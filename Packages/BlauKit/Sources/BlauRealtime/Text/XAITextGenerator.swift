import BlauCore
import BlauTelemetry
import Foundation
import os

/// `TextGenerator` backed by xAI's chat completions REST API
/// (`POST /v1/chat/completions`), called directly with the user's key from
/// the Keychain. No backend is involved (issue #33).
///
/// BlauTopics uses it as the topic-label fallback when Apple Intelligence
/// is unavailable (#53); BlauMemory can use it for fact extraction (#66).
/// The request is OpenAI-compatible: a system and a user message,
/// `max_tokens`, `temperature` and, for structured output,
/// `response_format: {"type": "json_schema", "json_schema": {...}}`.
public struct XAITextGenerator: TextGenerator {
    /// The text model used unless the caller pins another: the 0309
    /// snapshot of Grok 4.20 without the reasoning phase, which answers
    /// immediately and is the cheapest Grok 4 model that supports
    /// structured output (docs.x.ai, October 2026).
    public static let defaultModel = "grok-4.20-0309-non-reasoning"

    public let model: String
    private let client: XAIHTTPClient

    public init(client: XAIHTTPClient, model: String = XAITextGenerator.defaultModel) {
        self.client = client
        self.model = model
    }

    public func isAvailable() async -> Bool {
        await client.hasAPIKey()
    }

    /// - Throws: `XAIError`, or `XAIError.invalidResponse` when the reply has
    ///   no text (for example a refusal or a truncated structured reply).
    public func generate(_ request: TextGenerationRequest) async throws -> String {
        let body = try Self.body(for: request, model: model)
        let response = try await client.send(
            XAIHTTPClient.Request(method: "POST", path: "/v1/chat/completions", body: body, timeout: request.timeout),
            decoding: ChatCompletion.self
        )
        guard let choice = response.choices.first else {
            throw XAIError.invalidResponse("The chat completion has no choices")
        }
        if let refusal = choice.message.refusal, !refusal.isEmpty {
            throw XAIError.invalidResponse("The model refused the request")
        }
        guard let content = choice.message.content, !content.allSatisfy(\.isWhitespace) else {
            throw XAIError.invalidResponse("The chat completion has no content")
        }
        if let usage = response.usage {
            Log.realtime.debug(
                """
                xAI text generation: \(usage.promptTokens ?? 0, privacy: .public) prompt + \
                \(usage.completionTokens ?? 0, privacy: .public) completion tokens, \
                finish \(choice.finishReason ?? "unknown", privacy: .public)
                """
            )
        }
        return content
    }

    /// The JSON body. Built with `JSONSerialization` rather than the
    /// client's snake-casing encoder, which would rewrite the keys inside
    /// the caller's JSON Schema (`additionalProperties`).
    static func body(for request: TextGenerationRequest, model: String) throws(XAIError) -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.prompt],
            ],
            "max_tokens": request.maximumResponseTokens,
            "temperature": request.temperature,
            "stream": false,
        ]
        if let schema = request.responseSchema {
            guard let object = schema.schemaObject else {
                throw .invalidResponse("The response schema \(schema.name) is not a JSON object")
            }
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.name, "schema": object, "strict": true],
            ]
        }
        do {
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw .invalidResponse("Could not encode the request body: \(error)")
        }
    }

    /// The parts of a chat completion this reads. Decoded with
    /// `convertFromSnakeCase`.
    struct ChatCompletion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
                var refusal: String?
            }
            var message: Message
            var finishReason: String?
        }
        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?
        }
        var choices: [Choice]
        var usage: Usage?
    }
}
