import Foundation

/// One-shot text generation by a hosted language model, for features that
/// fall back to the cloud when the on-device model can't run.
///
/// Defined in BlauCore because the implementation and its consumers are
/// siblings: BlauRealtime owns the xAI REST client and implements this with
/// xAI's chat completions (`XAITextGenerator`), while BlauTopics (topic-label
/// fallback, #53) and BlauMemory (fact extraction, #66) consume it. The
/// app's composition root passes the implementation in
/// (docs/architecture.md, rule 2).
public protocol TextGenerator: Sendable {
    /// Whether a request can be attempted right now, for example because an
    /// API key is stored. Cheap; never touches the network.
    func isAvailable() async -> Bool

    /// Generates a reply to `request`.
    ///
    /// - Returns: The model's text. With a `responseSchema`, the text should
    ///   be a JSON object matching it, but callers must still validate it.
    /// - Throws: The service's error when no reply could be produced.
    func generate(_ request: TextGenerationRequest) async throws -> String
}

/// What to ask a `TextGenerator`.
public struct TextGenerationRequest: Hashable, Sendable {
    /// The system prompt.
    public var instructions: String

    /// The user prompt.
    public var prompt: String

    /// When set, asks for a JSON object matching this schema (structured
    /// output).
    public var responseSchema: JSONResponseSchema?

    /// Cap on the reply's length, in tokens.
    public var maximumResponseTokens: Int

    /// Sampling temperature; `0` is (close to) deterministic.
    public var temperature: Double

    /// Give up after this long.
    public var timeout: Duration

    public init(
        instructions: String,
        prompt: String,
        responseSchema: JSONResponseSchema? = nil,
        maximumResponseTokens: Int = 256,
        temperature: Double = 0,
        timeout: Duration = .seconds(15)
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.responseSchema = responseSchema
        self.maximumResponseTokens = maximumResponseTokens
        self.temperature = temperature
        self.timeout = timeout
    }
}

/// A named JSON Schema for structured output.
public struct JSONResponseSchema: Hashable, Sendable {
    /// Identifies the schema to the service (letters, digits, `_` and `-`).
    public var name: String

    /// The JSON Schema document, as UTF-8 JSON.
    public var schema: Data

    public init(name: String, schema: Data) {
        self.name = name
        self.schema = schema
    }

    /// The schema as a JSON object, or `nil` if `schema` isn't one.
    public var schemaObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: schema)) as? [String: Any]
    }
}
