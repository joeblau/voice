/// Turns text into a fixed-length vector whose cosine similarity reflects how
/// related two pieces of text are.
///
/// Defined in BlauCore because several sibling modules need it: BlauTopics
/// embeds exchanges for topic segmentation, and BlauMemory (M3) owns the
/// shared EmbeddingGemma service that will eventually back every embedder.
/// Consumers take `any TextEmbedder`, and the app's composition root decides
/// which implementation to pass in.
///
/// Implementations must be deterministic for a given `modelIdentifier`: the
/// same text always gives the same vector, and every vector has the same
/// length. Vectors from different models must never be compared, which is
/// why the identifier is part of the protocol.
public protocol TextEmbedder: Sendable {
    /// Identifies the model and its revision, for example
    /// `"lexical-hash-1024-v1"`. Changes whenever vectors would change.
    var modelIdentifier: String { get }

    /// Embeds `text`. Every call returns a vector of the same length.
    ///
    /// - Throws: When the model is unavailable or fails. Implementations
    ///   don't throw for empty text; they return a zero vector.
    func embed(_ text: String) async throws -> [Float]
}
