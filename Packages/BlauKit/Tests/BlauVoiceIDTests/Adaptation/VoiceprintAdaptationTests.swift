import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

/// Unit embeddings and evidence for the adaptation tests.
enum AdaptationFixtures {
    static let model = TestEmbeddings.model
    static let thresholds = VoiceIDConfig.calibrated.long

    /// The unit vector with `components` (axis: weight), normalized.
    static func unit(_ components: [Int: Float], duration: Duration = .seconds(4)) -> SpeakerEmbedding {
        var vector = [Float](repeating: 0, count: model.dimension)
        for (axis, weight) in components { vector[axis] = weight }
        return SpeakerEmbedding(normalizing: vector, modelIdentifier: model.identifier, audioDuration: duration)!
    }

    /// The enrollment centroid in these tests: axis 0.
    static let anchor = unit([0: 1], duration: .zero)

    /// A segment of `embedding`, scored by the gate at its cosine with the
    /// anchor unless `score` says otherwise.
    static func evidence(
        _ embedding: SpeakerEmbedding, score: Float? = nil, speech: Duration = .seconds(4), snr: Float? = 25,
        clipped: Double = 0
    ) -> VoiceprintAdaptationEvidence {
        VoiceprintAdaptationEvidence(
            embedding: embedding, score: score ?? embedding.cosineSimilarity(to: anchor), thresholds: thresholds,
            speechDuration: speech, signalToNoise: snr, clippedFraction: clipped)
    }

    static func adaptation(
        centroid: SpeakerEmbedding = anchor, policy: VoiceprintAdaptationPolicy = .standard
    ) throws -> VoiceprintAdaptation {
        try VoiceprintAdaptation(
            enrollmentCentroid: anchor, centroid: centroid, scoring: .cosineCentroid, policy: policy)
    }

    /// The owner, a little off the anchor: accepted with a wide margin.
    static let owner = unit([0: 1, 1: 0.4])
}

@Suite("Voiceprint adaptation")
struct VoiceprintAdaptationTests {
    typealias F = AdaptationFixtures

    @Test func movesTheCentroidByTheLearningRate() throws {
        var adaptation = try F.adaptation()
        let outcome = adaptation.consider(F.evidence(F.owner))
        guard case .updated(let update) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let expected = SpeakerEmbedding(
            normalizing: zip(F.anchor.vector, F.owner.vector).map { 0.95 * $0 + 0.05 * $1 },
            modelIdentifier: F.model.identifier, audioDuration: .zero)!
        #expect(adaptation.centroid.cosineSimilarity(to: expected) > 0.99999)
        #expect(update.count == 1)
        #expect(!update.isCapped)
        #expect(update.drift > 0 && update.drift < 0.01)
        #expect(abs(update.drift - adaptation.drift) < 1e-6)
        #expect(abs(update.enrollmentScore - F.owner.cosineSimilarity(to: F.anchor)) < 1e-5)
        #expect(adaptation.hasChanges)
        #expect(adaptation.snapshot == F.anchor)
    }

    @Test func onlyClearEvidenceMovesIt() throws {
        let cases: [(VoiceprintAdaptationEvidence, VoiceprintAdaptation.SkipReason)] = [
            // Speech of exactly 3 s, or an embedding of under 3 s.
            (F.evidence(F.owner, speech: .seconds(3)), .tooShort),
            (F.evidence(F.unit([0: 1, 1: 0.4], duration: .seconds(2.5)), speech: .seconds(5)), .tooShort),
            (F.evidence(F.owner, snr: 12), .noisy),
            (F.evidence(F.owner, snr: nil), .noisy),
            (F.evidence(F.owner, clipped: 0.01), .clipped),
            // Accepted (T_hi 0.40) but not by the 0.10 margin.
            (F.evidence(F.owner, score: 0.45), .lowScore),
            // The gate's score is high, but the enrollment centroid alone
            // doesn't accept it.
            (F.evidence(F.unit([0: 0.35, 1: 1]), score: 0.7), .lowEnrollmentScore),
            (
                VoiceprintAdaptationEvidence(
                    embedding: SpeakerEmbedding(
                        normalizing: [1, 0], modelIdentifier: "other", audioDuration: .seconds(5))!,
                    score: 0.9, thresholds: F.thresholds, speechDuration: .seconds(5), signalToNoise: 30),
                .modelMismatch
            ),
        ]
        for (evidence, reason) in cases {
            var adaptation = try F.adaptation()
            #expect(adaptation.consider(evidence) == .skipped(reason), "\(reason)")
            #expect(adaptation.centroid == F.anchor)
            #expect(adaptation.skips == [reason: 1])
            #expect(!adaptation.hasChanges)
        }
    }

    @Test func theMarginFollowsTheSensitivity() throws {
        // Strict sensitivity raises T_hi: the same score no longer clears
        // it by the margin.
        var adaptation = try F.adaptation()
        let strict = VoiceIDThresholds(accept: 0.50, reject: 0.37)
        let evidence = VoiceprintAdaptationEvidence(
            embedding: F.owner, score: 0.55, thresholds: strict, speechDuration: .seconds(4), signalToNoise: 25)
        #expect(adaptation.consider(evidence) == .skipped(.lowScore))
    }

    @Test func aConversationMakesAtMostItsQuotaOfUpdates() throws {
        var policy = VoiceprintAdaptationPolicy.standard
        policy.maximumUpdatesPerSession = 3
        var adaptation = try F.adaptation(policy: policy)
        for _ in 0..<3 {
            guard case .updated = adaptation.consider(F.evidence(F.owner)) else {
                Issue.record("expected an update")
                return
            }
        }
        #expect(adaptation.consider(F.evidence(F.owner)) == .skipped(.sessionLimit))
        #expect(adaptation.updateCount == 3)
    }

    /// However many segments push one way, the centroid stops on the cap,
    /// and moves along the cap's edge rather than through it.
    @Test func theDriftCapHolds() throws {
        var policy = VoiceprintAdaptationPolicy.standard
        policy.maximumUpdatesPerSession = 10_000
        var adaptation = try F.adaptation(policy: policy)
        // Cosine 0.6 with the anchor: accepted, and far beyond the cap.
        let pull = F.unit([0: 0.6, 1: 0.8])
        var lastUpdate: VoiceprintAdaptation.Update?
        for _ in 0..<500 {
            if case .updated(let update) = adaptation.consider(F.evidence(pull)) { lastUpdate = update }
            #expect(adaptation.drift <= policy.maximumDrift + 1e-5)
        }
        #expect(abs(adaptation.drift - policy.maximumDrift) < 1e-4)
        #expect(lastUpdate?.isCapped == true)
        #expect(adaptation.cappedCount > 0)
        // On the arc from the anchor towards the pull: no component off
        // the plane of axes 0 and 1.
        let off = adaptation.centroid.vector.enumerated().filter { $0.offset > 1 }.map { abs($0.element) }.max() ?? 0
        #expect(off < 1e-5)
        #expect(adaptation.centroid.vector[1] > 0)
    }

    @Test func theCapProjectsOntoTheArcTowardsTheCandidate() {
        let candidate = F.unit([0: 0.5, 2: 0.866])
        let (capped, isCapped) = VoiceprintAdaptation.capped(candidate, around: F.anchor, maximumDrift: 0.1)
        #expect(isCapped)
        #expect(abs(capped.cosineSimilarity(to: F.anchor) - 0.9) < 1e-5)
        #expect(capped.vector[2] > 0)
        #expect(abs(capped.vector[1]) < 1e-6)
        // Inside the cap: unchanged.
        let near = F.unit([0: 1, 2: 0.1])
        #expect(VoiceprintAdaptation.capped(near, around: F.anchor, maximumDrift: 0.1) == (near, false))
        // Exactly opposite: back to the anchor.
        let opposite = F.unit([0: -1])
        #expect(VoiceprintAdaptation.capped(opposite, around: F.anchor, maximumDrift: 0.1).embedding == F.anchor)
    }

    @Test func aStoredCentroidPastTheCapStartsOnIt() throws {
        let far = F.unit([0: 0.5, 1: 0.866])
        let adaptation = try F.adaptation(centroid: far)
        #expect(abs(adaptation.drift - 0.1) < 1e-5)
        #expect(adaptation.snapshot == adaptation.centroid)
    }

    /// Updates that pulled the centroid one way (a headset, a cold, someone
    /// else accepted with a margin) followed by the owner's usual voice the
    /// other way: the owner fits the adapted centroid worse than the
    /// snapshot, so the conversation's updates are undone and adaptation
    /// stops until the next conversation.
    @Test func rollsBackWhenTheOwnerFitsTheAdaptedCentroidWorse() throws {
        var adaptation = try F.adaptation()
        let pull = F.unit([0: 1, 1: 0.75])
        for _ in 0..<10 { _ = adaptation.consider(F.evidence(pull)) }
        #expect(adaptation.updateCount == 10)
        let moved = adaptation.centroid

        let owner = F.unit([0: 1, 1: -0.45])
        var outcomes: [VoiceprintAdaptation.Outcome] = []
        for _ in 0..<10 {
            outcomes.append(adaptation.consider(F.evidence(owner)))
            if case .rolledBack = outcomes.last { break }
        }
        guard case .rolledBack(let health) = outcomes.last else {
            Issue.record("no rollback: \(outcomes)")
            return
        }
        #expect(health.meanGain < -VoiceprintAdaptationPolicy.standard.rollbackTolerance)
        #expect(health.recentGains.count == VoiceprintAdaptationPolicy.standard.healthCheckSamples)
        #expect(adaptation.centroid == adaptation.snapshot)
        #expect(adaptation.centroid != moved)
        #expect(adaptation.isRolledBack)
        #expect(!adaptation.hasChanges)
        #expect(adaptation.discardedUpdates >= 10)
        #expect(adaptation.consider(F.evidence(F.owner)) == .skipped(.suspended))
    }

    @Test func theOwnersUsualVoiceDoesNotTriggerARollback() throws {
        var policy = VoiceprintAdaptationPolicy.standard
        policy.maximumUpdatesPerSession = 1_000
        var adaptation = try F.adaptation(policy: policy)
        // Segments scattered around one voice: every update moves towards
        // it, so the owner fits the adapted centroid better.
        for index in 0..<200 {
            let wobble = Float(index % 7 - 3) * 0.05
            _ = adaptation.consider(F.evidence(F.unit([0: 1, 1: 0.4, 2: wobble, 3: -wobble])))
        }
        #expect(!adaptation.isRolledBack)
        #expect(adaptation.health.meanGain > 0)
        #expect(adaptation.updateCount > 100)
    }

    @Test func driftOfRawVectors() throws {
        let clips: [[Float]] = [[1, 0, 0], [1, 0.2, 0], [1, -0.2, 0]]
        #expect(try #require(VoiceprintAdaptation.drift(of: [1, 0, 0], enrollmentClips: clips)) < 1e-6)
        let drift = try #require(VoiceprintAdaptation.drift(of: [1, 1, 0], enrollmentClips: clips))
        #expect(abs(drift - (1 - 1 / Float(2).squareRoot())) < 1e-5)
        #expect(VoiceprintAdaptation.drift(of: [1, 0], enrollmentClips: clips) == nil)
        #expect(VoiceprintAdaptation.drift(of: [1, 0, 0], enrollmentClips: []) == nil)
    }
}

@Suite("Adaptive voiceprint")
struct AdaptiveVoiceprintTests {
    typealias F = AdaptationFixtures

    static func voiceprint(clips: [SpeakerEmbedding] = [F.unit([0: 1, 5: 0.1]), F.unit([0: 1, 5: -0.1])])
        -> Voiceprint
    {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: F.model.identifier, centroid: SpeakerEmbedding.mean(of: clips)!,
            sets: clips.isEmpty ? [] : [VoiceprintSet(deviceModel: "iPhone18,1", embeddings: clips, createdAt: date)],
            createdAt: date, updatedAt: date)
    }

    @Test func theMatcherFollowsTheCentroid() throws {
        let adaptive = try #require(try AdaptiveVoiceprint(voiceprint: Self.voiceprint(), scoring: .cosineCentroid))
        let probe = F.unit([0: 1, 1: 0.6])
        let before = adaptive.matcher.score(probe)
        #expect(adaptive.matcher.adaptedCentroidOffset < 1e-4)
        for _ in 0..<20 { adaptive.consider(F.evidence(probe)) }
        #expect(adaptive.adaptation.updateCount == 20)
        #expect(adaptive.voiceprint.centroid == adaptive.adaptation.centroid)
        #expect(adaptive.matcher.adaptedCentroidOffset > 0)
        // The probe lines up with the move well beyond the handicap.
        #expect(adaptive.matcher.score(probe) > before + 0.01)

        adaptive.rollback()
        #expect(abs(adaptive.matcher.score(probe) - before) < 1e-5)
        #expect(adaptive.adaptation.isRolledBack)
    }

    @Test func aVoiceprintWithoutSetsIsNotAdapted() throws {
        var print = Self.voiceprint()
        print = Voiceprint(
            id: print.id, name: print.name, modelIdentifier: print.modelIdentifier, centroid: print.centroid, sets: [],
            createdAt: print.createdAt, updatedAt: print.updatedAt)
        #expect(try AdaptiveVoiceprint(voiceprint: print, scoring: .cosineCentroid) == nil)
    }

    @Test func aVerifierWithAdaptationScoresTheAdaptedVoiceprint() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let voiceprint = try await SpeakerVerifierTests.ownerVoiceprint(embedder)
        let fixed = try SpeakerVerifier(embedder: embedder, voiceprint: voiceprint, gauges: PerformanceGauges())
        #expect(fixed.adaptive == nil)

        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: voiceprint, adaptation: .standard, gauges: PerformanceGauges())
        let adaptive = try #require(verifier.adaptive)
        let speech = EnrollmentAudio.clip(.owner, duration: .seconds(4))
        let first = try await verifier.verify(speech)
        #expect(first.decision == .accept)
        let embedding = try #require(first.embedding)
        #expect(embedding.audioDuration == .seconds(4))

        for _ in 0..<5 {
            adaptive.consider(
                VoiceprintAdaptationEvidence(
                    embedding: embedding, score: first.score, thresholds: first.thresholds,
                    speechDuration: .seconds(4), signalToNoise: 30))
        }
        #expect(adaptive.adaptation.updateCount == 5)
        // The verifier now scores against the moved centroid.
        #expect(verifier.matcher.adaptedCentroidOffset == adaptive.matcher.adaptedCentroidOffset)
        #expect(verifier.matcher.adaptedCentroidOffset > 0)
        let second = try await verifier.verify(speech)
        #expect(second.score >= first.score - 1e-5)
    }
}
