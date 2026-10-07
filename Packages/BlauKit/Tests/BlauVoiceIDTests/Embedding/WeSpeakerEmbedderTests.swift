import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("WeSpeakerEmbedder")
struct WeSpeakerEmbedderTests {
    let signposts = RecordingSignpostBackend()

    private func embedder(_ network: FakeSpeakerEmbeddingNetwork) -> WeSpeakerEmbedder {
        WeSpeakerEmbedder(network: network, signposter: Signposter(category: .voiceID, backend: signposts))
    }

    // MARK: Output

    @Test func returnsUnitVectorsTaggedWithTheModel() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        let embedding = try await embedder(network).embed(constantSegment(5, count: 24_000))
        #expect(embedding.vector == FakeSpeakerEmbeddingNetwork.direction(5, dimension: 256, length: 1))
        #expect(embedding.dimension == 256)
        #expect(embedding.modelIdentifier == SpeakerEmbeddingModelInfo.weSpeakerResNet34LM.identifier)
        #expect(embedding.audioDuration == .milliseconds(1_500))
    }

    @Test func normalizesWhateverLengthTheNetworkReturns() async throws {
        let network = FakeSpeakerEmbeddingNetwork { _ in (0..<256).map { Float($0) - 100 } }
        let embedding = try await embedder(network).embed(constantSegment(1, count: 16_000))
        let norm = embedding.vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-5)
    }

    @Test func emptyInputDoesNotRunTheModel() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        #expect(try await embedder(network).embed([]).isEmpty)
        #expect(network.inputs.isEmpty)
    }

    // MARK: Windows and model runs

    @Test func eachWindowIsItsOwnModelRunOverTheStartOfTheSegment() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        let segment = AudioFrame(samples: (0..<80_000).map { Float($0 % 200) }, sampleOffset: 0)
        let embeddings = try await embedder(network).embed(segment, windows: SpeakerEmbeddingWindow.standard)

        #expect(embeddings.map(\.audioDuration) == [.milliseconds(1_500), .seconds(3)])
        #expect(network.inputs == [Array(segment.samples.prefix(24_000)), Array(segment.samples.prefix(48_000))])
    }

    @Test func aWindowLongerThanTheSegmentUsesAllOfIt() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        let embeddings = try await embedder(network).embed(
            constantSegment(1, count: 32_000), windows: SpeakerEmbeddingWindow.standard)
        #expect(embeddings.map(\.audioDuration) == [.milliseconds(1_500), .seconds(2)])
        #expect(network.inputs.map(\.count) == [24_000, 32_000])
    }

    @Test func embedsEverySegmentInOrder() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        let segments = (0..<7).map { constantSegment(Float($0), count: 16_000 + $0) }
        let embeddings = try await embedder(network).embed(segments)

        #expect(network.inputs.map(\.count) == segments.map(\.sampleCount))
        #expect(embeddings.count == 7)
        for (index, embedding) in embeddings.enumerated() {
            #expect(embedding.vector == FakeSpeakerEmbeddingNetwork.direction(index, dimension: 256, length: 1))
        }
    }

    @Test func stopsWhenCancelled() async {
        let network = FakeSpeakerEmbeddingNetwork()
        let embedder = embedder(network)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await embedder.embed([constantSegment(1, count: 16_000)])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(network.inputs.isEmpty)
    }

    // MARK: Long segments

    @Test func splitsSegmentsLongerThanTheNetworkInputAndAveragesThem() async throws {
        // 25 s: three pieces of 8.33 s, each starting with a different value.
        var samples = [Float](repeating: 0, count: 400_000)
        for (piece, start) in [0, 133_334, 266_667].enumerated() {
            samples[start] = Float(piece + 1)
        }
        let network = FakeSpeakerEmbeddingNetwork()
        let embedding = try await embedder(network).embed(AudioFrame(samples: samples, sampleOffset: 0))

        #expect(network.inputs.map(\.count) == [133_334, 133_333, 133_333])
        #expect(embedding.audioDuration == .seconds(25))
        let third = Float(1) / Float(3).squareRoot()
        for axis in 0..<256 {
            #expect(abs(embedding.vector[axis] - ((1...3).contains(axis) ? third : 0)) < 1e-6)
        }
    }

    @Test func aTenSecondSegmentIsOnePiece() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        _ = try await embedder(network).embed(constantSegment(1, count: 160_000))
        #expect(network.inputs.map(\.count) == [160_000])
    }

    @Test(arguments: [1, 9, 10, 159_999, 160_000, 160_001, 320_000, 320_001, 1_000_003])
    func splitCoversEverySampleWithEqualPiecesWithinTheLimit(count: Int) {
        let samples = (0..<count).map(Float.init)
        let pieces = WeSpeakerEmbedder.split(samples, maximumLength: 160_000)
        #expect(pieces.flatMap { $0 } == samples)
        #expect(pieces.count == (count + 159_999) / 160_000)
        #expect(pieces.allSatisfy { $0.count <= 160_000 })
        let lengths = pieces.map(\.count)
        #expect(lengths.max()! - lengths.min()! <= 1)
    }

    // MARK: Validation

    @Test func rejectsOtherSampleRates() async {
        let network = FakeSpeakerEmbeddingNetwork()
        await #expect(throws: SpeakerEmbedderError.unsupportedSampleRate(48_000)) {
            try await embedder(network).embed(constantSegment(1, count: 48_000, sampleRate: 48_000))
        }
        #expect(network.inputs.isEmpty)
    }

    @Test func rejectsSegmentsShorterThanTheMinimum() async {
        let network = FakeSpeakerEmbeddingNetwork()
        await #expect(throws: SpeakerEmbedderError.segmentTooShort(.milliseconds(250), minimum: .milliseconds(500))) {
            try await embedder(network).embed([constantSegment(1, count: 16_000), constantSegment(1, count: 4_000)])
        }
        #expect(network.inputs.isEmpty, "Nothing runs when any segment is invalid")
    }

    @Test func acceptsExactlyTheMinimum() async throws {
        let network = FakeSpeakerEmbeddingNetwork()
        _ = try await embedder(network).embed(constantSegment(1, count: 8_000))
        #expect(network.inputs.count == 1)
    }

    @Test func rejectsNonFiniteSamples() async {
        var samples = [Float](repeating: 0.1, count: 16_000)
        samples[777] = .nan
        await #expect(throws: SpeakerEmbedderError.nonFiniteSamples) {
            try await embedder(FakeSpeakerEmbeddingNetwork()).embed(AudioFrame(samples: samples, sampleOffset: 0))
        }
    }

    @Test func rejectsOutputWithoutADirection() async {
        let network = FakeSpeakerEmbeddingNetwork { _ in [Float](repeating: 0, count: 256) }
        await #expect(throws: SpeakerEmbedderError.invalidOutput) {
            try await embedder(network).embed(constantSegment(1, count: 16_000))
        }
    }

    @Test func rejectsOutputOfTheWrongWidth() async {
        let network = FakeSpeakerEmbeddingNetwork { _ in [1, 2, 3] }
        await #expect(throws: SpeakerEmbedderError.invalidOutput) {
            try await embedder(network).embed(constantSegment(1, count: 16_000))
        }
    }

    @Test func passesNetworkErrorsThrough() async {
        struct Failure: Error, Equatable {}
        let network = FakeSpeakerEmbeddingNetwork { _ in throw Failure() }
        await #expect(throws: Failure()) {
            try await embedder(network).embed(constantSegment(1, count: 16_000))
        }
    }

    // MARK: Telemetry

    @Test func marksEachCallWithTheEmbedSignpost() async throws {
        let embedder = embedder(FakeSpeakerEmbeddingNetwork())
        _ = try await embedder.embed(constantSegment(1, count: 48_000), windows: SpeakerEmbeddingWindow.standard)
        #expect(signposts.completedIntervals == ["voiceid.embed"])
        #expect(signposts.openIntervals.isEmpty)
    }

    @Test func endsTheSignpostWhenEmbeddingFails() async {
        let embedder = embedder(FakeSpeakerEmbeddingNetwork())
        _ = try? await embedder.embed(constantSegment(1, count: 10))
        #expect(signposts.completedIntervals == ["voiceid.embed"])
        #expect(signposts.openIntervals.isEmpty)
    }
}
