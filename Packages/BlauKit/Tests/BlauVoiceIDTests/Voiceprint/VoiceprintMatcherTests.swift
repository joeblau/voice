import Foundation
import Testing

@testable import BlauVoiceID

/// Scoring against the centroid and every device's set.
@Suite("Voiceprint matcher")
struct VoiceprintMatcherTests {
    let model = TestEmbeddings.model
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func voiceprint(centroidAxis: Int, sets: [(String, [SpeakerEmbedding])]) -> Voiceprint {
        Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: model.identifier,
            centroid: TestEmbeddings.embedding(axis: centroidAxis),
            sets: sets.map { VoiceprintSet(deviceModel: $0.0, embeddings: $0.1, createdAt: date) }, createdAt: date,
            updatedAt: date)
    }

    @Test func theScoreIsTheBestOfTheCentroidAndEverySet() throws {
        // The centroid points one way, the iPad's set another: a probe
        // recorded on the iPad matches its own set best.
        let ipad = TestEmbeddings.speaker(3, count: 3)
        let print = voiceprint(
            centroidAxis: 0, sets: [("iPhone18,1", TestEmbeddings.speaker(0, count: 4)), ("iPad16,3", ipad)])
        // This centroid isn't the mean of the clips, as an adapted one
        // would be; score it as is (the handicap is tested below).
        let matcher = try VoiceprintMatcher(voiceprint: print, scoring: .cosineCentroid, adaptedCentroidPenalty: 0)
        #expect(matcher.scorers.count == 3)

        let ipadProbe = TestEmbeddings.embedding(axis: 3)
        let ipadScore = matcher.score(ipadProbe)
        #expect(ipadScore > 0.9)
        #expect(ipadScore > ipadProbe.cosineSimilarity(to: print.centroid))

        let iphoneProbe = TestEmbeddings.embedding(axis: 0)
        #expect(abs(matcher.score(iphoneProbe) - 1) < 1e-5)  // the centroid itself

        let stranger = TestEmbeddings.embedding(axis: 7)
        #expect(matcher.score(stranger) < 0.1)
    }

    @Test func aVoiceprintWithoutSetsUsesTheCentroid() throws {
        let matcher = try VoiceprintMatcher(
            voiceprint: voiceprint(centroidAxis: 4, sets: []), scoring: .cosineBestMatch)
        #expect(matcher.scorers.count == 1)
        #expect(abs(matcher.score(TestEmbeddings.embedding(axis: 4)) - 1) < 1e-5)
    }

    @Test func anEnrolledCentroidIsScoredAsIs() throws {
        let clips = TestEmbeddings.speaker(0, count: 4)
        let print = Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: model.identifier, centroid: SpeakerEmbedding.mean(of: clips)!,
            sets: [VoiceprintSet(deviceModel: "iPhone18,1", embeddings: clips, createdAt: date)], createdAt: date,
            updatedAt: date)
        let matcher = try VoiceprintMatcher(voiceprint: print, scoring: .cosineCentroid)
        #expect(matcher.adaptedCentroidOffset < 1e-3)
    }

    /// An adapted centroid pays `penalty × |centroid − enrollment centroid|`
    /// on its cosine, and the sets (the enrollment) still score as before:
    /// a probe gains from the adaptation only if it lines up with the move
    /// by more than the penalty.
    @Test func anAdaptedCentroidIsHandicappedByHowFarItMoved() throws {
        let clips = TestEmbeddings.speaker(0, count: 4)
        let enrollment = SpeakerEmbedding.mean(of: clips)!
        // Moved towards axis 1 by cosine distance 0.05.
        let moved = SpeakerEmbedding(
            normalizing: zip(enrollment.vector, TestEmbeddings.vector(1)).map { 0.95 * $0 + 0.312 * $1 },
            modelIdentifier: model.identifier, audioDuration: .zero)!
        let print = Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: model.identifier, centroid: moved,
            sets: [VoiceprintSet(deviceModel: "iPhone18,1", embeddings: clips, createdAt: date)], createdAt: date,
            updatedAt: date)
        let drift = try #require(print.adaptationDrift)
        let matcher = try VoiceprintMatcher(voiceprint: print, scoring: .cosineCentroid)
        let distance = (2 * drift).squareRoot()
        #expect(abs(matcher.adaptedCentroidOffset - VoiceprintMatcher.adaptedCentroidPenalty * distance) < 1e-5)

        // A probe along the move scores the handicapped adapted centroid.
        let along = moved
        #expect(abs(matcher.score(along) - (1 - matcher.adaptedCentroidOffset)) < 1e-4)
        // A probe the other way scores the enrollment set, unchanged.
        let away = SpeakerEmbedding(
            normalizing: zip(enrollment.vector, TestEmbeddings.vector(1)).map { 0.95 * $0 - 0.312 * $1 },
            modelIdentifier: model.identifier, audioDuration: .zero)!
        #expect(abs(matcher.score(away) - away.cosineSimilarity(to: enrollment)) < 1e-4)
        // Without the handicap the adapted centroid would score it higher.
        let unguarded = try VoiceprintMatcher(voiceprint: print, scoring: .cosineCentroid, adaptedCentroidPenalty: 0)
        #expect(unguarded.score(along) > matcher.score(along))
    }

    /// With several devices' sets, no set's own centroid is the enrollment
    /// centroid: an adapted voiceprint keeps it as a reference, so nothing
    /// scores lower than against the enrolled voiceprint.
    @Test func anAdaptedVoiceprintNeverScoresBelowTheEnrolledOne() throws {
        let iphone = TestEmbeddings.speaker(0, count: 4)
        let ipad = (0..<3).map { TestEmbeddings.embedding(axis: 0, mix: 0.6, mixAxis: 50 + $0) }
        let sets = [
            VoiceprintSet(deviceModel: "iPhone18,1", embeddings: iphone, createdAt: date),
            VoiceprintSet(deviceModel: "iPad16,3", embeddings: ipad, createdAt: date),
        ]
        let enrollment = SpeakerEmbedding.mean(of: iphone + ipad)!
        let enrolled = Voiceprint(
            id: UUID(), name: "Me", modelIdentifier: model.identifier, centroid: enrollment, sets: sets,
            createdAt: date, updatedAt: date)
        let adapted = enrolled.withCentroid(
            VoiceprintAdaptation.capped(TestEmbeddings.embedding(axis: 9), around: enrollment, maximumDrift: 0.1)
                .embedding)
        let before = try VoiceprintMatcher(voiceprint: enrolled, scoring: .cosineCentroid)
        let after = try VoiceprintMatcher(voiceprint: adapted, scoring: .cosineCentroid)
        #expect(before.scorers.count == 3)
        #expect(after.scorers.count == 4)
        for axis in [0, 1, 9, 50, 100, 101] {
            for mix: Float in [0, 0.5, 1] {
                let probe = TestEmbeddings.embedding(axis: 0, mix: mix, mixAxis: axis == 0 ? 255 : axis)
                #expect(after.score(probe) >= before.score(probe) - 1e-5, "axis \(axis) mix \(mix)")
            }
        }
    }

    @Test func asNormNeedsACohort() {
        #expect(throws: VoiceprintScorer.Error.missingCohort) {
            try VoiceprintMatcher(voiceprint: voiceprint(centroidAxis: 0, sets: []), scoring: .asNormCentroid)
        }
    }
}
