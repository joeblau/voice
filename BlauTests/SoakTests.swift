import BlauAudio
import BlauRealtime
import BlauTelemetry
import Foundation
import Testing

@testable import Blau

/// The long-session soak test (#76): `SoakRun` drives the whole pipeline
/// with mixed audio against the fake realtime server and judges the run.
/// `BlauPerfTests/SoakTests` runs it for one or two hours in a Release
/// build (`make soak`); these check the harness itself, in Debug, on a few
/// minutes of audio.
@Suite("Soak")
@MainActor
struct SoakTests {
    @Test func configurationComesFromTheLaunchEnvironment() {
        let defaults = SoakConfiguration(environment: [:])
        #expect(defaults.duration == .seconds(7_200))
        #expect(defaults.speed == 10)
        #expect(defaults.recognizer == .scripted)
        #expect(defaults.rolloverAt == .seconds(72 * 60))
        #expect(defaults.sampleInterval == .seconds(60))

        let custom = SoakConfiguration(environment: [
            "BLAU_SOAK_MINUTES": "20", "BLAU_SOAK_SPEED": "realtime", "BLAU_SOAK_ASR": "parakeet",
            "BLAU_SOAK_ROLLOVER_MINUTES": "5", "BLAU_SOAK_SAMPLE_SECONDS": "30",
        ])
        #expect(custom.duration == .seconds(1_200))
        #expect(custom.speed == 1)
        #expect(custom.recognizer == .parakeet)
        #expect(custom.rolloverAt == .seconds(300))
        #expect(custom.sampleInterval == .seconds(30))

        let short = SoakConfiguration(environment: ["BLAU_SOAK_MINUTES": "10"])
        #expect(short.rolloverAt == .seconds(360), "60% of the session")
        #expect(short.sampleInterval == .seconds(10), "at least 10 s")

        #expect(SoakConfiguration(environment: ["BLAU_SOAK_SPEED": "max"]).speed == nil)
        #expect(SoakConfiguration(environment: ["BLAU_SOAK_ROLLOVER_MINUTES": "xai"]).rolloverAt == nil)
        // Nonsense keeps the defaults.
        let invalid = SoakConfiguration(environment: [
            "BLAU_SOAK_MINUTES": "-1", "BLAU_SOAK_SPEED": "fast", "BLAU_SOAK_ASR": "whisper",
            "BLAU_SOAK_ROLLOVER_MINUTES": "soon", "BLAU_SOAK_SAMPLE_SECONDS": "0",
        ])
        #expect(invalid == defaults)

        #expect(SoakConfiguration.isRequested(in: ["BLAU_SOAK": "1"]))
        #expect(!SoakConfiguration.isRequested(in: [:]))
    }

    @Test func theSessionScheduleIsScaledToTheRun() {
        // Two hours at 10x, renewal at 72 audio minutes: xAI's 110 minutes
        // become 7.2 minutes of wall time.
        let soak = SoakConfiguration(environment: [:])
        #expect(abs(soak.sessionTimeScale - 10 * 110 / 72) < 1e-9)
        let continuity = soak.continuity
        #expect(abs((continuity.rolloverAfter ?? .zero).timeInterval - 432) < 0.001)
        #expect(abs(continuity.rolloverDeadline.timeInterval - 432 * 118 / 110) < 0.001)
        // Every session ends by its deadline, so a run lasting a deadline
        // and a bit has renewed at least once, and twice after two.
        let deadline = continuity.rolloverDeadline
        #expect(soak.expectedRollovers(wallTime: deadline * 0.9) == 0)
        #expect(soak.expectedRollovers(wallTime: deadline + .seconds(5)) == 1)
        #expect(soak.expectedRollovers(wallTime: deadline * 2 + .seconds(5)) == 2)

        // xAI's own schedule, only sped up.
        let xai = SoakConfiguration(environment: ["BLAU_SOAK_ROLLOVER_MINUTES": "xai", "BLAU_SOAK_SPEED": "realtime"])
        #expect(xai.sessionTimeScale == 1)
        #expect(xai.continuity == SessionContinuityConfiguration.standard)
    }

    @Test func controllerStatusLabels() {
        #expect(SoakController.Status.idle.label == "idle")
        #expect(SoakController.Status.running.label == "running")
        #expect(SoakController.Status.finished(passed: true, failures: []).label == "passed")
        #expect(
            SoakController.Status.finished(passed: false, failures: ["memory.slope", "topics.count"]).label
                == "failed: memory.slope, topics.count")
        #expect(SoakController.Status.error("boom").label == "error: boom")
    }

    /// `SOAK_ASR=parakeet` without the installed models must not run (and
    /// pass) on the scripted recognizer and the energy VAD.
    @Test func aParakeetSoakWithoutItsModelsFailsInsteadOfFallingBack() async throws {
        let script = ConversationAudioScript.session(lasting: .seconds(30))
        await #expect(throws: SoakRun.SetupError.modelsMissing(["Silero VAD", "Parakeet EOU"])) {
            _ = try await SoakRun.models(.parakeet, vadDirectory: nil, asrDirectory: nil, script: script)
        }
        let someDirectory = FileManager.default.temporaryDirectory
        await #expect(throws: SoakRun.SetupError.modelsMissing(["Parakeet EOU"])) {
            _ = try await SoakRun.models(.parakeet, vadDirectory: someDirectory, asrDirectory: nil, script: script)
        }
        // The whole run fails the same way, before it synthesizes or plays
        // anything.
        let configuration = SoakConfiguration(duration: .seconds(60), speed: nil, recognizer: .parakeet)
        await #expect(throws: SoakRun.SetupError.modelsMissing(["Silero VAD", "Parakeet EOU"])) {
            _ = try await SoakRun(configuration: configuration).run()
        }

        // The scripted soak needs no models and judges line by line.
        let scripted = try await SoakRun.models(.scripted, vadDirectory: nil, asrDirectory: nil, script: script)
        #expect(scripted.recognizerName == "scripted ASR")
        #expect(scripted.voiceActivityName == "energy VAD")
        #expect(scripted.transcript == .scripted)
        let speech = try await SoakRun.speech(for: .scripted)
        #expect(speech.topics.isEmpty, "the hermetic signal, nothing synthesized")
    }

    /// The screen keeps Start disabled for a Parakeet soak until both models
    /// are installed (the fixture manager has installed nothing before it
    /// starts).
    @Test func aParakeetSoakWaitsForTheInstalledModels() {
        let models = SpeechModels.fixtureManager(
            root: FileManager.default.temporaryDirectory.appending(path: "soak-models-\(UUID().uuidString)"))
        let parakeet = SoakController(
            configuration: SoakConfiguration(duration: .seconds(60), speed: 1, recognizer: .parakeet))
        #expect(parakeet.missingModels(models) == ["Silero VAD", "Parakeet EOU"])
        let scripted = SoakController(configuration: SoakConfiguration(duration: .seconds(60), speed: 1))
        #expect(scripted.missingModels(models).isEmpty)
    }

    /// `CaptureStatistics.droppedFrames(frameLength:)` already counts the
    /// subscriber drops: a sample holds them once, and apart.
    @Test func subscriberDropsAreSampledOnce() {
        var capture = CaptureStatistics()
        capture.framesPublished = 10_000
        capture.droppedSamples = 640  // two frames lost in capture
        capture.subscriberDroppedFrames = 5
        let frames = SoakSampler.frameCounts(capture)
        #expect(frames.delivered == 10_000)
        #expect(frames.dropped == 7, "2 lost in capture + 5 missed by a subscriber, not 12")
        #expect(frames.missedBySubscribers == 5)
        let loss = SoakAnalysis.frameLoss(
            SoakSample(
                audioSeconds: 200, wallSeconds: 20, footprintBytes: nil, framesDelivered: frames.delivered,
                framesDropped: frames.dropped, subscriberFramesDropped: frames.missedBySubscribers))
        #expect(loss.lostInCapture == 2)
        #expect(loss.captured == 10_002)
        #expect(loss.missedBySubscribers == 5)
        #expect(loss.published == 10_000)
    }

    /// Six minutes of audio at 20x: about 20 s, with the session renewed
    /// part-way through and the TV in the interludes rejected.
    @Test(.timeLimit(.minutes(3)))
    func aShortSoakRunsEveryStageAndRenewsTheSession() async throws {
        let configuration = SoakConfiguration(duration: .seconds(360), speed: 20)
        let report = try await SoakRun(configuration: configuration).run()
        let outcome = report.outcome

        #expect(outcome.lines > 10)
        #expect(outcome.userUtterances == outcome.lines, "\(report.summary)")
        #expect(outcome.agentReplies == outcome.lines)
        #expect(outcome.failedTurns == 0)
        #expect(outcome.backgroundBursts > 0)
        #expect(outcome.backgroundScores > 0)
        #expect(outcome.backgroundRejected == outcome.backgroundScores)
        #expect(outcome.userAccepted == outcome.userScores)
        #expect(outcome.gateCommitted == outcome.lines, "every line passed the voice ID gate")
        #expect(outcome.gateDiscarded == 0, "the TV carries no words for the scripted recognizer")
        #expect(outcome.expectedRollovers >= 1, "the run outlasts the scaled deadline")
        #expect(outcome.rollovers >= 1)
        #expect(outcome.reseeds >= outcome.rollovers)
        #expect(outcome.connections >= outcome.rollovers + 1)
        #expect(outcome.topicBoundaries >= 1)

        #expect(report.samples.count >= 30, "a sample every 10 s of audio")
        #expect(report.samples.first?.audioSeconds == 0)
        #expect(report.samples.last?.audioSeconds == report.setup.audioSeconds)
        #expect(report.samples.allSatisfy { $0.footprintBytes != nil })
        #expect(report.samples.last?.agentReplies == outcome.lines)
        #expect(report.samples.last.map { $0.framesDelivered > 0 } == true)
        #expect(report.setup.recognizer == "scripted ASR")
        #expect(outcome.transcript == .scripted)
        #expect(report.samples.last?.subscriberFramesDropped == 0)
        #expect(report.setup.audio.contains("TV"))

        // Everything but memory (too short a run to read a slope from) is
        // judged as a long run would be.
        for check in report.checks where check.name != "memory.slope" {
            #expect(check.passed, "\(check.name): \(check.measured) (\(check.limit)) \(check.detail ?? "")")
        }
        let json = try report.jsonData()
        #expect(try SoakReport.decode(json) == report)
    }
}
