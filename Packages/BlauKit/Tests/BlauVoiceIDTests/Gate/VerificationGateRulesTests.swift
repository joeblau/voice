import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Verification gate rules")
struct VerificationGateRulesTests {
    static func verdict(
        _ decision: SpeakerDecision, seconds: Double, basis: SegmentVerdict.Basis = .scored
    ) -> SegmentVerdict {
        SegmentVerdict(
            segmentID: 0, decision: decision, score: nil, scoredDuration: .zero, speechDuration: .seconds(seconds),
            basis: basis)
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
        ([(SpeakerDecision, Double)](), SpeakerDecision.uncertain),
        ([(.uncertain, 2), (.uncertain, 2)], .uncertain),
        ([(.accept, 2), (.uncertain, 0.5)], .accept),
        ([(.reject, 2), (.uncertain, 0.5)], .reject),
    ])
    func combiningWithoutAConflict(parts: [(SpeakerDecision, Double)], expected: SpeakerDecision) {
        let verdicts = parts.map { Self.verdict($0.0, seconds: $0.1) }
        #expect(VerificationGateRules.combine(verdicts, minorityShare: 1.0 / 3) == expected)
    }

    /// Uncertain speech counts in the total: a few accepted (or rejected)
    /// words don't carry a long stretch voice ID couldn't attribute, which
    /// goes through the uncertain policy instead.
    @Test func mostlyUncertainSpeechIsUncertain() {
        let combine = { (parts: [(SpeakerDecision, Double)]) in
            VerificationGateRules.combine(parts.map { Self.verdict($0.0, seconds: $0.1) }, minorityShare: 1.0 / 3)
        }
        // The owner's 1.4 s, then 6 s of a voice voice ID can't place: 19%.
        #expect(combine([(.accept, 1.4), (.uncertain, 6)]) == .uncertain)
        #expect(combine([(.reject, 1.4), (.uncertain, 6)]) == .uncertain)
        #expect(combine([(.accept, 2), (.uncertain, 2)]) == .uncertain)
        // Accepted speech that dominates still accepts (80%, 75%).
        #expect(combine([(.accept, 2), (.uncertain, 0.5)]) == .accept)
        #expect(combine([(.uncertain, 1), (.accept, 3)]) == .accept)
        #expect(combine([(.reject, 3), (.uncertain, 1)]) == .reject)
        // A dominant majority over a conflict and some uncertainty (69%).
        #expect(combine([(.accept, 7), (.reject, 3), (.uncertain, 0.2)]) == .accept)
        // A close conflict with a little uncertainty stays uncertain.
        #expect(combine([(.accept, 3), (.reject, 2), (.uncertain, 0.2)]) == .uncertain)
        // Exactly two thirds decides, as documented.
        #expect(combine([(.accept, 2), (.uncertain, 1)]) == .accept)
        #expect(combine([(.reject, 2), (.uncertain, 1)]) == .reject)
    }

    /// A short segment that is uncertain only because it had nothing recent
    /// to inherit carries no evidence about who spoke, so it doesn't count
    /// against the scored speech: the owner's "Okay, so… [pause] what about
    /// tomorrow?" accepts. Scored, inherited, unscored and timed-out
    /// uncertain parts still count.
    @Test func aShortOpenerWithNothingToInheritDoesNotCount() {
        let combine = { (parts: [(SpeakerDecision, Double, SegmentVerdict.Basis)]) in
            VerificationGateRules.combine(
                parts.map { Self.verdict($0.0, seconds: $0.1, basis: $0.2) }, minorityShare: 1.0 / 3)
        }
        #expect(combine([(.uncertain, 0.7, .noRecentDecision), (.accept, 1.3, .scored)]) == .accept)
        #expect(combine([(.uncertain, 0.65, .noRecentDecision), (.accept, 1.1, .scored)]) == .accept)
        #expect(combine([(.uncertain, 0.9, .noRecentDecision), (.reject, 1.1, .scored)]) == .reject)
        // Several short unattributed parts around a scored one.
        #expect(
            combine([
                (.uncertain, 0.8, .noRecentDecision), (.accept, 1.2, .scored), (.uncertain, 0.9, .noRecentDecision),
            ]) == .accept)
        // Nothing but unattributed short parts: still uncertain.
        #expect(combine([(.uncertain, 0.7, .noRecentDecision), (.uncertain, 0.6, .noRecentDecision)]) == .uncertain)
        // Real evidence of uncertainty still counts.
        #expect(combine([(.accept, 1.4, .scored), (.uncertain, 6, .scored)]) == .uncertain)
        for basis: SegmentVerdict.Basis in [.scored, .inherited(from: 3), .unscored, .timedOut] {
            #expect(combine([(.uncertain, 0.7, basis), (.accept, 1.3, .scored)]) == .uncertain)
        }
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
