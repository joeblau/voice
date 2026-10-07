import Foundation
import Synchronization
import Testing

@testable import BlauTelemetry

/// The workload `scripts/verify-hud.sh` records with Instruments to check
/// that the performance HUD's numbers match Instruments' own.
///
/// Off by default. With `BLAU_HUD_COMPARE=1` it:
///
/// 1. times a few hundred canonical intervals of known, varied lengths
///    through the shared `Signposts` while the HUD's tap is active (some
///    overlapping, some ending on another task), and
/// 2. holds a steady CPU load for 20 s (one thread at a fixed duty cycle) and an
///    extra 96 MB of touched memory inside the `hud.compare.load` interval,
///    sampling CPU % and the memory footprint the way the HUD does,
///
/// then writes what the HUD measured to `BLAU_HUD_COMPARE_OUT` as JSON. The
/// script compares it with the os_signpost and Activity Monitor tables of
/// the trace (`scripts/lib/hud_compare.py`).
@Suite(
    "Performance HUD vs Instruments workload",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_HUD_COMPARE"] == "1")
)
struct PerformanceHUDInstrumentsComparison {
    /// The intervals the workload emits, and the range of their lengths in
    /// milliseconds.
    static let workload: [(PipelineInterval, ClosedRange<Double>)] = [
        (.captureFrame, 0.2...1.5),
        (.vadChunk, 0.5...3),
        (.asrChunk, 3...25),
        (.voiceIDVerify, 2...12),
        (.realtimeFirstAudio, 5...40),
        (.realtimeTurn, 10...60),
        (.playbackFirstBuffer, 1...10),
        (.topicsSegment, 0.3...4),
        (.dbSave, 1...8),
    ]
    static let repetitions = 40
    /// Every fourth repetition runs two overlapping intervals.
    static let expectedCount = repetitions + repetitions / 4

    struct Output: Codable {
        struct Interval: Codable {
            var count: Int
            var mean: Double
            var p50: Double
            var p95: Double
            var maximum: Double
            /// Every duration the HUD timed, in milliseconds, in the order
            /// the intervals ended.
            var samples: [Double]
        }

        var pid: Int32
        var intervals: [String: Interval]
        /// HUD CPU % readings (100 = one core) inside the load phase.
        var cpuPercent: [Double]
        /// HUD physical-footprint readings inside the load phase, in bytes.
        var footprintBytes: [UInt64]
        /// The process CPU time (ns) the HUD's clock read at each sample of
        /// the load phase, in order; each read is inside a
        /// `hud.compare.sample` interval, so the trace knows when it was.
        var cpuTimes: [UInt64]
        /// The duty cycle of the load thread.
        var loadDuty: Double
    }

    @Test func recordTheWorkload() async throws {
        try await waitForTheRecording()
        let tap = SignpostLatencyTap.shared
        tap.activate()
        defer { tap.deactivate() }

        try await emitIntervals()
        let (cpu, footprint, cpuTimes) = try await holdSteadyLoad()

        var intervals: [String: Output.Interval] = [:]
        for (interval, _) in Self.workload {
            let stats = try #require(tap.stats(for: interval), "\(interval.name) was not timed")
            #expect(stats.totalCount == Self.expectedCount)
            intervals[interval.name.description] = Output.Interval(
                count: stats.totalCount, mean: stats.mean, p50: stats.p50, p95: stats.p95, maximum: stats.maximum,
                samples: tap.samples(for: interval))
        }
        let output = Output(
            pid: ProcessInfo.processInfo.processIdentifier, intervals: intervals, cpuPercent: cpu,
            footprintBytes: footprint, cpuTimes: cpuTimes, loadDuty: Self.loadDuty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        if let path = ProcessInfo.processInfo.environment["BLAU_HUD_COMPARE_OUT"] {
            try data.write(to: URL(filePath: path))
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    /// With `BLAU_HUD_COMPARE_READY` and `BLAU_HUD_COMPARE_GO` set (the
    /// script sets both), writes this process's pid to the first path so
    /// Instruments can attach to it, then waits for the second to exist.
    private func waitForTheRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let ready = environment["BLAU_HUD_COMPARE_READY"], let go = environment["BLAU_HUD_COMPARE_GO"] else {
            return
        }
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: URL(filePath: ready))
        let deadline = ContinuousClock.now + .seconds(300)
        while !FileManager.default.fileExists(atPath: go) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Instruments never started recording")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Signposts

    /// Deterministic lengths, so a rerun produces the same mix.
    private struct Lengths {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private func emitIntervals() async throws {
        var lengths = Lengths()
        for repetition in 0..<Self.repetitions {
            for (interval, range) in Self.workload {
                let milliseconds = lengths.next(in: range)
                switch repetition % 4 {
                case 0:
                    // Synchronous work on this thread.
                    Signposts.withInterval(interval) { spin(milliseconds: milliseconds) }
                case 1:
                    // Async work across a suspension.
                    try await Signposts.withInterval(interval) {
                        try await Task.sleep(for: .microseconds(Int(milliseconds * 1_000)))
                    }
                case 2:
                    // Begun here, ended on another task.
                    let span = Signposts.beginInterval(interval)
                    await Task.detached {
                        spin(milliseconds: milliseconds)
                        span.end()
                    }.value
                default:
                    // Two of the same interval overlapping on two tasks.
                    let other = lengths.next(in: range)
                    async let first: Void = Task.detached {
                        Signposts.withInterval(interval) { spin(milliseconds: milliseconds) }
                    }.value
                    async let second: Void = Task.detached {
                        Signposts.withInterval(interval) { spin(milliseconds: other) }
                    }.value
                    _ = await (first, second)
                }
            }
        }
    }

    // MARK: CPU and memory

    static let loadDuty = 0.6
    static let loadSeconds = 20.0
    static let extraMemory = 96 * 1_048_576

    /// Runs the load and returns the HUD's CPU and footprint readings taken
    /// every 250 ms during it (the first second is skipped while it ramps up).
    private func holdSteadyLoad() async throws -> (cpu: [Double], footprint: [UInt64], cpuTimes: [UInt64]) {
        let source = SystemCPUTimeSource()
        let probe = ProcessMemoryProbe()
        let stop = StopFlag()

        let load = Signposts.ui.beginInterval("hud.compare.load")
        let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.extraMemory, alignment: 16_384)
        defer { memory.deallocate() }
        memset(memory.baseAddress!, 0xA5, Self.extraMemory)

        let worker = Thread {
            let period = 10.0
            while !stop.isSet {
                spin(milliseconds: period * Self.loadDuty)
                Thread.sleep(forTimeInterval: period * (1 - Self.loadDuty) / 1_000)
            }
        }
        worker.start()

        var meter = CPUUsageMeter()
        var cpu: [Double] = []
        var footprint: [UInt64] = []
        var cpuTimes: [UInt64] = []
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(Self.loadSeconds) {
            try await Task.sleep(for: .milliseconds(250))
            let marker = Signposts.ui.beginInterval("hud.compare.sample")
            let processCPU = source.processCPUTime()
            marker.end()
            cpuTimes.append(processCPU)
            let percent = meter.sample(cpu: processCPU, wall: source.wallTime())
            guard ContinuousClock.now - started > .seconds(1) else { continue }
            if let percent { cpu.append(percent) }
            if let snapshot = probe.snapshot() { footprint.append(snapshot.physicalFootprint) }
        }
        stop.set()
        load.end()
        // Keep the memory touched until the interval has ended.
        #expect(memory[Self.extraMemory - 1] == 0xA5)
        return (cpu, footprint, cpuTimes)
    }
}

private final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    var isSet: Bool { flag.load(ordering: .relaxed) }

    func set() { flag.store(true, ordering: .relaxed) }
}

private func spin(milliseconds: Double) {
    let deadline = ContinuousClock.now + .microseconds(Int(milliseconds * 1_000))
    while ContinuousClock.now < deadline {}
}
