import BlauCore
import FluidAudio
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("SpeakerEmbedding")
struct SpeakerEmbeddingTests {
    private func embedding(_ raw: [Float], model: String = "test", duration: Duration = .seconds(1)) throws
        -> SpeakerEmbedding
    {
        try #require(SpeakerEmbedding(normalizing: raw, modelIdentifier: model, audioDuration: duration))
    }

    @Test func normalizesToUnitLength() throws {
        let value = try embedding([3, 4])
        #expect(value.vector == [0.6, 0.8])
        #expect(value.dimension == 2)
        #expect(value.modelIdentifier == "test")
        #expect(value.audioDuration == .seconds(1))
    }

    @Test func keepsTinyVectorsWithADirection() throws {
        let value = try embedding([1e-30, 0])
        #expect(value.vector == [1, 0])
    }

    @Test(arguments: [
        [Float](),
        [0, 0, 0],
        [1, .nan],
        [1, .infinity],
    ])
    func rejectsVectorsWithoutADirection(raw: [Float]) {
        #expect(SpeakerEmbedding(normalizing: raw, modelIdentifier: "test", audioDuration: .zero) == nil)
    }

    @Test func cosineSimilarityIsTheDotProductOfUnitVectors() throws {
        let a = try embedding([1, 0, 0])
        #expect(a.cosineSimilarity(to: a) == 1)
        #expect(a.cosineSimilarity(to: try embedding([0, 2, 0])) == 0)
        #expect(a.cosineSimilarity(to: try embedding([-5, 0, 0])) == -1)
        let diagonal = try embedding([1, 1, 0])
        #expect(abs(a.cosineSimilarity(to: diagonal) - Float(0.5).squareRoot()) < 1e-6)
        #expect(a.cosineSimilarity(to: diagonal) == diagonal.cosineSimilarity(to: a))
    }

    @Test func meanIsTheNormalizedAverageDirection() throws {
        let mean = try #require(
            SpeakerEmbedding.mean(of: [
                try embedding([1, 0], duration: .seconds(1)), try embedding([0, 7], duration: .seconds(2)),
            ]))
        #expect(abs(mean.vector[0] - Float(0.5).squareRoot()) < 1e-6)
        #expect(abs(mean.vector[1] - Float(0.5).squareRoot()) < 1e-6)
        #expect(mean.audioDuration == .seconds(3))
    }

    @Test func meanRefusesEmptyMixedOrCancellingInput() throws {
        #expect(SpeakerEmbedding.mean(of: []) == nil)
        #expect(
            SpeakerEmbedding.mean(of: [try embedding([1, 0], model: "a"), try embedding([1, 0], model: "b")]) == nil)
        #expect(SpeakerEmbedding.mean(of: [try embedding([1, 0]), try embedding([1, 0, 0])]) == nil)
        #expect(SpeakerEmbedding.mean(of: [try embedding([1, 0]), try embedding([-1, 0])]) == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        let value = try embedding([1, 2, 3], duration: .milliseconds(1_500))
        let decoded = try JSONDecoder().decode(SpeakerEmbedding.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
}

@Suite("SpeakerEmbeddingModelInfo")
struct SpeakerEmbeddingModelInfoTests {
    @Test func weSpeakerIs256DimensionalAndNamesItsWeights() {
        let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM
        #expect(model.dimension == 256)
        #expect(model.dimension == SpeakerEmbeddingNetworkShape.weSpeaker.dimension)
        #expect(model.identifier.hasPrefix("wespeaker-resnet34-lm@"))
    }

    /// The identifier names the weights' revision. If FluidAudio (and with
    /// it Blau's pinned manifest, see `ModelManifestTests`) moves to new
    /// weights, this fails: bump the identifier so old voiceprints are
    /// recognized as incompatible.
    @Test func identifierMatchesFluidAudiosPinnedRevision() throws {
        let revision = Repo.diarizer.revision
        let suffix = try #require(SpeakerEmbeddingModelInfo.weSpeakerResNet34LM.identifier.split(separator: "@").last)
        #expect(revision.hasPrefix(suffix))
    }

    @Test func modelBundleIsFluidAudiosEmbeddingFile() {
        #expect(WeSpeakerEmbedder.modelBundleName == ModelNames.Diarizer.embeddingFile)
        #expect(WeSpeakerEmbedder.modelBundleName == "wespeaker_v2.mlmodelc")
    }
}

@Suite("SpeakerEmbeddingWindow")
struct SpeakerEmbeddingWindowTests {
    @Test func standardWindowsAre1point5And3Seconds() {
        #expect(SpeakerEmbeddingWindow.standard == [.short, .long])
        #expect(SpeakerEmbeddingWindow.short.sampleCount() == 24_000)
        #expect(SpeakerEmbeddingWindow.long.sampleCount() == 48_000)
        #expect(SpeakerEmbeddingWindow.short < .long)
    }

    @Test func prefixTakesTheStartOfTheSegment() {
        let segment = AudioFrame(samples: (0..<60_000).map(Float.init), sampleOffset: 800, hostTime: 42)
        let prefix = SpeakerEmbeddingWindow.short.prefix(of: segment)
        #expect(prefix.samples == (0..<24_000).map(Float.init))
        #expect(prefix.sampleOffset == 800)
        #expect(prefix.hostTime == 42)
        #expect(prefix.duration == .milliseconds(1_500))
    }

    @Test func prefixOfAShorterSegmentIsTheWholeSegment() {
        let segment = constantSegment(1, count: 30_000)
        #expect(SpeakerEmbeddingWindow.long.prefix(of: segment) == segment)
    }

    @Test func prefixHonorsTheSegmentsSampleRate() {
        let segment = constantSegment(1, count: 96_000, sampleRate: 48_000)
        #expect(SpeakerEmbeddingWindow.short.prefix(of: segment).sampleCount == 72_000)
    }
}

@Suite("SpeakerEmbeddingInput")
struct SpeakerEmbeddingInputTests {
    private func tile(_ source: [Float], into count: Int) -> [Float] {
        var destination = [Float](repeating: -1, count: count)
        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { SpeakerEmbeddingInput.tile(source, into: $0) }
        }
        return destination
    }

    @Test func repeatsTheSourceToFillTheBuffer() {
        #expect(tile([1, 2, 3], into: 8) == [1, 2, 3, 1, 2, 3, 1, 2])
        #expect(tile([5], into: 4) == [5, 5, 5, 5])
        #expect(tile([1, 2], into: 2) == [1, 2])
    }

    @Test func matchesNaiveRepetitionForAWindowSizedBuffer() {
        let source = (0..<24_001).map { Float($0 % 977) }
        let tiled = tile(source, into: 160_000)
        #expect(tiled == (0..<160_000).map { source[$0 % source.count] })
    }
}

@Suite("SpeakerEmbeddingNetworkShape")
struct SpeakerEmbeddingNetworkShapeTests {
    @Test func readsTheLayoutFromTensorShapes() throws {
        let shape = try SpeakerEmbeddingNetworkShape(waveform: [3, 160_000], mask: [3, 589], embedding: [3, 256])
        #expect(shape == .weSpeaker)
    }

    @Test(arguments: [
        ([160_000], [3, 589], [3, 256]),
        ([3, 160_000], [3, 589], [3, 1, 256]),
        ([3, 0], [3, 589], [3, 256]),
        ([3, 160_000], [2, 589], [3, 256]),
        ([3, 160_000], [3, 589], [1, 256]),
    ])
    func rejectsUnexpectedShapes(waveform: [Int], mask: [Int], embedding: [Int]) {
        #expect(throws: SpeakerEmbedderError.self) {
            try SpeakerEmbeddingNetworkShape(waveform: waveform, mask: mask, embedding: embedding)
        }
    }
}
