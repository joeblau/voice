import Synchronization

/// How much work the conversation pipeline may do right now (#75).
///
/// `PerformancePolicy` derives it from the device's thermal state, Low
/// Power Mode and battery level. Each subsystem maps it to its own knobs;
/// the levels are ordered, so `level >= .reduced` reads "at least reduced":
///
/// | Level | Streaming ASR | Second pass | Topic LLM | Memory indexing |
/// | --- | --- | --- | --- | --- |
/// | `normal` | Parakeet, 320 ms chunks | On | Confirms every candidate | Immediate |
/// | `reduced` | Parakeet, 1280 ms chunks | Off | Confirms strong candidates only | Deferred |
/// | `minimal` | Apple's `SpeechTranscriber` where the stage offers it, else 1280 ms | Off | Titles only, no confirmation | Suspended |
///
/// See docs/performance.md ("Thermal and power adaptation").
public enum PerformanceLevel: String, CaseIterable, Codable, Comparable, Hashable, Sendable {
    /// Everything on: the device is cool and has power to spare.
    case normal
    /// Shed the optional work: the device is hot, in Low Power Mode or low
    /// on battery.
    case reduced
    /// Shed everything that can be shed: the device is critically hot or
    /// almost out of battery.
    case minimal

    private var rank: Int {
        switch self {
        case .normal: 0
        case .reduced: 1
        case .minimal: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Whether any work is being shed.
    public var isDegraded: Bool { self != .normal }

    /// One level less restrictive, or `nil` at `normal`.
    var relaxed: PerformanceLevel? {
        switch self {
        case .normal: nil
        case .reduced: .normal
        case .minimal: .reduced
        }
    }
}

/// Reports the current `PerformanceLevel`. `PerformancePolicy` is the
/// production implementation; tests and previews use `FixedPerformanceLevel`
/// or `ManualPerformanceLevel`.
///
/// Consumers read `performanceLevel` synchronously on their own hot paths
/// (between utterances, per candidate), so it must return at once.
public protocol PerformanceLevelProviding: Sendable {
    /// The level right now.
    var performanceLevel: PerformanceLevel { get }

    /// The current level, then every change. Finishes when the consumer
    /// stops iterating; a provider that never changes yields once and then
    /// stays open.
    func performanceLevels() -> AsyncStream<PerformanceLevel>
}

/// A level that never changes. For tests, previews and pipelines built
/// without the policy.
public struct FixedPerformanceLevel: PerformanceLevelProviding {
    public let performanceLevel: PerformanceLevel

    public init(_ level: PerformanceLevel = .normal) {
        performanceLevel = level
    }

    public func performanceLevels() -> AsyncStream<PerformanceLevel> {
        // Stays open: a consumer waiting for a better level must keep
        // waiting, not see the stream end.
        let (stream, continuation) = AsyncStream.makeStream(of: PerformanceLevel.self)
        continuation.yield(performanceLevel)
        return stream
    }
}

/// A level set by hand. For tests and SwiftUI previews.
public final class ManualPerformanceLevel: PerformanceLevelProviding {
    private struct State {
        var level: PerformanceLevel
        var nextID: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<PerformanceLevel>.Continuation] = [:]
    }

    private let state: Mutex<State>

    public init(_ level: PerformanceLevel = .normal) {
        state = Mutex(State(level: level))
    }

    public var performanceLevel: PerformanceLevel { state.withLock { $0.level } }

    /// Changes the level and tells every subscriber.
    public func set(_ level: PerformanceLevel) {
        let subscribers = state.withLock { state -> [AsyncStream<PerformanceLevel>.Continuation] in
            guard state.level != level else { return [] }
            state.level = level
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.yield(level)
        }
    }

    public func performanceLevels() -> AsyncStream<PerformanceLevel> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PerformanceLevel.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = continuation
            continuation.yield(state.level)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// The number of open `performanceLevels()` streams.
    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}
