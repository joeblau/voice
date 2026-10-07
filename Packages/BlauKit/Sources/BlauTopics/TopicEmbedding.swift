import BlauCore
import BlauTelemetry
import os

/// The embedder a conversation's topic segmenter runs on, and the
/// `TopicConfig` tuned for it.
///
/// Since #60 the segmenter runs on the shared text-embedding service
/// (BlauMemory's `SharedTextEmbedder`: EmbeddingGemma, 256-d int8), the same
/// vectors the memory index stores, so an exchange is embedded once for
/// both. BlauTopics can't import BlauMemory, so the composition root passes
/// it in. Until that model is downloaded (or if it can't load), the
/// segmenter falls back to Apple's `NLContextualTextEmbedder` when its OS
/// assets are on the device, and to `LexicalTextEmbedder` otherwise.
///
/// Pick the embedding once per conversation: vectors from different models
/// can't be compared, so a segmenter never switches mid-stream.
///
/// ```swift
/// let embedding = await TopicEmbedding.best(shared: { try? await textEmbeddings.textEmbedder() })
/// let segmenter = StreamingTopicSegmenter(embedding: embedding)
/// ```
public enum TopicEmbedding: Sendable {
    /// The shared retrieval embedding model (`TopicConfig.sharedEmbedding`).
    case shared(any TextEmbedder)
    /// Apple's contextual embedding (`TopicConfig.contextualEmbedding`).
    case contextual(any TextEmbedder)
    /// The lexical reference embedder (`TopicConfig.default`).
    case lexical(LexicalTextEmbedder)

    public var embedder: any TextEmbedder {
        switch self {
        case .shared(let embedder), .contextual(let embedder): embedder
        case .lexical(let embedder): embedder
        }
    }

    /// The parameters tuned for this embedder's similarity scale.
    public var config: TopicConfig {
        switch self {
        case .shared: .sharedEmbedding
        case .contextual: .contextualEmbedding
        case .lexical: .default
        }
    }

    /// The first available of: the shared embedder, the contextual one, the
    /// lexical one.
    public static func choose(shared: (any TextEmbedder)?, contextual: (any TextEmbedder)?) -> TopicEmbedding {
        if let shared { return .shared(shared) }
        if let contextual { return .contextual(contextual) }
        return .lexical(LexicalTextEmbedder())
    }

    /// The best embedding available now. `shared` returns the shared
    /// service's embedder, or `nil` while its model isn't installed or
    /// can't load. The contextual fallback is used only if its assets are
    /// already on the device (this never downloads them).
    public static func best(shared: @Sendable () async -> (any TextEmbedder)?) async -> TopicEmbedding {
        if let embedder = await shared() {
            Log.topics.notice("Topic segmentation on \(embedder.modelIdentifier, privacy: .public)")
            return .shared(embedder)
        }
        var contextual: (any TextEmbedder)?
        #if canImport(NaturalLanguage)
            if let candidate = NLContextualTextEmbedder(), await candidate.hasAvailableAssets {
                contextual = candidate
            }
        #endif
        let embedding = choose(shared: nil, contextual: contextual)
        Log.topics.notice(
            "Shared text embedding unavailable; topic segmentation on \(embedding.embedder.modelIdentifier, privacy: .public)"
        )
        return embedding
    }
}

extension StreamingTopicSegmenter {
    /// A segmenter on `embedding`'s embedder with its tuned config.
    public init(embedding: TopicEmbedding, signposter: Signposter = Signposts.topics) {
        self.init(embedder: embedding.embedder, config: embedding.config, signposter: signposter)
    }
}
