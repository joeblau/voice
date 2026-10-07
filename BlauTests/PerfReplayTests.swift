import BlauCore
import Foundation
import Testing

@testable import Blau

/// The performance suite's scripted session (#73): `PerfReplay` runs the
/// whole pipeline end to end and is deterministic, so its measurements only
/// move when the code does. The perf tests (`BlauPerfTests`) measure it in a
/// Release build; these check it works, in Debug.
@Suite("Perf replay")
@MainActor
struct PerfReplayTests {
    @Test func configurationComesFromTheLaunchEnvironment() {
        let defaults = PerfReplayConfiguration(environment: [:])
        #expect(defaults.duration == .seconds(300))
        #expect(defaults.speed == 10)
        #expect(defaults.recognizer == .scripted)

        let custom = PerfReplayConfiguration(environment: [
            "BLAU_PERF_REPLAY_SECONDS": "60", "BLAU_PERF_REPLAY_SPEED": "max", "BLAU_PERF_REPLAY_ASR": "parakeet",
        ])
        #expect(custom.duration == .seconds(60))
        #expect(custom.speed == nil)
        #expect(custom.recognizer == .parakeet)
        #expect(PerfReplayConfiguration(environment: ["BLAU_PERF_REPLAY_SPEED": "realtime"]).speed == 1)
        #expect(PerfReplayConfiguration(environment: ["BLAU_PERF_REPLAY_SPEED": "4"]).speed == 4)
        // Nonsense keeps the defaults.
        let invalid = PerfReplayConfiguration(environment: [
            "BLAU_PERF_REPLAY_SECONDS": "-3", "BLAU_PERF_REPLAY_SPEED": "fast", "BLAU_PERF_REPLAY_ASR": "whisper",
        ])
        #expect(invalid == defaults)

        #expect(PerfReplayConfiguration.isRequested(in: ["BLAU_PERF_REPLAY": "1"]))
        #expect(!PerfReplayConfiguration.isRequested(in: [:]))
    }

    @Test(.timeLimit(.minutes(2)))
    func aShortSessionRunsTheWholePipelineDeterministically() async throws {
        let configuration = PerfReplayConfiguration(duration: .seconds(60), speed: nil)
        let first = try await PerfReplay(configuration: configuration).run()
        let second = try await PerfReplay(configuration: configuration).run()

        #expect(first.isComplete, "\(first.summary)")
        #expect(first.lines >= 3)
        #expect(first.userUtterances == first.lines)
        #expect(first.agentReplies == first.lines)
        #expect(first.topicUnits == first.lines)
        #expect(first.memorySearches == first.lines)
        #expect(first.memoryChunks == first.lines)
        #expect(first.verifications >= first.lines)
        #expect(first.accepted == first.verifications, "every segment is the enrolled speaker")
        #expect(first.saves > 0)
        #expect(first.replyAudioSeconds > Double(first.lines) * 3)
        #expect(first.audioSeconds >= 60)
        #expect(first.recognizer == "scripted ASR")
        #expect(first.voiceActivity == "energy VAD")

        // Everything but timing repeats exactly.
        func counts(_ report: PerfReplayReport) -> [Int] {
            [
                report.lines, report.userUtterances, report.agentReplies, report.topicUnits, report.topicBoundaries,
                report.memoryChunks, report.memorySearches, report.verifications, report.accepted,
            ]
        }
        #expect(counts(first) == counts(second))
    }

    @Test func aLongSessionChangesTopic() async throws {
        // Two and a half topics' worth of exchanges at 16 s each.
        let report = try await PerfReplay(configuration: .init(duration: .seconds(240), speed: nil)).run()
        #expect(report.isComplete, "\(report.summary)")
        #expect(report.topicBoundaries >= 1, "\(report.summary)")
    }

    @Test func probesMatchTheVoiceprint() {
        let voiceprint = ReplayVoiceprint()
        let segment = SpeechSegment(
            id: 1, sampleRange: 16_000..<64_000, sampleRate: 16_000, isContinuation: false, endReason: .silence,
            detectedAt: 70_000, peakProbability: 1, meanProbability: 0.9)
        let result = voiceprint.scorer.verify(voiceprint.probe(for: segment), config: voiceprint.config)
        #expect(result.decision == .accept, "score \(result.score)")
        #expect(result.score < 0.95, "probes vary like real speech")
    }

    @Test func controllerStatusLabels() {
        #expect(PerfReplayController.Status.idle.label == "idle")
        #expect(PerfReplayController.Status.running(2).label == "running 2")
        #expect(PerfReplayController.Status.finished(2).label == "finished 2")
        #expect(PerfReplayController.Status.failed(3, "boom").label == "failed 3: boom")
        #expect(!PerfReplayController().isRunning)
    }
}
