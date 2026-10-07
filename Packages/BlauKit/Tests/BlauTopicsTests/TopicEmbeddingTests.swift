import BlauCore
import BlauTelemetry
import BlauTopics
import Testing

@Suite("Topic embedding choice")
struct TopicEmbeddingTests {
    /// Stands in for BlauMemory's `SharedTextEmbedder`.
    struct SharedStandIn: TextEmbedder {
        var modelIdentifier: String { "embeddinggemma-300m-256d-int8-r1+fp16.wint8.ti8.L128@000000000000" }
        func embed(_ text: String) async throws -> [Float] { [1, 0] }
    }

    @Test func prefersTheSharedServiceThenContextualThenLexical() {
        let shared = SharedStandIn()
        let contextual = LexicalTextEmbedder(dimension: 8)

        let first = TopicEmbedding.choose(shared: shared, contextual: contextual)
        #expect(first.embedder.modelIdentifier == shared.modelIdentifier)
        #expect(first.config == .sharedEmbedding)

        let second = TopicEmbedding.choose(shared: nil, contextual: contextual)
        #expect(second.embedder.modelIdentifier == contextual.modelIdentifier)
        #expect(second.config == .contextualEmbedding)

        let last = TopicEmbedding.choose(shared: nil, contextual: nil)
        #expect(last.embedder.modelIdentifier == LexicalTextEmbedder().modelIdentifier)
        #expect(last.config == .default)
    }

    @Test func usesTheSharedServiceWhenItIsAvailable() async {
        let embedding = await TopicEmbedding.best { SharedStandIn() }
        guard case .shared = embedding else {
            Issue.record("Expected the shared embedder, got \(embedding.embedder.modelIdentifier)")
            return
        }
        let segmenter = StreamingTopicSegmenter(embedding: embedding, signposter: .disabled(.topics))
        #expect(await segmenter.config == .sharedEmbedding)
    }

    /// Without the shared model the fallback depends on the machine (Apple's
    /// contextual embedding if its assets are present), but it is never the
    /// shared config, and its config always matches its embedder.
    @Test func fallsBackWhenTheSharedModelIsMissing() async {
        let embedding = await TopicEmbedding.best { nil }
        switch embedding {
        case .shared: Issue.record("No shared embedder was offered")
        case .contextual: #expect(embedding.config == .contextualEmbedding)
        case .lexical: #expect(embedding.config == .default)
        }
    }

    @Test func theSharedConfigIsValid() {
        #expect(TopicConfig.sharedEmbedding.validationError == nil)
        #expect(TopicConfig.sharedEmbedding.minimumDepth == 0.5)
        var expected = TopicConfig.default
        expected.minimumDepth = 0.5
        #expect(TopicConfig.sharedEmbedding == expected)
    }
}
