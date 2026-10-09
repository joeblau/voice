import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauTelemetry

@Suite("PerformanceHUDReadout")
struct PerformanceHUDReadoutTests {
    @Test func anEmptySnapshotShowsPlaceholders() {
        let readout = PerformanceHUDReadout(PerformanceHUDSnapshot())
        #expect(readout.compact.map(\.label) == ["FPS", "CPU", "Memory", "Thermal", "EOU → audio", "Speech → audio"])
        #expect(readout.compact.allSatisfy { $0.value == "–" })
        #expect(
            readout.sections.map(\.title) == [
                "Device", "Audio", "Speech", "Grok", "Latency budget", "Topics", "Signposts",
            ])
        #expect(readout.row("Voice score")?.value == "–")
        #expect(readout.row("Intervals")?.value == "–")
        #expect(readout.level == .normal)
    }

    @Test func aFullSnapshotFormatsEveryRow() {
        let stats = LatencyStats(
            last: 42.4, p50: 40, p95: 58.6, mean: 41, maximum: 90, windowCount: 120, totalCount: 340)
        let snapshot = PerformanceHUDSnapshot(
            frameRate: FrameRateReading(
                framesPerSecond: 59.6, targetFramesPerSecond: 60, droppedFrames: 0, longestFrame: 0.017),
            cpuPercent: 14.4,
            memory: MemorySnapshot(
                physicalFootprint: 212 * 1_048_576, peakPhysicalFootprint: nil, neural: nil,
                available: UInt64(1.6 * 1_073_741_824)),
            thermalState: .fair,
            pipeline: PipelineReadings(
                capture: .init(droppedBuffers: 0, subscriberDroppedFrames: 0, conversionFailures: 0),
                voiceActivity: .init(isSpeech: true, modelLoad: 0.012, skippedFraction: 0.4),
                transcriber: .init(chunks: 10, meanChunkMilliseconds: 30, slowestChunkMilliseconds: 80),
                turnState: "listening", connection: "connected",
                firstAudio: LatencyStats(
                    last: 640, p50: 610, p95: 900, mean: 650, maximum: 980, windowCount: 12, totalCount: 12),
                turnTime: nil,
                usage: .init(inputTokens: 4120, outputTokens: 960, responses: 12, estimatedCostUSD: 0.4249)),
            intervals: [
                .init(interval: .asrChunk, stats: stats),
                .init(
                    interval: .vadChunk,
                    stats: .init(last: 0.84, p50: 0.8, p95: 1.26, mean: 0.9, maximum: 2, windowCount: 3, totalCount: 3)),
            ],
            voiceScore: .init(value: 0.712, reportedAt: 0, count: 1),
            voiceThreshold: .init(value: 0.55, reportedAt: 0, count: 1),
            topicDepth: .init(value: 0.184, reportedAt: 0, count: 4),
            overhead: 0.0004
        )
        let readout = PerformanceHUDReadout(snapshot)
        #expect(readout.row("FPS")?.value == "60 / 60")
        #expect(readout.row("CPU")?.value == "14%")
        #expect(readout.row("Memory")?.value == "212 MB · 1.6 GB free")
        #expect(readout.row("Thermal")?.value == "fair")
        #expect(readout.row("HUD cost")?.value == "0.04% CPU")
        #expect(readout.row("Capture")?.value == "no drops")
        #expect(readout.row("VAD")?.value == "speech · model 1.2% · skip 40%")
        // The signpost window wins over the transcriber's counters.
        #expect(readout.row("ASR chunk")?.value == "last 42 · p50 40 · p95 59 ms (n=340)")
        #expect(readout.row("EOU decision")?.value == "–")
        #expect(readout.row("Voice score")?.value == "0.71 (thr 0.55)")
        #expect(readout.row("Turn")?.value == "listening")
        #expect(readout.row("EOU → audio")?.value == "last 640 · p50 610 · p95 900 ms (n=12)")
        #expect(readout.compact.first { $0.label == "EOU → audio" }?.value == "p50 610 · p95 900 ms")
        #expect(readout.row("Turn time")?.value == "–")
        #expect(readout.row("Tokens")?.value == "4120 in · 960 out · 12 resp")
        #expect(readout.row("Cost")?.value == "$0.42 est.")
        #expect(readout.row("Topic depth")?.value == "0.18")
        #expect(readout.row("asr.chunk")?.value == "last 42 · p50 40 · p95 59 ms (n=340)")
        #expect(readout.row("vad.chunk")?.value == "last 0.8 · p50 0.8 · p95 1.3 ms (n=3)")
        #expect(readout.level == .normal)
    }

    @Test func theTranscriberCountersStandInForMissingSignposts() {
        var snapshot = PerformanceHUDSnapshot()
        snapshot.pipeline.transcriber = .init(chunks: 12, meanChunkMilliseconds: 31.6, slowestChunkMilliseconds: 7.25)
        #expect(PerformanceHUDReadout(snapshot).row("ASR chunk")?.value == "mean 32 · max 7.3 ms (n=12)")
        snapshot.pipeline.transcriber = .init(chunks: 0, meanChunkMilliseconds: 0, slowestChunkMilliseconds: 0)
        #expect(PerformanceHUDReadout(snapshot).row("ASR chunk")?.value == "–")
    }

    @Test func troubleRaisesTheLevel() {
        var snapshot = PerformanceHUDSnapshot()
        snapshot.frameRate = FrameRateReading(
            framesPerSecond: 50, targetFramesPerSecond: 60, droppedFrames: 4, longestFrame: 0.1)
        var readout = PerformanceHUDReadout(snapshot)
        #expect(readout.row("FPS")?.value == "50 / 60 · 4 dropped")
        #expect(readout.row("FPS")?.level == .warning)
        #expect(readout.level == .warning)

        snapshot.thermalState = .critical
        snapshot.pipeline.capture = .init(droppedBuffers: 3, subscriberDroppedFrames: 1, conversionFailures: 0)
        readout = PerformanceHUDReadout(snapshot)
        #expect(readout.row("Thermal")?.level == .critical)
        #expect(readout.row("Capture")?.value == "dropped 3 buf · 1 sub")
        #expect(readout.level == .critical)

        #expect(PerformanceHUDReadout.performanceLevelRow(nil).value == "–")
        #expect(PerformanceHUDReadout.performanceLevelRow(PerformanceSnapshot()).value == "normal")
        #expect(PerformanceHUDReadout.performanceLevelRow(PerformanceSnapshot()).level == .normal)
        snapshot.pipeline.performance = PerformanceSnapshot(
            level: .reduced, reasons: [.thermal(.serious), .lowPowerMode], isRecovering: true)
        readout = PerformanceHUDReadout(snapshot)
        #expect(readout.row("Perf level")?.value == "reduced · thermal state serious · recovering")
        #expect(readout.row("Perf level")?.level == .warning)
        #expect(
            PerformanceHUDReadout.performanceLevelRow(
                PerformanceSnapshot(level: .minimal, reasons: [.lowBattery(percent: 4)])
            ).value == "minimal · battery at 4%")
        #expect(
            PerformanceHUDReadout.performanceLevelRow(PerformanceSnapshot(level: .minimal, reasons: [.override]))
                .level == .critical)

        #expect(PerformanceHUDReadout.cpuRow(85).level == .warning)
        #expect(PerformanceHUDReadout.cpuRow(220).level == .critical)
        #expect(PerformanceHUDReadout.overheadRow(0.012).level == .warning)
        let low = MemorySnapshot(
            physicalFootprint: 1, peakPhysicalFootprint: nil, neural: nil, available: 100 * 1_048_576)
        #expect(PerformanceHUDReadout.memoryRow(low).level == .critical)
        #expect(
            PerformanceHUDReadout.frameRateRow(
                .init(framesPerSecond: 20, targetFramesPerSecond: 60, droppedFrames: 0, longestFrame: 0)
            ).level == .critical)
    }

    @Test(arguments: [
        (0.0, 0, "0"), (1.25, 1, "1.3"), (0.05, 2, "0.05"), (-0.004, 2, "0.00"), (-1.5, 1, "-1.5"),
        (12.0, 3, "12.000"), (0.999, 2, "1.00"), (Double.nan, 2, "–"),
    ])
    func decimalsDontDependOnTheLocale(value: Double, places: Int, expected: String) {
        #expect(PerformanceHUDReadout.decimal(value, places: places) == expected)
    }

    @Test func unitFormatting() {
        #expect(PerformanceHUDReadout.percent(0.0004) == "0.04%")
        #expect(PerformanceHUDReadout.percent(0.05) == "5.0%")
        #expect(PerformanceHUDReadout.percent(1.5) == "150%")
        #expect(PerformanceHUDReadout.bytes(5 * 1_048_576) == "5 MB")
        #expect(PerformanceHUDReadout.bytes(3 * 1_073_741_824) == "3.0 GB")
        #expect(PerformanceHUDReadout.milliseconds(9.94) == "9.9")
        #expect(PerformanceHUDReadout.milliseconds(10.4) == "10")
        #expect(PerformanceHUDReadout.cost(0.0123) == "$0.012 est.")
        #expect(
            PerformanceHUDReadout.cost(12.345) == "$12.35 est." || PerformanceHUDReadout.cost(12.345) == "$12.34 est.")
    }
}

/// Scripted clocks for the sampler: every read returns the next value.
private final class ScriptedCPU: CPUTimeSource {
    private let state = Mutex((process: UInt64(0), thread: UInt64(0), wall: UInt64(0)))

    func advance(process: UInt64 = 0, thread: UInt64 = 0, wall: UInt64 = 0) {
        state.withLock {
            $0.process += process
            $0.thread += thread
            $0.wall += wall
        }
    }

    func processCPUTime() -> UInt64 { state.withLock { $0.process } }
    func threadCPUTime() -> UInt64 { state.withLock { $0.thread } }
    func wallTime() -> UInt64 { state.withLock { $0.wall } }
}

private struct FixedMemory: MemoryProbe {
    func snapshot() -> MemorySnapshot? {
        MemorySnapshot(physicalFootprint: 100 * 1_048_576, peakPhysicalFootprint: nil, neural: nil, available: nil)
    }
}

@Suite("PerformanceHUDSampler")
struct PerformanceHUDSamplerTests {
    @Test func samplesEveryProbeAndTheTap() throws {
        let cpu = ScriptedCPU()
        let tap = SignpostLatencyTap()
        let gauges = PerformanceGauges()
        var sampler = PerformanceHUDSampler(
            memory: FixedMemory(), cpu: cpu, thermal: { .serious }, tap: tap, gauges: gauges)
        sampler.start()
        #expect(tap.isActive)

        tap.record(.asrChunk, nanoseconds: 40_000_000)
        gauges.report(.voiceScore, 0.66)
        cpu.advance(process: 100_000_000, wall: 500_000_000)
        var pipelineReads = 0
        let readout = sampler.sample(frameRate: nil) {
            pipelineReads += 1
            return PipelineReadings(turnState: "listening")
        }
        #expect(pipelineReads == 1)
        let snapshot = sampler.snapshot
        #expect(snapshot.cpuPercent == 20)
        #expect(snapshot.memory?.physicalFootprint == 100 * 1_048_576)
        #expect(snapshot.thermalState == .serious)
        #expect(snapshot.stats(for: .asrChunk)?.last == 40)
        #expect(snapshot.voiceScore?.value == 0.66)
        #expect(snapshot.pipeline.turnState == "listening")
        #expect(readout.row("Thermal")?.value == "serious")
        #expect(readout.row("asr.chunk") != nil)

        sampler.stop()
        #expect(!tap.isActive)
        #expect(!sampler.isRunning)
    }

    @Test func chargesItsOwnTimeAndTheDisplayLinksToTheOverhead() throws {
        let cpu = ScriptedCPU()
        var sampler = PerformanceHUDSampler(
            memory: FixedMemory(), cpu: cpu, thermal: { .nominal }, tap: SignpostLatencyTap(),
            gauges: PerformanceGauges())
        sampler.start()
        for _ in 0..<4 {
            cpu.advance(wall: 500_000_000)
            sampler.chargeExternal(nanoseconds: 1_000_000)
            // Each sample "costs" 1 ms of thread time.
            sampler.sample(frameRate: nil) {
                cpu.advance(thread: 1_000_000)
                return PipelineReadings()
            }
        }
        cpu.advance(wall: 500_000_000)
        sampler.sample(frameRate: nil) { PipelineReadings() }
        // 4 x (1 ms sampling + 1 ms display link) over 2.5 s.
        let overhead = try #require(sampler.snapshot.overhead)
        #expect(abs(overhead - 0.008 / 2.5) < 1e-9)
    }

    /// The overhead acceptance criterion: sampling at the HUD's rate with
    /// the real probes costs far less than 1% of a core. It counts thread
    /// CPU time, not wall time, so a busy CI host doesn't inflate it.
    @Test func realSamplingCostsWellUnderOnePercentOfACore() throws {
        let source = SystemCPUTimeSource()
        let tap = SignpostLatencyTap()
        var sampler = PerformanceHUDSampler(tap: tap, gauges: PerformanceGauges())
        sampler.start()
        for interval in PipelineInterval.allCases {
            for sample in 0..<200 {
                tap.record(interval, nanoseconds: UInt64(1_000_000 + sample * 1_000))
            }
        }
        let samples = 40
        let start = source.threadCPUTime()
        for _ in 0..<samples {
            sampler.sample(
                frameRate: FrameRateReading(
                    framesPerSecond: 60, targetFramesPerSecond: 60, droppedFrames: 0, longestFrame: 0.016)
            ) {
                PipelineReadings(turnState: "listening")
            }
        }
        let perSample = Double(source.threadCPUTime() - start) / Double(samples)
        let samplesPerSecond = 1 / PerformanceHUDSampler.defaultInterval.timeInterval
        let share = perSample * samplesPerSecond / 1_000_000_000
        print("HUD sampling: \(Int(perSample / 1_000)) µs per sample, \(share * 100)% of a core at the HUD's rate")
        // Every interval has a full window here (the worst case); a debug
        // build measures about 0.1%, an optimized one far less.
        #expect(share < 0.005, "Sampling should stay under half of the 1% budget")
        sampler.stop()
    }

    /// The signpost tap's cost per interval at a busy pipeline's rate
    /// (capture frames, VAD and ASR chunks, realtime events, ~250 a second).
    @Test func tappingIntervalsCostsWellUnderOnePercentOfACore() {
        let source = SystemCPUTimeSource()
        let tap = SignpostLatencyTap()
        tap.activate()
        let tapped = Signposter(
            category: .asr, backend: TappedSignpostBackend(base: OSSignpostBackend.disabled, tap: tap))
        let iterations = 20_000
        let start = source.threadCPUTime()
        for _ in 0..<iterations {
            tapped.withInterval(.asrChunk) {}
        }
        let perInterval = Double(source.threadCPUTime() - start) / Double(iterations)
        let share = perInterval * 250 / 1_000_000_000
        print("Signpost tap: \(Int(perInterval)) ns per interval, \(share * 100)% of a core at 250 intervals/s")
        #expect(tap.stats(for: .asrChunk)?.totalCount == iterations)
        #expect(share < 0.001)
    }
}
