import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Verification gate rules")
struct VerificationGateRulesTests {
    static func verdict(_ decision: SpeakerDecision, seconds: Double) -> SegmentVerdict {
        SegmentVerdict(
            segmentID: 0, decision: decision, score: nil, scoredDuration: .zero, speechDuration: .seconds(seconds),
            basis: .scored)
    }

    static func score(_ decision: SpeakerDecision, seconds: Double, score: Float = 0) -> SpeakerScore {
        SpeakerScore(
            score: score, decision: decision, audioDuration: .seconds(seconds),
            thresholds: VoiceIDConfig.calibrated.short)
    }

    @Test func theLongestScoreDecides() {
        #expect(VerificationGateRules.decision(from: []) == nil)
        let scores = [
            Self.score(.uncertain, seconds: 1.5), Self.score(.accept, seconds: 3), Self.score(.reject, seconds: 2),
        ]
        #expect(VerificationGateRules.decision(from: scores)?.decision == .accept)
        // Of equal lengths, the latest.
        let equal = [Self.score(.accept, seconds: 3, score: 0.5), Self.score(.reject, seconds: 3, score: 0.1)]
        #expect(VerificationGateRules.decision(from: equal)?.score == 0.1)
    }

    @Test(arguments: [
        ([SpeakerDecision](), SpeakerDecision.uncertain),
        ([.uncertain, .uncertain], .uncertain),
        ([.accept, .uncertain], .accept),
        ([.reject, .uncertain], .reject),
    ])
    func combiningWithoutAConflict(decisions: [SpeakerDecision], expected: SpeakerDecision) {
        let verdicts = decisions.map { Self.verdict($0, seconds: 2) }
        #expect(VerificationGateRules.combine(verdicts, minorityShare: 1.0 / 3) == expected)
    }

    @Test func aConflictGoesToTheMajorityUnlessItIsClose() {
        let combine = { (accept: Double, reject: Double) in
            VerificationGateRules.combine(
                [Self.verdict(.accept, seconds: accept), Self.verdict(.reject, seconds: reject)], minorityShare: 1.0 / 3
            )
        }
        #expect(combine(5, 1) == .accept)
        #expect(combine(1, 5) == .reject)
        #expect(combine(2, 3) == .uncertain)
        #expect(combine(3, 3) == .uncertain)
    }

    @Test func dispositions() {
        let rules = VerificationGateRules.self
        let policy = UncertainSpeechPolicy.standard
        #expect(
            rules.disposition(for: .accept, duration: .seconds(0.5), isTurnActive: false, policy: policy) == .accepted)
        #expect(rules.disposition(for: .reject, duration: .seconds(9), isTurnActive: true, policy: policy) == .rejected)
        #expect(
            rules.disposition(for: .uncertain, duration: .seconds(2), isTurnActive: true, policy: policy)
                == .uncertainCommitted)
        #expect(
            rules.disposition(for: .uncertain, duration: .seconds(1.9), isTurnActive: true, policy: policy)
                == .uncertainDiscarded)
        #expect(
            rules.disposition(for: .uncertain, duration: .seconds(5), isTurnActive: false, policy: policy)
                == .uncertainDiscarded)
        #expect(GatedUtterance.Disposition.uncertainCommitted.isCommitted)
        #expect(!GatedUtterance.Disposition.rejected.isCommitted)
    }

    @Test func inheritance() {
        let rate = 16_000
        let window = Duration.seconds(5)
        let inherited = VerificationGateRules.inherited(
            previous: (.accept, 16_000), start: 16_000 * 5, sampleRate: rate, window: window)
        #expect(inherited.decision == .accept && inherited.isInherited)
        let tooLate = VerificationGateRules.inherited(
            previous: (.accept, 16_000), start: 16_000 * 6, sampleRate: rate, window: window)
        #expect(tooLate.decision == .uncertain && !tooLate.isInherited)
        let nothing = VerificationGateRules.inherited(previous: nil, start: 0, sampleRate: rate, window: window)
        #expect(nothing.decision == .uncertain && !nothing.isInherited)
    }

    /// What the evaluation harness replays: the longest window the speech
    /// fills decides, with that window's thresholds.
    @Test func simulatedDecisions() {
        let config = VoiceIDConfig.calibrated
        let gate = VerificationGateConfiguration.standard
        let scores: [(audioDuration: Duration, score: Float)] = [(.seconds(1.5), 0.30), (.seconds(3), 0.45)]
        #expect(
            VerificationGateRules.simulatedDecision(
                scores: scores, speechDuration: .seconds(6), config: config, gate: gate) == .accept)
        // Only 2 s of speech: the 3 s score doesn't exist.
        #expect(
            VerificationGateRules.simulatedDecision(
                scores: scores, speechDuration: .seconds(2), config: config, gate: gate) == .uncertain)
        #expect(
            VerificationGateRules.simulatedDecision(
                scores: scores, speechDuration: .seconds(0.8), config: config, gate: gate) == nil)
    }

    @Test func theTurnStaysActiveForAWhileAfterEitherSideSpoke() {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        #expect(!activity.isActive)
        activity.agentActivityChanged(true)
        clock.advance(by: .seconds(30))
        #expect(activity.isActive)
        activity.agentActivityChanged(false)
        clock.advance(by: .seconds(9))
        #expect(activity.isActive)
        clock.advance(by: .seconds(2))
        #expect(!activity.isActive)
        activity.userUtteranceCommitted()
        clock.advance(by: .seconds(5))
        #expect(activity.isActive)
        activity.reset()
        #expect(!activity.isActive)
    }
}

@Suite("Speaker verifier")
struct SpeakerVerifierTests {
    static func voiceprint(
        _ embeddings: [SpeakerEmbedding], model: String = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM.identifier
    ) -> Voiceprint {
        Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: model, centroid: SpeakerEmbedding.mean(of: embeddings)!,
            sets: [VoiceprintSet(deviceModel: "Mac", embeddings: embeddings, createdAt: .now)], createdAt: .now,
            updatedAt: .now)
    }

    static func ownerVoiceprint(_ embedder: ScriptedSpeakerEmbedder) async throws -> Voiceprint {
        let clips = [6, 7, 8].map { EnrollmentAudio.clip(.owner, duration: .seconds(Double($0))) }
        return voiceprint(try await embedder.embed(clips))
    }

    @Test func scoresTheOwnerAboveSomeoneElse() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let signposts = RecordingSignpostBackend()
        let gauges = PerformanceGauges()
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: try await Self.ownerVoiceprint(embedder),
            signposter: Signposter(category: .voiceID, backend: signposts), gauges: gauges)

        let owner = try await verifier.verify(EnrollmentAudio.clip(.owner, duration: .seconds(2)))
        let other = try await verifier.verify(EnrollmentAudio.clip(.other, duration: .seconds(2)))

        #expect(owner.decision == .accept)
        #expect(other.decision == .reject)
        #expect(owner.audioDuration == .seconds(2))
        #expect(owner.thresholds == VoiceIDConfig.calibrated.short)
        #expect(signposts.completedIntervals == ["voiceid.verify", "voiceid.verify"])
        #expect(gauges.reading(.voiceScore)?.value == Double(other.score))
        #expect(gauges.reading(.voiceThreshold)?.value == Double(VoiceIDConfig.calibrated.short.accept))
        #expect(try await verifier.evaluate(EnrollmentAudio.clip(.owner, duration: .seconds(2))) == .accept)
        #expect(await verifier.isEnrolled)
    }

    @Test func followsTheSensitivityForEveryScore() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let settings = await VoiceIDSettings(store: InMemoryVoiceIDSensitivityStore())
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: try await Self.ownerVoiceprint(embedder),
            config: { settings.currentConfig() }, gauges: PerformanceGauges())
        let speech = EnrollmentAudio.clip(.owner, duration: .seconds(2))
        let calibrated = try await verifier.verify(speech)
        await MainActor.run { settings.level = 1 }
        let strict = try await verifier.verify(speech)
        #expect(strict.thresholds.accept == calibrated.thresholds.accept + VoiceIDSensitivity.maximumThresholdShift)
    }

    @Test func refusesAVoiceprintFromAnotherModel() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let stale = Self.voiceprint(
            [SpeakerEmbedding(normalizing: [1, 0], modelIdentifier: "old-model", audioDuration: .seconds(3))!],
            model: "old-model")
        #expect(throws: SpeakerVerifierError.self) {
            try SpeakerVerifier(embedder: embedder, voiceprint: stale)
        }
        let config = VoiceIDConfig(
            modelIdentifier: "other", scoring: .cosineCentroid, short: VoiceIDConfig.calibrated.short,
            long: VoiceIDConfig.calibrated.long)
        let voiceprint = try await Self.ownerVoiceprint(embedder)
        #expect(throws: SpeakerVerifierError.configModelMismatch(config: "other", embedder: embedder.model.identifier))
        {
            try SpeakerVerifier(embedder: embedder, voiceprint: voiceprint, config: { config })
        }
        #expect(throws: SpeakerVerifierError.scorer(.missingCohort)) {
            try SpeakerVerifier(
                embedder: embedder, voiceprint: voiceprint,
                config: {
                    VoiceIDConfig(
                        modelIdentifier: embedder.model.identifier, scoring: .asNormCentroid,
                        short: VoiceIDConfig.calibrated.short, long: VoiceIDConfig.calibrated.long)
                })
        }
    }
}
