import BlauCore
import Foundation

/// A `TextEmbedder` over a fixed set of texts whose token IDs were computed
/// ahead of time, so a Core ML embedding model can be evaluated from Swift
/// before Blau has a tokenizer for it (#60 adds the real one).
///
/// `scripts/embeddings/convert_coreml.py` writes the table
/// (`<model>.eval-tokens.json`) with the model's own tokenizer, prompts
/// included: `{"model": "...", "maximumLength": 256, "tokens": {"<text>": [ids]}}`.
public struct PretokenizedTextEmbedder: TextEmbedder {
    public enum Failure: Error, Hashable, Sendable {
        /// `embed(_:)` got a text that isn't in the table.
        case notInTable(String)
    }

    public let modelIdentifier: String
    private let model: any TokenEmbeddingModel
    private let tokens: [String: [Int32]]

    public init(modelIdentifier: String, model: any TokenEmbeddingModel, tokens: [String: [Int32]]) {
        self.modelIdentifier = modelIdentifier
        self.model = model
        self.tokens = tokens
    }

    /// Reads a token table written by `convert_coreml.py`.
    public init(model: any TokenEmbeddingModel, tableURL: URL) throws {
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: tableURL))
        self.init(modelIdentifier: "\(table.model)-coreml", model: model, tokens: table.tokens)
    }

    public var texts: Set<String> { Set(tokens.keys) }

    public func embed(_ text: String) async throws -> [Float] {
        guard let ids = tokens[text] else { throw Failure.notInTable(String(text.prefix(80))) }
        return try await model.embed(tokenIDs: ids)
    }

    struct Table: Decodable {
        var model: String
        var tokens: [String: [Int32]]
    }
}
