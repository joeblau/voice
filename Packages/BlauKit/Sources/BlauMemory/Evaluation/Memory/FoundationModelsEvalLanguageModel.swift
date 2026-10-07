#if canImport(FoundationModels)
    import Foundation
    import FoundationModels

    /// Apple's on-device model as the memory evaluation's reader and judge:
    /// no key, no network, and the same answers every run (greedy decoding).
    ///
    /// The reader transforms the user's own memories, so it runs with
    /// `.permissiveContentTransformations` guardrails, like the topic
    /// labeler's text fallback (#53); otherwise ordinary personal topics
    /// (money, health) are refused as sensitive. Each call is a fresh
    /// session.
    public struct FoundationModelsEvalLanguageModel: MemoryEvalLanguageModel {
        public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
            case unavailable(String)

            public var description: String {
                switch self {
                case .unavailable(let reason): "Apple's on-device model is unavailable: \(reason)"
                }
            }
        }

        public var identifier: String { "apple-foundation-models" }
        public var maximumResponseTokens: Int
        private let model: SystemLanguageModel

        public init(
            model: SystemLanguageModel = SystemLanguageModel(guardrails: .permissiveContentTransformations),
            maximumResponseTokens: Int = 200
        ) {
            self.model = model
            self.maximumResponseTokens = maximumResponseTokens
        }

        /// Whether the model can run here (Apple Intelligence on, assets
        /// downloaded). CI virtual machines usually can't.
        public var isAvailable: Bool { model.isAvailable }

        public var availabilityDescription: String { String(describing: model.availability) }

        public func respond(instructions: String, prompt: String) async throws -> String {
            guard model.isAvailable else { throw Failure.unavailable(availabilityDescription) }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
            return try await session.respond(to: prompt, options: options).content
        }
    }
#endif
