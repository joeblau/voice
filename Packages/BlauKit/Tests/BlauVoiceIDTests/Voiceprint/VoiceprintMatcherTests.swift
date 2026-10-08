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
        let matcher = try VoiceprintMatcher(voiceprint: print, scoring: .cosineCentroid)
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

    @Test func asNormNeedsACohort() {
        #expect(throws: VoiceprintScorer.Error.missingCohort) {
            try VoiceprintMatcher(voiceprint: voiceprint(centroidAxis: 0, sets: []), scoring: .asNormCentroid)
        }
    }
}
