import BlauCore
import BlauTelemetry
import BlauTopics
import Synchronization
import Testing

/// A `TextEmbedder` fake that counts calls and can be told to fail.
private final class FakeEmbedder: TextEmbedder {
    struct Failure: Error, Equatable {}

    private let inner = LexicalTextEmbedder()
    private let state = Mutex((calls: 0, failNext: false))

    var modelIdentifier: String { "fake" }

    var calls: Int { state.withLock { $0.calls } }

    func failNextCall() { state.withLock { $0.failNext = true } }

    func embed(_ text: String) async throws -> [Float] {
        let fail = state.withLock { state in
            state.calls += 1
            defer { state.failNext = false }
            return state.failNext
        }
        if fail { throw Failure() }
        return inner.vector(for: text)
    }
}

@Suite("StreamingTopicSegmenter")
struct StreamingTopicSegmenterTests {
    @Test func matchesTheCoreEngineOnAScriptedTranscript() async throws {
        let embedder = FakeEmbedder()
        let segmenter = StreamingTopicSegmenter(embedder: embedder, signposter: .disabled(.topics))
        var events: [TopicSegmentationEvent] = []
        for unit in ScriptedTranscript.threeTopics.units() {
            events += try await segmenter.append(unit)
        }
        events += await segmenter.finish()

        let reference = try SegmenterRun.run(.threeTopics)
        #expect(events == reference.events)
        #expect(await segmenter.boundaries.map(\.unitIndex) == [6, 12])
        #expect(await segmenter.units.count == ScriptedTranscript.threeTopics.count)
        #expect(embedder.calls == ScriptedTranscript.threeTopics.count)
    }

    @Test func emitsOneTopicsSegmentIntervalPerUnit() async throws {
        let backend = RecordingSignpostBackend()
        let segmenter = StreamingTopicSegmenter(
            embedder: LexicalTextEmbedder(),
            signposter: Signposter(category: .topics, backend: backend)
        )
        let units = ScriptedTranscript.explicitCues.units()
        for unit in units {
            _ = try await segmenter.append(unit)
        }
        #expect(backend.completedIntervals == Array(repeating: "topics.segment", count: units.count))
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func anEmbedderFailureLeavesTheSegmenterUnchanged() async throws {
        let embedder = FakeEmbedder()
        let segmenter = StreamingTopicSegmenter(embedder: embedder, signposter: .disabled(.topics))
        let units = ScriptedTranscript.threeTopics.units()
        _ = try await segmenter.append(units[0])

        embedder.failNextCall()
        await #expect(throws: FakeEmbedder.Failure()) {
            try await segmenter.append(units[1])
        }
        #expect(await segmenter.units.count == 1)

        // The caller can retry the same unit.
        _ = try await segmenter.append(units[1])
        #expect(await segmenter.units.count == 2)
    }

    @Test func acceptsPrecomputedEmbeddings() async throws {
        let embedder = FakeEmbedder()
        let segmenter = StreamingTopicSegmenter(embedder: embedder, signposter: .disabled(.topics))
        let lexical = LexicalTextEmbedder()
        for unit in ScriptedTranscript.briefDigression.units() {
            _ = try await segmenter.append(unit, embedding: lexical.vector(for: unit.text))
        }
        #expect(embedder.calls == 0)
        #expect(await segmenter.boundaries.map(\.unitIndex) == [12])
        #expect(await segmenter.pendingCandidate == nil)
        #expect(await segmenter.currentTopicStart == 12)
        #expect(await segmenter.gapScore(at: 12) != nil)
    }

    @Test func invalidEmbeddingsThrowTheSegmenterError() async throws {
        let segmenter = StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics))
        let unit = ScriptedTranscript.threeTopics.units()[0]
        await #expect(throws: TopicSegmenterError.emptyEmbedding) {
            try await segmenter.append(unit, embedding: [])
        }
        #expect(await segmenter.config == .default)
    }
}
