import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

@Suite("XAITextGenerator")
struct XAITextGeneratorTests {
    static let schema = JSONResponseSchema(
        name: "TopicShift",
        schema: Data(
            #"{"type":"object","additionalProperties":false,"required":["title"],"properties":{"title":{"type":"string"}}}"#
                .utf8))

    static let request = TextGenerationRequest(
        instructions: "Title the topic.", prompt: "User: sourdough", responseSchema: schema,
        maximumResponseTokens: 120, temperature: 0, timeout: .seconds(7))

    static let reply = """
        {"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant",\
        "content":"{\\"title\\":\\"Sourdough Baking\\"}","refusal":null},"finish_reason":"stop"}],\
        "usage":{"prompt_tokens":40,"completion_tokens":8,"total_tokens":48}}
        """

    @Test func postsAChatCompletionWithTheStoredKey() async throws {
        let transport = ScriptedTransport(routes: ["/v1/chat/completions": .json(200, Self.reply)])
        let generator = XAITextGenerator(client: .test(transport: transport))

        let text = try await generator.generate(Self.request)
        #expect(text == #"{"title":"Sourdough Baking"}"#)

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.primaryRaw)")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 7)

        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == XAITextGenerator.defaultModel)
        #expect(body["max_tokens"] as? Int == 120)
        #expect(body["temperature"] as? Double == 0)
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(
            messages == [
                ["role": "system", "content": "Title the topic."], ["role": "user", "content": "User: sourdough"],
            ])

        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "TopicShift")
        #expect(jsonSchema["strict"] as? Bool == true)
        // The schema's own keys are not snake-cased.
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func omitsTheResponseFormatForPlainText() throws {
        let request = TextGenerationRequest(instructions: "i", prompt: "p")
        let body = try XAITextGenerator.body(for: request, model: "grok-test")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["response_format"] == nil)
        #expect(object["model"] as? String == "grok-test")
    }

    @Test func rejectsASchemaThatIsNotAnObject() {
        let request = TextGenerationRequest(
            instructions: "i", prompt: "p", responseSchema: JSONResponseSchema(name: "x", schema: Data("[1]".utf8)))
        #expect(throws: XAIError.self) { try XAITextGenerator.body(for: request, model: "m") }
    }

    @Test func availabilityFollowsTheStoredKey() async {
        let transport = ScriptedTransport(routes: [:])
        #expect(await XAITextGenerator(client: .test(transport: transport)).isAvailable())
        #expect(
            !(await XAITextGenerator(client: .test(store: InMemoryAPIKeyStore(), transport: transport)).isAvailable()))
        #expect(
            !(await XAITextGenerator(client: .test(store: FailingAPIKeyStore(error: .locked), transport: transport))
                .isAvailable()))
        #expect(transport.requests.isEmpty)
    }

    @Test func missingKeyFailsWithoutANetworkCall() async {
        let transport = ScriptedTransport(routes: [:])
        let generator = XAITextGenerator(client: .test(store: InMemoryAPIKeyStore(), transport: transport))
        await #expect(throws: XAIError.missingAPIKey) { try await generator.generate(Self.request) }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        #"{"choices":[]}"#,
        #"{"choices":[{"message":{"content":null},"finish_reason":"length"}]}"#,
        #"{"choices":[{"message":{"content":"  "}}]}"#,
        #"{"choices":[{"message":{"content":"x","refusal":"I can't help with that."}}]}"#,
        #"{"unexpected":true}"#,
    ])
    func unusableRepliesAreInvalidResponses(_ reply: String) async {
        let transport = ScriptedTransport(routes: ["/v1/chat/completions": .json(200, reply)])
        let generator = XAITextGenerator(client: .test(transport: transport))
        await #expect {
            try await generator.generate(Self.request)
        } throws: { error in
            if case .invalidResponse = error as? XAIError { true } else { false }
        }
    }

    @Test func httpErrorsAreClassified() async {
        let transport = ScriptedTransport(routes: ["/v1/chat/completions": .json(401, #"{"error":"bad key"}"#)])
        let generator = XAITextGenerator(client: .test(transport: transport))
        await #expect {
            try await generator.generate(Self.request)
        } throws: { error in
            if case .invalidAPIKey = error as? XAIError { true } else { false }
        }
    }
}
