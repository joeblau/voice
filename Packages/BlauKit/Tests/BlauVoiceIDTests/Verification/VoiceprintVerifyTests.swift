import BlauCore
import BlauTelemetry
import Testing

@testable import BlauVoiceID

@Suite struct VoiceprintVerifyTests {
    static let model = "test-model"

    static func embedding(_ vector: [Float], seconds: Double = 2) -> SpeakerEmbedding {
        SpeakerEmbedding(normalizing: vector, modelIdentifier: model, audioDuration: .seconds(seconds))!
    }

    static let config = VoiceIDConfig(
        modelIdentifier: model, scoring: .cosineCentroid,
        short: VoiceIDThresholds(accept: 0.6, reject: 0.3), long: VoiceIDThresholds(accept: 0.7, reject: 0.4),
        longWindow: .seconds(3))

    @Test func verifyScoresAndDecidesInsideTheInterval() throws {
        let scorer = try VoiceprintScorer(
            enrollment: [Self.embedding([1, 0, 0]), Self.embedding([0.9, 0.1, 0])], scoring: .cosineCentroid)
        let backend = RecordingSignpostBackend()
        let signposter = Signposter(category: .voiceID, backend: backend)

        let same = scorer.verify(Self.embedding([1, 0.05, 0]), config: Self.config, signposter: signposter)
        let other = scorer.verify(Self.embedding([0, 0, 1]), config: Self.config, signposter: signposter)
        let between = scorer.verify(Self.embedding([1, 1.6, 0]), config: Self.config, signposter: signposter)

        #expect(same.decision == .accept)
        #expect(other.decision == .reject)
        #expect(between.decision == .uncertain, "score \(between.score)")
        #expect(same.score == scorer.score(Self.embedding([1, 0.05, 0])))
        #expect(backend.completedIntervals == ["voiceid.verify", "voiceid.verify", "voiceid.verify"])
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func longProbesUseTheLongThresholds() throws {
        let scorer = try VoiceprintScorer(enrollment: [Self.embedding([1, 0])], scoring: .cosineCentroid)
        // cos ≈ 0.65: accepted against the short thresholds, uncertain against the long ones.
        let vector: [Float] = [0.65, (1 - 0.65 * 0.65).squareRoot()]
        let short = scorer.verify(
            Self.embedding(vector, seconds: 1.5), config: Self.config, signposter: .disabled(.voiceID))
        let long = scorer.verify(
            Self.embedding(vector, seconds: 3), config: Self.config, signposter: .disabled(.voiceID))
        #expect(short.decision == .accept)
        #expect(long.decision == .uncertain)
    }
}
