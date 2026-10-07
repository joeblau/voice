import Foundation

/// An OpenAI-compatible chat-completions endpoint (`POST
/// <baseURL>/chat/completions`) as the memory evaluation's reader or judge.
/// The default base URL is xAI's (`https://api.x.ai/v1`), so Grok, the
/// model that answers the user in the app, can read the memories.
///
/// For opt-in local runs only (`make eval-memory MEMORY_EVAL_READER=xai`):
/// the key comes from the environment of the run, never from the repo or CI
/// (docs/memory-eval.md). It goes only into the `Authorization` header and
/// is never logged. Requests use temperature 0.
public struct ChatCompletionsEvalLanguageModel: MemoryEvalLanguageModel {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case http(status: Int, message: String)
        case invalidResponse(String)

        public var description: String {
            switch self {
            case .http(let status, let message): "Chat completions failed with HTTP \(status): \(message)"
            case .invalidResponse(let reason): "Unexpected chat completions response: \(reason)"
            }
        }
    }

    public static let xaiBaseURL = URL(string: "https://api.x.ai/v1")!

    public let baseURL: URL
    public let model: String
    public var maximumTokens: Int
    /// Attempts per call for rate limits (429) and server errors (5xx).
    public var attempts: Int
    /// The wait before retry n is n times this.
    public var retryDelay: Duration
    private let apiKey: String
    private let transport: Transport

    public init(
        model: String, apiKey: String, baseURL: URL = xaiBaseURL, maximumTokens: Int = 300, attempts: Int = 3,
        retryDelay: Duration = .seconds(2),
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maximumTokens = maximumTokens
        self.attempts = max(1, attempts)
        self.retryDelay = retryDelay
        self.transport = transport
    }

    public var identifier: String { model }

    struct Body: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var model: String
        var messages: [Message]
        var temperature: Double
        var maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }

            var message: Message
        }

        var choices: [Choice]
    }

    public func request(instructions: String, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Body(
                model: model,
                messages: [.init(role: "system", content: instructions), .init(role: "user", content: prompt)],
                temperature: 0, maxTokens: maximumTokens))
        return request
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        let request = try request(instructions: instructions, prompt: prompt)
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse("not HTTP") }
            if (200..<300).contains(http.statusCode) {
                let reply: Reply
                do {
                    reply = try JSONDecoder().decode(Reply.self, from: data)
                } catch {
                    throw Failure.invalidResponse("undecodable body")
                }
                guard let content = reply.choices.first?.message.content else {
                    throw Failure.invalidResponse("no choices")
                }
                return content
            }
            let retryable = http.statusCode == 429 || (500..<600).contains(http.statusCode)
            guard retryable, attempt < attempts else {
                throw Failure.http(status: http.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
            }
            try await Task.sleep(for: retryDelay * attempt)
        }
    }
}
