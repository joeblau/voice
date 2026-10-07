import Foundation

/// What a text is embedded as. Retrieval models embed questions and the
/// passages that answer them with different prompts
/// (`TextEmbeddingModelSpec.queryPrompt` / `documentPrompt`).
public enum TextEmbeddingTask: String, Codable, Hashable, Sendable, CaseIterable {
    /// A search query (`search_memory`, hybrid retrieval #64).
    case query
    /// Anything stored and searched: exchanges, facts, notes, collection
    /// items (#62), and the exchanges the topic segmenter compares.
    case document
}

/// One text's vector as the memory index stores it: the model's Matryoshka
/// prefix, L2-normalized, quantized to int8 with one scale per vector, and
/// the version of the model that produced it.
///
/// Vectors with different `modelVersion`s must never be compared: the index
/// (#62) keeps the version with every row and re-embeds when it changes.
public struct TextEmbedding: Codable, Hashable, Sendable {
    /// `storedDimensions` int8 codes; `value ≈ Float(code) * scale`.
    public var codes: [Int8]
    /// The largest magnitude divided by 127; 0 for a zero vector.
    public var scale: Float
    /// `TextEmbeddingBundle.modelVersion(revision:)` of the model.
    public var modelVersion: String
    /// Tokens the model saw, prompt and special tokens included.
    public var tokenCount: Int
    /// Tokens cut from the end of the text because it was longer than the
    /// model's sequence length.
    public var truncatedTokens: Int

    public init(codes: [Int8], scale: Float, modelVersion: String, tokenCount: Int, truncatedTokens: Int = 0) {
        self.codes = codes
        self.scale = scale
        self.modelVersion = modelVersion
        self.tokenCount = tokenCount
        self.truncatedTokens = truncatedTokens
    }

    /// Quantizes a full-width model output: keep the first `dimensions`
    /// components, L2-normalize, int8 (`MatryoshkaEmbedding`).
    public init(fullOutput: [Float], dimensions: Int, modelVersion: String, tokenCount: Int, truncatedTokens: Int) {
        let stored = MatryoshkaEmbedding.quantized(
            MatryoshkaEmbedding.truncatedAndNormalized(fullOutput, to: dimensions))
        self.init(
            codes: stored.codes, scale: stored.scale, modelVersion: modelVersion, tokenCount: tokenCount,
            truncatedTokens: truncatedTokens)
    }

    public var dimensions: Int { codes.count }

    public var wasTruncated: Bool { truncatedTokens > 0 }

    /// A zero vector: empty text, or a model output that wasn't finite. It
    /// scores 0 against everything.
    public var isZero: Bool { scale == 0 }

    /// The dequantized vector (unit length up to quantization error).
    public var vector: [Float] { codes.map { Float($0) * scale } }

    /// Cosine similarity of the int8 codes, or `nil` when the vectors come
    /// from different models (or widths) and must not be compared. 0 when
    /// either is a zero vector.
    public func cosineSimilarity(to other: TextEmbedding) -> Float? {
        guard modelVersion == other.modelVersion, codes.count == other.codes.count else { return nil }
        var dot: Int32 = 0
        var left: Int32 = 0
        var right: Int32 = 0
        for index in codes.indices {
            let a = Int32(codes[index])
            let b = Int32(other.codes[index])
            dot += a * b
            left += a * a
            right += b * b
        }
        guard left > 0, right > 0 else { return 0 }
        return Float(Double(dot) / (Double(left).squareRoot() * Double(right).squareRoot()))
    }
}
