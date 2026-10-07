import BlauCore
import Foundation

/// The first fallback when Apple Intelligence is unavailable: the same task
/// sent to a hosted model through a `TextGenerator`. In the app that is
/// `XAITextGenerator`, xAI's text API called directly with the user's key
/// from the Keychain (#33).
///
/// It asks for structured output with `TopicLabelPrompt.jsonSchema` and
/// parses the reply leniently (a JSON object anywhere in the text, string or
/// boolean `isNewTopic`), because structured output is a request, not a
/// guarantee.
public struct RemoteTopicLabeler: TopicLabeler {
    public let source: TopicLabelSource
    private let generator: any TextGenerator

    /// Prompt budget, in estimated tokens. The hosted model's window is far
    /// larger; this caps cost and latency, and matches what the on-device
    /// model sees.
    public var promptTokenBudget: Int

    public var maximumResponseTokens: Int

    public var timeout: Duration

    public init(
        generator: any TextGenerator,
        source: TopicLabelSource = .xai,
        promptTokenBudget: Int = 2_500,
        maximumResponseTokens: Int = 160,
        timeout: Duration = .seconds(10)
    ) {
        self.generator = generator
        self.source = source
        self.promptTokenBudget = promptTokenBudget
        self.maximumResponseTokens = maximumResponseTokens
        self.timeout = timeout
    }

    public func isAvailable() async -> Bool {
        await generator.isAvailable()
    }

    public func label(_ request: TopicLabelRequest) async throws -> TopicShift {
        let fitted = try await TopicLabelPrompt.fit(request, budget: promptTokenBudget) { prompt in
            TopicLabelPrompt.estimatedTokens(prompt)
        }
        let reply = try await generator.generate(
            TextGenerationRequest(
                instructions: TopicLabelPrompt.instructions(for: request)
                    + "\n" + TopicLabelPrompt.jsonReplyInstruction,
                prompt: fitted.prompt,
                responseSchema: JSONResponseSchema(name: "TopicShift", schema: TopicLabelPrompt.jsonSchema),
                maximumResponseTokens: maximumResponseTokens,
                temperature: 0,
                timeout: timeout
            )
        )
        return try TopicShift.parse(reply)
    }
}
