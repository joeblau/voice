import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The soak report's acceptance rules (docs/background.md).
@Suite("Long session report")
struct LongSessionReportTests {
    /// 35 minutes, 30.5 of them locked, live throughout.
    static var goodRun: AudioSessionKeeper.Statistics {
        var statistics = AudioSessionKeeper.Statistics()
        statistics.foregroundSeconds = 180
        statistics.backgroundSeconds = 90
        statistics.lockedSeconds = 1_830
        statistics.backgroundEntries = 1
        return statistics
    }

    static func vad(seconds: Double) -> LongSessionReport.VAD {
        var statistics = VoiceActivityStatistics()
        statistics.samplesProcessed = Int64(seconds * 16_000)
        statistics.chunksAnalyzed = 100
        return LongSessionReport.VAD(model: "Silero VAD (Core ML)", statistics: statistics)
    }

    static let inference = BackgroundInferenceMonitor.Snapshot(
        phase: .foreground, mitigation: .shipping, stages: [], switches: [])

    static func verdict(
        _ keeper: AudioSessionKeeper.Statistics,
        vad: LongSessionReport.VAD? = vad(seconds: 2_100),
        inference: BackgroundInferenceMonitor.Snapshot = inference
    ) -> LongSessionReport.Verdict {
        LongSessionReport.evaluate(keeper: keeper, vad: vad, inference: inference, rules: .init())
    }

    @Test func aThirtyMinuteLockedRunThatStayedLivePasses() {
        let verdict = Self.verdict(Self.goodRun)
        #expect(verdict.passed)
        #expect(verdict.findings.isEmpty)
    }

    @Test func tooShortALockedRunFails() {
        var keeper = Self.goodRun
        keeper.lockedSeconds = 600
        let verdict = Self.verdict(keeper, vad: Self.vad(seconds: 870))
        #expect(!verdict.passed)
        #expect(verdict.findings == ["Locked for 10.0 min; the test needs 30.0"])
    }

    @Test func anUnrecoveredStallFails() {
        var keeper = Self.goodRun
        keeper.stallsDetected = 2
        keeper.stallsRecovered = 1
        #expect(Self.verdict(keeper).findings == ["1 of 2 capture stall(s) not recovered"])
    }

    @Test func downtimeFailsUnlessACallCausedIt() {
        var keeper = Self.goodRun
        keeper.notLiveSeconds = 60
        #expect(Self.verdict(keeper).findings == ["Audio wasn't live for 60 s without an interruption"])
        keeper.interruptions = 1
        #expect(Self.verdict(keeper).passed)
    }

    @Test func aVADThatFellBehindFails() {
        #expect(
            Self.verdict(Self.goodRun, vad: Self.vad(seconds: 1_500)).findings == [
                "The VAD analysed 71% of the session's audio"
            ])
        #expect(Self.verdict(Self.goodRun, vad: nil).passed, "a run without the VAD is judged on the audio alone")
    }

    @Test func anExhaustedModelStageFails() {
        var policy = BackgroundInferencePolicy(configuration: .init(mitigation: .reloadOnCPUWhenBackgrounded))
        _ = policy.register(.init(name: "vad", ladder: [.neuralEngine, .cpu], budget: .milliseconds(256)))
        _ = policy.setPhase(.locked)
        _ = policy.switchFailed(stage: "vad", backend: .cpu, error: "load failed")
        let inference = BackgroundInferenceMonitor.Snapshot(
            phase: .locked, mitigation: .reloadOnCPUWhenBackgrounded, stages: policy.statuses, switches: [])
        #expect(
            Self.verdict(Self.goodRun, inference: inference).findings == [
                "The vad stage couldn't keep up on any backend off screen (1 time)"
            ])
    }

    /// The real procedure: the stage runs out of backends while locked, the
    /// user unlocks (which clears `isExhausted`) and then stops the run. The
    /// verdict must still fail.
    @Test func aStageExhaustedWhileLockedStillFailsAfterUnlocking() {
        var policy = BackgroundInferencePolicy(configuration: .init(mitigation: .keepNeuralEngine))
        _ = policy.register(.init(name: "vad", ladder: [.neuralEngine, .cpu], budget: .milliseconds(256)))
        _ = policy.setPhase(.locked)
        // Errors move it to the CPU, which keeps failing: nowhere left.
        for _ in 0..<2 { _ = policy.observe(.init(stage: "vad", outcome: .failed(description: "E5RT"))) }
        while let (stage, backend) = policy.pendingSwitch() {
            policy.switchCompleted(stage: stage, to: backend)
        }
        for _ in 0..<2 { _ = policy.observe(.init(stage: "vad", outcome: .failed(description: "E5RT"))) }
        #expect(policy.status(of: "vad")?.isExhausted == true)

        _ = policy.setPhase(.foreground)
        let status = policy.status(of: "vad")
        #expect(status?.isExhausted == false, "unlocking retries every backend")
        #expect(status?.exhaustedOffScreen == 1)

        let inference = BackgroundInferenceMonitor.Snapshot(
            phase: .foreground, mitigation: .keepNeuralEngine, stages: policy.statuses, switches: [])
        let verdict = Self.verdict(Self.goodRun, inference: inference)
        #expect(!verdict.passed)
        #expect(verdict.findings == ["The vad stage couldn't keep up on any backend off screen (1 time)"])
    }

    @Test func roundTripsThroughJSON() throws {
        var capture = CaptureStatistics()
        capture.framesPublished = 105_000
        let report = LongSessionReport(
            device: .current,
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_002_100),
            finalStatus: "live",
            keeper: Self.goodRun,
            capture: .init(capture),
            vad: Self.vad(seconds: 2_100),
            inference: Self.inference
        )
        #expect(report.verdict.passed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LongSessionReport.self, from: report.jsonData())
        #expect(decoded == report)
    }
}
