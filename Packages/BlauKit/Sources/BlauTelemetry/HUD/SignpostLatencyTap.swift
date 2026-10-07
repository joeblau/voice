import Darwin
import Synchronization

/// An in-process consumer of Blau's canonical signpost intervals: while it
/// is active, every `PipelineInterval` that ends through the shared
/// `Signposts` adds its duration to a rolling window, which the debug
/// performance HUD (#71) reads.
///
/// The HUD therefore measures exactly the spans Instruments shows: the same
/// begin and end calls produce both the `os_signpost` records and the
/// samples here. Both timestamps are taken right before the `os_signpost`
/// begin and end calls, so the call's own cost cancels out and a HUD
/// duration differs from Instruments' only by scheduling jitter inside
/// those calls. `scripts/verify-hud.sh` checks that against a real trace.
///
/// While inactive (the default, and whenever the HUD is hidden) the cost is
/// one relaxed atomic load per interval. While active, an interval costs two
/// clock reads, a name lookup and one short lock.
public final class SignpostLatencyTap: Sendable {
    /// The tap the shared `Signposts` report to.
    public static let shared = SignpostLatencyTap()

    /// One canonical interval's statistics.
    public struct IntervalLatency: Sendable, Hashable {
        public var interval: PipelineInterval
        public var stats: LatencyStats

        public init(interval: PipelineInterval, stats: LatencyStats) {
            self.interval = interval
            self.stats = stats
        }
    }

    /// How many recent samples each interval keeps.
    public let capacity: Int
    private let active = Atomic<Bool>(false)
    private let windows: Mutex<[LatencyWindow]>

    /// - Parameter capacity: Samples kept per interval (the window the
    ///   percentiles cover).
    public init(capacity: Int = 200) {
        self.capacity = capacity
        windows = Mutex(Array(repeating: LatencyWindow(capacity: capacity), count: PipelineInterval.allCases.count))
    }

    /// Whether intervals are being recorded.
    public var isActive: Bool { active.load(ordering: .relaxed) }

    /// Starts recording, from an empty window.
    public func activate() {
        reset()
        active.store(true, ordering: .relaxed)
    }

    /// Stops recording. What was recorded stays readable.
    public func deactivate() {
        active.store(false, ordering: .relaxed)
    }

    /// Drops every recorded sample.
    public func reset() {
        let capacity = capacity
        windows.withLock { windows in
            for index in windows.indices {
                windows[index] = LatencyWindow(capacity: capacity)
            }
        }
    }

    /// Adds one sample for `interval`, whether or not the tap is active.
    /// Backends call this; tests and harnesses may too.
    public func record(_ interval: PipelineInterval, nanoseconds: UInt64) {
        record(index: interval.tapIndex, nanoseconds: nanoseconds)
    }

    func record(index: Int, nanoseconds: UInt64) {
        let milliseconds = Double(nanoseconds) / 1_000_000
        windows.withLock { $0[index].add(milliseconds: milliseconds) }
    }

    /// The statistics for `interval`, or `nil` before its first sample.
    public func stats(for interval: PipelineInterval) -> LatencyStats? {
        let window = windows.withLock { $0[interval.tapIndex] }
        return window.stats
    }

    /// The samples in `interval`'s window, in milliseconds, oldest first.
    public func samples(for interval: PipelineInterval) -> [Double] {
        let window = windows.withLock { $0[interval.tapIndex] }
        return window.samples
    }

    /// Every canonical interval with at least one sample, in
    /// `PipelineInterval` order.
    public func allStats() -> [IntervalLatency] {
        let copies = windows.withLock { $0 }
        return zip(PipelineInterval.allCases, copies).compactMap { interval, window in
            window.stats.map { IntervalLatency(interval: interval, stats: $0) }
        }
    }

    /// The current time on the clock the tap measures with: continuous
    /// (it keeps counting while the device sleeps), like `os_signpost`'s
    /// timestamps.
    @inline(__always)
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

extension PipelineInterval {
    /// The interval's position in `allCases`, which is also its slot in
    /// `SignpostLatencyTap`.
    var tapIndex: Int { Self.tapIndices[self]! }

    private static let tapIndices: [PipelineInterval: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })

    /// Every case's name, in `allCases` order.
    private static let tapNames: [StaticString] = allCases.map(\.name)

    /// The canonical interval named `name`, as its `tapIndex`, or `nil` for
    /// an ad-hoc name. Names passed through `PipelineInterval.name` are the
    /// same literals, so the pointer comparison almost always settles it;
    /// the byte comparison catches an ad-hoc literal with a canonical name.
    static func tapIndex(named name: StaticString) -> Int? {
        guard name.hasPointerRepresentation else { return nil }
        let pointer = name.utf8Start
        let length = name.utf8CodeUnitCount
        if let index = tapNames.firstIndex(where: { $0.hasPointerRepresentation && $0.utf8Start == pointer }) {
            return index
        }
        return tapNames.firstIndex { candidate in
            candidate.hasPointerRepresentation && candidate.utf8CodeUnitCount == length
                && memcmp(candidate.utf8Start, pointer, length) == 0
        }
    }
}

// MARK: - TappedSignpostBackend

/// A `SignpostBackend` that passes everything to `base` and, while `tap` is
/// active, also times every canonical interval for it.
///
/// The shared `Signposts` use one over their default backend, so every
/// pipeline stage reaches the HUD without knowing about it. When `base` is
/// off (nothing is recording signposts) but the tap is active, intervals are
/// still timed and `base` isn't called.
public struct TappedSignpostBackend: SignpostBackend {
    public let base: any SignpostBackend
    public let tap: SignpostLatencyTap

    public init(base: any SignpostBackend, tap: SignpostLatencyTap = .shared) {
        self.base = base
        self.tap = tap
    }

    public var isEnabled: Bool { tap.isActive || base.isEnabled }

    public func beginInterval(_ name: StaticString) -> SignpostIntervalToken {
        // Both timestamps are taken just before the os_signpost call, so the
        // time `os_signpost` spends before reading its own clock cancels out
        // between begin and end.
        var index: Int?
        var start: UInt64?
        if tap.isActive, let found = PipelineInterval.tapIndex(named: name) {
            index = found
            start = SignpostLatencyTap.now()
        }
        let baseActive = base.isEnabled
        var token = baseActive ? base.beginInterval(name) : SignpostIntervalToken(id: 0)
        token.tapBaseActive = baseActive
        token.tapIndex = index
        token.tapStart = start
        return token
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken) {
        let end = token.tapStart != nil ? SignpostLatencyTap.now() : 0
        if token.tapBaseActive {
            base.endInterval(name, token)
        }
        recordTap(token, end: end)
    }

    public func endInterval(_ name: StaticString, _ token: SignpostIntervalToken, message: String) {
        let end = token.tapStart != nil ? SignpostLatencyTap.now() : 0
        if token.tapBaseActive {
            base.endInterval(name, token, message: message)
        }
        recordTap(token, end: end)
    }

    public func emitEvent(_ name: StaticString) {
        guard base.isEnabled else { return }
        base.emitEvent(name)
    }

    private func recordTap(_ token: SignpostIntervalToken, end: UInt64) {
        guard let start = token.tapStart, let index = token.tapIndex, end >= start else { return }
        tap.record(index: index, nanoseconds: end - start)
    }
}
