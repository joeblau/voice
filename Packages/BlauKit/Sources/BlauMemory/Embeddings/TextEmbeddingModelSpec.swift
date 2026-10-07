/// Everything the memory index needs to know about a text-embedding model:
/// its prompts, its widths and how its vectors are stored.
///
/// #59 compared the candidates below on Blau's personal retrieval eval
/// (docs/benchmarks.md, "Text embedding model"); `chosen` is the outcome and
/// the model the shared embedding service (#60) loads. The prompts must match
/// `scripts/embeddings/candidates.py`, which produced the numbers.
public struct TextEmbeddingModelSpec: Codable, Hashable, Sendable {
    /// How the model turns token vectors into one vector.
    public enum Pooling: String, Codable, Hashable, Sendable {
        /// Mean over the real tokens (EmbeddingGemma, NLContextualEmbedding).
        case mean
        /// The hidden state of the last real token (decoder models: Qwen3).
        case lastToken
        /// Mean of static per-token vectors; no transformer (Model2Vec).
        case staticMean
    }

    /// Stable short identifier, e.g. `embeddinggemma-300m`.
    public var id: String
    public var displayName: String
    /// Where the weights come from (a Hugging Face repository, or the OS).
    public var source: String
    public var license: String
    /// Prepended to a search query before embedding.
    public var queryPrompt: String
    /// Prepended to every indexed chunk (exchange, fact, note) before
    /// embedding.
    public var documentPrompt: String
    /// Width of the model's own output.
    public var fullDimensions: Int
    /// Width the index stores: the Matryoshka prefix kept after truncation.
    public var storedDimensions: Int
    /// Longest input in tokens; longer chunks are truncated.
    public var maximumTokens: Int
    public var pooling: Pooling
    /// Whether the first `storedDimensions` components are trained to work on
    /// their own (Matryoshka representation learning). Truncating a model
    /// that isn't costs far more quality.
    public var isMatryoshka: Bool
    /// Bumped whenever stored vectors would change (new weights, prompts or
    /// width), so the index knows to rebuild.
    public var revision: Int

    public init(
        id: String,
        displayName: String,
        source: String,
        license: String,
        queryPrompt: String,
        documentPrompt: String,
        fullDimensions: Int,
        storedDimensions: Int,
        maximumTokens: Int,
        pooling: Pooling,
        isMatryoshka: Bool,
        revision: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.license = license
        self.queryPrompt = queryPrompt
        self.documentPrompt = documentPrompt
        self.fullDimensions = fullDimensions
        self.storedDimensions = storedDimensions
        self.maximumTokens = maximumTokens
        self.pooling = pooling
        self.isMatryoshka = isMatryoshka
        self.revision = revision
    }

    /// Identifies stored vectors: model, width, int8 storage and revision.
    /// Vectors with different identifiers must never be compared
    /// (`TextEmbedder.modelIdentifier`).
    public var vectorIdentifier: String { "\(id)-\(storedDimensions)d-int8-r\(revision)" }

    /// The text to embed for a search query.
    public func queryText(_ query: String) -> String { queryPrompt + query }

    /// The text to embed for an indexed chunk.
    public func documentText(_ document: String) -> String { documentPrompt + document }

    /// The vector the index stores for a full-width model output: the
    /// Matryoshka prefix, L2-normalized, as int8 codes and a scale.
    public func storedVector(fromFullOutput vector: [Float]) -> (codes: [Int8], scale: Float) {
        MatryoshkaEmbedding.quantized(MatryoshkaEmbedding.truncatedAndNormalized(vector, to: storedDimensions))
    }
}

extension TextEmbeddingModelSpec {
    /// The model Blau uses for memory search and topic segmentation (#59).
    public static let chosen = embeddingGemma300M

    /// Every candidate #59 compared, the chosen one first.
    public static let candidates: [TextEmbeddingModelSpec] = [
        embeddingGemma300M, qwen3Embedding06B, potionRetrieval32M, nlContextualEmbedding,
    ]

    /// Google's EmbeddingGemma-300M: 308M parameters, 768-d, Matryoshka down to
    /// 128-d, 2k-token context, task prompts from the model card.
    public static let embeddingGemma300M = TextEmbeddingModelSpec(
        id: "embeddinggemma-300m",
        displayName: "EmbeddingGemma-300M",
        source: "google/embeddinggemma-300m",
        license: "Gemma Terms of Use",
        queryPrompt: "task: search result | query: ",
        documentPrompt: "title: none | text: ",
        fullDimensions: 768,
        storedDimensions: 256,
        maximumTokens: 256,
        pooling: .mean,
        isMatryoshka: true
    )

    /// Alibaba's Qwen3-Embedding-0.6B: 596M parameters, 1024-d, Matryoshka,
    /// last-token pooling, an English task instruction on queries only.
    public static let qwen3Embedding06B = TextEmbeddingModelSpec(
        id: "qwen3-embedding-0.6b",
        displayName: "Qwen3-Embedding-0.6B",
        source: "Qwen/Qwen3-Embedding-0.6B",
        license: "Apache-2.0",
        queryPrompt:
            "Instruct: Given a question about the user's life, work or past conversations, "
            + "retrieve the memory that answers it\nQuery:",
        documentPrompt: "",
        fullDimensions: 1_024,
        storedDimensions: 256,
        maximumTokens: 256,
        pooling: .lastToken,
        isMatryoshka: true
    )

    /// Minish Lab's potion-retrieval-32M: Model2Vec static embeddings
    /// distilled for retrieval. No transformer runs at inference, so it costs
    /// microseconds on the CPU. Its 512 components come from PCA, so a prefix
    /// keeps the highest-variance directions.
    public static let potionRetrieval32M = TextEmbeddingModelSpec(
        id: "potion-retrieval-32m",
        displayName: "potion-retrieval-32M (Model2Vec)",
        source: "minishlab/potion-retrieval-32M",
        license: "MIT",
        queryPrompt: "",
        documentPrompt: "",
        fullDimensions: 512,
        storedDimensions: 256,
        maximumTokens: 512,
        pooling: .staticMean,
        isMatryoshka: false
    )

    /// Apple's `NLContextualEmbedding` (English), mean-pooled: the baseline
    /// that ships with the OS. 512-d (the width varies by OS model, see
    /// `NLContextualEmbedding.dimension`); not trained for retrieval.
    public static let nlContextualEmbedding = TextEmbeddingModelSpec(
        id: "nl-contextual-embedding",
        displayName: "Apple NLContextualEmbedding (mean-pooled)",
        source: "NaturalLanguage framework (OS asset)",
        license: "Apple SDK",
        queryPrompt: "",
        documentPrompt: "",
        fullDimensions: 512,
        storedDimensions: 512,
        maximumTokens: 256,
        pooling: .mean,
        isMatryoshka: false
    )
}
