import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Synchronization

/// A streaming processor whose windows "take" a scripted time on a
/// `VirtualClock`, with FluidAudio's windowing.
final class FakeStreamingProcessor: StreamingChunkProcessor {
    struct Calls: Hashable {
        var prepare = 0
        var load = 0
        var process = 0
        var finish = 0
        var unload = 0
        var samples = 0
    }

    let windowSamples: Int
    let hopSamples: Int
    private let clock: VirtualClock
    private let loadTime: Duration
    private let finishTime: Duration
    /// Latency of one window at a given uptime.
    private let windowTime: @Sendable (Duration) -> Duration
    /// Throws from `process` at a given uptime, if non-nil.
    private let failure: @Sendable (Duration) -> (any Error)?
    private let state = Mutex<(calls: Calls, buffered: Int)>((Calls(), 0))

    init(
        windowSamples: Int = 10_080,
        hopSamples: Int = 5_120,
        clock: VirtualClock,
        loadTime: Duration = .milliseconds(500),
        finishTime: Duration = .milliseconds(30),
        windowTime: @escaping @Sendable (Duration) -> Duration = { _ in .milliseconds(40) },
        failure: @escaping @Sendable (Duration) -> (any Error)? = { _ in nil }
    ) {
        self.windowSamples = windowSamples
        self.hopSamples = hopSamples
        self.clock = clock
        self.loadTime = loadTime
        self.finishTime = finishTime
        self.windowTime = windowTime
        self.failure = failure
    }

    var calls: Calls { state.withLock { $0.calls } }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0.calls.prepare += 1 }
        progress(1)
    }

    func load() async throws {
        state.withLock { $0.calls.load += 1 }
        clock.advance(by: loadTime)
    }

    func process(_ samples: [Float]) async throws {
        if let error = failure(clock.uptime) { throw error }
        let windows = state.withLock { state in
            state.calls.process += 1
            state.calls.samples += samples.count
            state.buffered += samples.count
            var windows = 0
            while state.buffered >= windowSamples {
                windows += 1
                state.buffered -= hopSamples
            }
            return windows
        }
        let perWindow = windowTime(clock.uptime)
        clock.advance(by: perWindow * windows)
    }

    func finishUtterance() async throws -> String {
        state.withLock { state in
            state.calls.finish += 1
            state.buffered = 0
        }
        clock.advance(by: finishTime)
        return "text"
    }

    func unload() async {
        state.withLock { $0.calls.unload += 1 }
    }
}

/// Virtual time for code that paces itself: `sleep(for:)` returns at once
/// after moving the clock forward by the duration, and fakes `advance` it
/// to simulate work. A single task drives it, so runs are deterministic
/// and take no real time.
final class VirtualClock: BlauClock {
    private let state = Mutex<(now: Date, uptime: Duration)>((Date(timeIntervalSinceReferenceDate: 0), .zero))

    var now: Date { state.withLock { $0.now } }
    var uptime: Duration { state.withLock { $0.uptime } }

    func advance(by duration: Duration) {
        state.withLock { state in
            state.uptime += duration
            state.now += duration.timeInterval
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration > .zero { advance(by: duration) }
    }
}

extension BenchmarkDevice {
    static func fixture(
        identifier: String,
        simulator: Bool = false,
        operatingSystem: String = "iOS 27.2 (Build 24C5054e)"
    ) -> BenchmarkDevice {
        let known = BenchmarkDevice.lookup(identifier)
        return BenchmarkDevice(
            modelIdentifier: identifier, marketingName: known?.name, chip: known?.chip,
            operatingSystem: operatingSystem, physicalMemoryBytes: 8 << 30, activeProcessorCount: 6,
            isSimulator: simulator)
    }
}

/// A fixed memory reading.
struct FixedMemoryProbe: MemoryProbe {
    func snapshot() -> MemorySnapshot? {
        MemorySnapshot(physicalFootprint: 50 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
    }
}
