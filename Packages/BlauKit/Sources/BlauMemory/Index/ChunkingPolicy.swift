import Foundation

/// Counts the tokens a chunk's key text takes when it is embedded as a
/// stored document, prompt and special tokens included.
public protocol ChunkTokenCounting: Sendable {
    func tokenCount(_ text: String) -> Int
}

/// A tokenizer-free estimate: a quarter of the UTF-8 bytes (the same rule
/// as `ProfileBlock.approximateTokenCount`), rounded up, plus the prompt and
/// special tokens.
///
/// The default, because it keeps chunk boundaries independent of the
/// installed model: chunk ids and hashes don't change when the embedding
/// model is downloaded or replaced, so the FTS rows stay put and only the
/// vectors are (re)computed.
public struct ApproximateTokenCounter: ChunkTokenCounting, Hashable {
    /// Tokens added to every text: EmbeddingGemma's document prompt
    /// (`title: none | text: `, 7 tokens) plus `<bos>` and `<eos>`.
    public var overhead: Int

    public init(overhead: Int = 9) {
        self.overhead = overhead
    }

    public func tokenCount(_ text: String) -> Int {
        (text.utf8.count + 3) / 4 + overhead
    }
}

extension TextEmbeddingModel: ChunkTokenCounting {
    /// The model's exact count for `text` embedded as a document.
    public nonisolated func tokenCount(_ text: String) -> Int {
        tokenCount(of: text, as: .document)
    }
}

/// How `MemoryChunker` cuts sources into chunks.
///
/// The issue sketched documents as 200–400-token chunks, but the shared
/// embedding model (#60) reads at most 128 tokens, so a 400-token chunk
/// would be embedded from its first quarter only. Chunk sizes therefore
/// follow the model's sequence length: `forSequenceLength(_:)` leaves a
/// safety margin for the estimate and caps at 400 tokens, which gives the
/// issue's 200–400 range back once a 512-token model ships.
public struct ChunkingPolicy: Hashable, Sendable {
    /// The most tokens a chunk's key text may take, prompt included. Longer
    /// exchanges and paragraphs are split; the overlap context is trimmed
    /// to fit.
    public var maximumTokens: Int
    /// A document chunk ends at a heading only once it has this many
    /// tokens; smaller sections are merged with the next one.
    public var minimumDocumentTokens: Int
    /// How many earlier exchanges each exchange chunk carries as context
    /// after its own text (0 or 1).
    public var exchangeOverlap: Int
    /// Most facts in an exchange's `facts:` prefix.
    public var maximumFactsPerExchange: Int
    /// The time zone of the dates in key texts.
    public var timeZone: TimeZone

    public init(
        maximumTokens: Int,
        minimumDocumentTokens: Int? = nil,
        exchangeOverlap: Int = 1,
        maximumFactsPerExchange: Int = 5,
        timeZone: TimeZone = .current
    ) {
        self.maximumTokens = max(16, maximumTokens)
        self.minimumDocumentTokens = min(self.maximumTokens, max(1, minimumDocumentTokens ?? self.maximumTokens / 2))
        self.exchangeOverlap = max(0, min(1, exchangeOverlap))
        self.maximumFactsPerExchange = max(0, maximumFactsPerExchange)
        self.timeZone = timeZone
    }

    /// Chunks for a model that reads `sequenceLength` tokens: 7/8 of it
    /// (headroom for the token estimate), at most 400.
    public static func forSequenceLength(_ sequenceLength: Int, timeZone: TimeZone = .current) -> ChunkingPolicy {
        let maximum = min(400, sequenceLength * 7 / 8)
        return ChunkingPolicy(maximumTokens: maximum, minimumDocumentTokens: maximum / 2, timeZone: timeZone)
    }

    /// For the shipped 128-token embedding model (#60): at most 112 tokens.
    public static var `default`: ChunkingPolicy { forSequenceLength(128) }
}
