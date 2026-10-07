import BlauAudio
import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Synchronization
import Testing

@Suite("Background inference probe")
struct BackgroundInferenceProbeTests {
    /// Foreground until `lockAt`, then locked.
    struct ScriptedPhases: ExecutionPhaseProvider {
        let clock: VirtualClock
        let lockAt: Duration

        func currentPhase() async -> ExecutionPhase {
            clock.uptime < lockAt ? .foreground : .locked
        }
    }

    /// Foreground until `lockAt`, locked until `suspendAt`. The first check
    /// at or after `suspendAt` simulates a suspension: the clock jumps by
    /// `suspension` (as if the process was frozen) and the tester has
    /// unlocked, so the app is back in the foreground.
    final class SuspendingPhases: ExecutionPhaseProvider {
        let clock: VirtualClock
        let lockAt: Duration
        let suspendAt: Duration
        let suspension: Duration
        let resumed = Mutex(false)

        init(clock: VirtualClock, lockAt: Duration, suspendAt: Duration, suspension: Duration) {
            self.clock = clock
            self.lockAt = lockAt
            self.suspendAt = suspendAt
            self.suspension = suspension
        }

        func currentPhase() async -> ExecutionPhase {
            if clock.uptime < lockAt { return .foreground }
            if resumed.withLock({ $0 }) { return .foreground }
            if clock.uptime < suspendAt { return .locked }
            resumed.withLock { $0 = true }
            clock.advance(by: suspension)
            return .foreground
        }
    }

    struct ANEUnavailable: Error, CustomStringConvertible {
        var description: String { "ANE unavailable" }
    }

    static let audio = AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(5)))

    static func probe(
        clock: VirtualClock,
        lockAt: Duration,
        processor: FakeStreamingProcessor,
        cpu: FakeStreamingProcessor?,
        duration: Duration = .seconds(40)
    ) -> BackgroundInferenceProbe {
        BackgroundInferenceProbe(
            processor: processor,
            cpuProcessor: cpu,
            phases: ScriptedPhases(clock: clock, lockAt: lockAt),
            neuralEngineListed: { true },
            audio: audio,
            configuration: .init(duration: duration, cpuBaselineWindows: 30, warmupWindows: 4, utteranceSeconds: 10)
        )
    }

    static func run(_ probe: BackgroundInferenceProbe, clock: VirtualClock) async throws -> BackgroundProbeReport {
        let context = BenchmarkContext(clock: clock, memory: FixedMemoryProbe())
        return try await probe.run(context: context)
    }

    @Test func cpuLikeLatencyAfterLockingIsAFallbackTheCPUCanCarry() async throws {
        let clock = VirtualClock()
        // The run starts after the CPU baseline and model load, about 10 s in.
        let lockAt = Duration.seconds(30)
        let processor = FakeStreamingProcessor(
            clock: clock, windowTime: { $0 < lockAt ? .milliseconds(40) : .milliseconds(160) })
        let cpu = FakeStreamingProcessor(clock: clock, windowTime: { _ in .milliseconds(170) })

        let report = try await Self.run(
            Self.probe(clock: clock, lockAt: lockAt, processor: processor, cpu: cpu), clock: clock)

        #expect(report.analysis.cpuBaseline?.p50 == 170)
        #expect(report.analysis.foreground?.p50 == 40)
        #expect(report.analysis.locked?.p50 == 160)
        #expect(report.analysis.verdict == .cpuFallback(slowdown: 4))
        #expect(report.mitigation == .acceptCPUFallback)
        #expect(report.hopMilliseconds == 320)
        #expect(report.samples.contains { $0.phase == .foreground })
        #expect(report.samples.contains { $0.phase == .locked })
        #expect(cpu.calls.unload == 1)
        #expect(processor.calls.unload == 1)
    }

    @Test func errorsAfterLockingAreRecordedNotThrown() async throws {
        let clock = VirtualClock()
        let lockAt = Duration.seconds(30)
        let processor = FakeStreamingProcessor(
            clock: clock, failure: { $0 >= lockAt ? ANEUnavailable() : nil })
        let cpu = FakeStreamingProcessor(clock: clock, windowTime: { _ in .milliseconds(170) })

        let report = try await Self.run(
            Self.probe(clock: clock, lockAt: lockAt, processor: processor, cpu: cpu), clock: clock)

        guard case .errors(let count, let first) = report.analysis.verdict else {
            Issue.record("Expected errors, got \(report.analysis.verdict)")
            return
        }
        #expect(count > 10)
        #expect(first == "ANE unavailable")
        #expect(report.mitigation == .reloadOnCPUWhenBackgrounded)
    }

    @Test func steadyLatencyKeepsTheNeuralEngine() async throws {
        let clock = VirtualClock()
        let report = try await Self.run(
            Self.probe(
                clock: clock, lockAt: .seconds(25), processor: FakeStreamingProcessor(clock: clock), cpu: nil),
            clock: clock)
        #expect(report.analysis.verdict == .works(slowdown: 1))
        #expect(report.mitigation == .keepNeuralEngine)
        #expect(report.analysis.cpuBaseline == nil)
    }

    @Test func aSuspensionUntilTheEndOfTheRunIsNotReadAsWorking() async throws {
        // Normal latency before and after locking, then the app is suspended
        // and only resumes after `duration` has passed. The step after
        // resuming changes phase, so it is a warm-up and records nothing;
        // the run then ends. Without the run's end time the last locked
        // sample had no successor and the verdict came out `.works`.
        let clock = VirtualClock()
        let probe = BackgroundInferenceProbe(
            processor: FakeStreamingProcessor(clock: clock),
            cpuProcessor: nil,
            phases: SuspendingPhases(
                clock: clock, lockAt: .seconds(15), suspendAt: .seconds(27), suspension: .seconds(60)),
            neuralEngineListed: { true },
            audio: Self.audio,
            configuration: .init(duration: .seconds(40), cpuBaselineWindows: 30, warmupWindows: 4, utteranceSeconds: 10)
        )
        let report = try await Self.run(probe, clock: clock)

        #expect((report.analysis.background?.count ?? 0) >= 20)
        #expect((report.analysis.foreground?.count ?? 0) >= 20)
        #expect(report.samples.last?.phase == .locked)
        guard case .suspended(let coverage) = report.analysis.verdict else {
            Issue.record("Expected suspended, got \(report.analysis.verdict)")
            return
        }
        #expect(coverage < 0.3)
        #expect(report.mitigation == .fixBackgroundExecution)
        #expect((report.analysis.runEndedAtUptimeSeconds ?? 0) > 80)
    }

    @Test func reportRoundTripsThroughJSON() async throws {
        let clock = VirtualClock()
        let report = try await Self.run(
            Self.probe(
                clock: clock, lockAt: .seconds(10), processor: FakeStreamingProcessor(clock: clock), cpu: nil,
                duration: .seconds(15)),
            clock: clock)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackgroundProbeReport.self, from: report.jsonData())
        #expect(decoded.samples == report.samples)
        #expect(decoded.mitigation == report.mitigation)
    }
}

@Suite("Background inference mitigation")
struct BackgroundInferenceMitigationTests {
    static let hop = Duration.milliseconds(320)

    static func analysis(foreground: Double, background: Double?, error: String? = nil, cpu: Double?)
        -> BackgroundInferenceAnalysis
    {
        let foregroundSamples = (0..<30).map {
            InferenceSample(
                uptimeSeconds: Double($0) * 0.32, phase: .foreground, latencyMilliseconds: foreground, error: nil,
                neuralEngineAvailable: true)
        }
        let backgroundSamples = (30..<60).map {
            InferenceSample(
                uptimeSeconds: Double($0) * 0.32, phase: .locked, latencyMilliseconds: error == nil ? background : nil,
                error: error, neuralEngineAvailable: nil)
        }
        return BackgroundInferenceAnalysis(
            samples: foregroundSamples + backgroundSamples,
            cpuBaseline: cpu.map { LatencySummary(milliseconds: Array(repeating: $0, count: 30))! },
            expectedInterval: hop)
    }

    @Test func fallbackTheCPUCannotCarrySwitchesToTheSystemTranscriber() {
        let analysis = Self.analysis(foreground: 40, background: 300, cpu: 310)
        #expect(BackgroundInferenceMitigation.recommended(for: analysis, hop: Self.hop) == .switchToSystemTranscriber)
    }

    @Test func errorsWithASlowCPUSwitchToTheSystemTranscriber() {
        let analysis = Self.analysis(foreground: 40, background: nil, error: "E5", cpu: 400)
        #expect(BackgroundInferenceMitigation.recommended(for: analysis, hop: Self.hop) == .switchToSystemTranscriber)
    }

    @Test func degradedButWithinBudgetIsAccepted() {
        let analysis = Self.analysis(foreground: 40, background: 80, cpu: 400)
        #expect(analysis.verdict == .degraded(slowdown: 2))
        #expect(BackgroundInferenceMitigation.recommended(for: analysis, hop: Self.hop) == .acceptCPUFallback)
    }

    @Test func inconclusiveRunsAreRepeated() {
        let analysis = BackgroundInferenceAnalysis(samples: [], cpuBaseline: nil, expectedInterval: Self.hop)
        #expect(BackgroundInferenceMitigation.recommended(for: analysis, hop: Self.hop) == .rerunProbe)
    }

    @Test func everyMitigationHasASummary() {
        for mitigation in BackgroundInferenceMitigation.allCases {
            #expect(!mitigation.summary.isEmpty)
        }
    }
}
