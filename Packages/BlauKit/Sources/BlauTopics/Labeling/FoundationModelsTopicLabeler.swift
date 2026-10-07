#if canImport(FoundationModels)
    import BlauTelemetry
    import Foundation
    import FoundationModels
    import os

    /// Confirms boundaries and titles topics with Apple's on-device model.
    ///
    /// - A fresh `LanguageModelSession` per call, so nothing from one
    ///   boundary leaks into the next and the transcript never grows.
    /// - The prompt holds about six units around the boundary plus the
    ///   previous title, trimmed with `TopicLabelPrompt.fit` to stay well
    ///   under the context window: at most `contextFraction` of
    ///   `min(model.contextSize, maximumContextTokens)`, after the
    ///   instructions, the schema and the reply. Tokens are counted with
    ///   `SystemLanguageModel.tokenCount(for:)` on iOS / macOS 26.4 and
    ///   later, and estimated before that.
    /// - If the model still reports the context window exceeded, the
    ///   request is retried once with half the units, then given up.
    /// - Greedy sampling, so the same conversation gets the same title.
    /// - Guided generation is always checked by the default guardrails, and
    ///   the model refuses ordinary personal-finance talk ("refinance the
    ///   mortgage", "tax deductions") as "May contain sensitive content".
    ///   Labeling only transforms what the user already said, so after a
    ///   guardrail violation or refusal the request is retried once as plain
    ///   text with `.permissiveContentTransformations` (which relaxes text
    ///   output only) and the JSON reply is parsed with `TopicShift.parse(_:)`.
    public struct FoundationModelsTopicLabeler: TopicLabeler {
        /// The structured reply. The `@Guide`s steer the model;
        /// `TopicTitleFormatter` enforces the limits afterwards.
        @Generable
        struct GeneratedTopicShift {
            @Guide(description: "Whether the turns after the change are about a different subject.")
            var isNewTopic: Bool

            @Guide(description: "≤5 words, Title Case")
            var title: String

            @Guide(description: "one sentence")
            var summary: String
        }

        /// Guided generation tripped the guardrails, or the model refused
        /// ("May contain sensitive content").
        struct SensitiveContent: Error {}

        public var source: TopicLabelSource { .foundationModels }

        /// The context budget never assumes more than this, so behaviour
        /// matches iOS 26's 4,096-token window even where the OS offers more.
        public var maximumContextTokens: Int

        /// Share of the context the whole request (instructions, schema,
        /// prompt and reply) may use. Well under the window, because token
        /// estimates are approximate and the guided-generation scaffolding
        /// adds tokens the counts don't see.
        public var contextFraction: Double

        /// Cap on the reply.
        public var maximumResponseTokens: Int

        private let model: SystemLanguageModel
        /// The same model with the guardrails for transforming user content.
        private let permissiveModel: SystemLanguageModel

        public init(
            model: SystemLanguageModel = .default,
            permissiveModel: SystemLanguageModel = SystemLanguageModel(guardrails: .permissiveContentTransformations),
            maximumContextTokens: Int = 4096,
            contextFraction: Double = 0.75,
            maximumResponseTokens: Int = 160
        ) {
            self.model = model
            self.permissiveModel = permissiveModel
            self.maximumContextTokens = maximumContextTokens
            self.contextFraction = contextFraction
            self.maximumResponseTokens = maximumResponseTokens
        }

        /// The model's availability, for settings and diagnostics.
        public var availability: SystemLanguageModel.Availability { model.availability }

        public func isAvailable() async -> Bool {
            model.isAvailable
        }

        public func label(_ request: TopicLabelRequest) async throws -> TopicShift {
            try await label(request, preparedSession: nil)
        }

        // MARK: Prewarming seam

        /// A guided-generation session made ahead of a request, optionally
        /// prewarmed. The on-device benchmark (#22) uses it to measure
        /// `LanguageModelSession.prewarm(promptPrefix:)` on exactly the
        /// session production creates. Use it for one request only.
        struct PreparedSession: Sendable {
            /// The instructions the session was made with.
            let instructions: String
            let session: LanguageModelSession

            /// The session, if it was made for `instructions`.
            func session(for instructions: String) -> LanguageModelSession? {
                instructions == self.instructions ? session : nil
            }
        }

        /// The session `label(_:)` makes for `request`'s first guided
        /// attempt (same model, same instructions). With `prewarm`, it starts
        /// loading the model and the instructions now and returns at once.
        func prepareSession(for request: TopicLabelRequest, prewarm: Bool) -> PreparedSession {
            let instructions = TopicLabelPrompt.instructions(for: request)
            let session = makeGuidedSession(instructions: instructions)
            if prewarm {
                session.prewarm()
            }
            return PreparedSession(instructions: instructions, session: session)
        }

        /// `label(_:)`, running the first guided attempt in `preparedSession`
        /// when it was made for the same instructions. Retries (a smaller
        /// prompt, or plain text after a refusal) always use fresh sessions.
        func label(_ request: TopicLabelRequest, preparedSession: PreparedSession?) async throws -> TopicShift {
            guard model.isAvailable else {
                throw TopicLabelerError.unavailable(String(describing: model.availability))
            }
            do {
                return try await respond(to: request, preparedSession: preparedSession)
            } catch TopicLabelerError.contextWindowExceeded {
                // The counts were off. One more try with half the units.
                var smaller = request
                while smaller.before.count + smaller.after.count > (request.before.count + request.after.count) / 2,
                    let next = TopicLabelPrompt.droppingOneUnit(smaller)
                {
                    smaller = next
                }
                guard smaller != request else { throw TopicLabelerError.contextWindowExceeded }
                Log.topics.info("Topic label prompt exceeded the context window; retrying with fewer units")
                return try await respond(to: smaller, preparedSession: nil)
            }
        }

        private func respond(
            to request: TopicLabelRequest, preparedSession: PreparedSession?
        ) async throws -> TopicShift {
            let instructions = TopicLabelPrompt.instructions(for: request)
            let budget = try await promptBudget(instructions: instructions)
            let fitted = try await TopicLabelPrompt.fit(request, budget: budget) { prompt in
                try await countTokens(prompt)
            }
            do {
                let session =
                    preparedSession?.session(for: instructions) ?? makeGuidedSession(instructions: instructions)
                return try await generateGuided(prompt: fitted.prompt, session: session)
            } catch is SensitiveContent {
                Log.topics.info("Topic label refused as sensitive; retrying as a content transformation")
                return try await generateText(prompt: fitted.prompt, instructions: instructions)
            }
        }

        private var options: GenerationOptions {
            GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        }

        private func makeGuidedSession(instructions: String) -> LanguageModelSession {
            LanguageModelSession(model: model, instructions: instructions)
        }

        private func generateGuided(prompt: String, session: LanguageModelSession) async throws -> TopicShift {
            do {
                let response = try await session.respond(
                    to: prompt, generating: GeneratedTopicShift.self, options: options)
                let shift = response.content
                return TopicShift(isNewTopic: shift.isNewTopic, title: shift.title, summary: shift.summary)
            } catch {
                throw Self.map(error)
            }
        }

        private func generateText(prompt: String, instructions: String) async throws -> TopicShift {
            let session = LanguageModelSession(
                model: permissiveModel, instructions: instructions + "\n" + TopicLabelPrompt.jsonReplyInstruction)
            let reply: String
            do {
                reply = try await session.respond(to: prompt, options: options).content
            } catch {
                let mapped = Self.map(error)
                throw mapped is SensitiveContent ? TopicLabelerError.unavailable("sensitiveContent") : mapped
            }
            return try TopicShift.parse(reply)
        }

        /// Tokens left for the prompt.
        private func promptBudget(instructions: String) async throws -> Int {
            let window = Int(Double(min(model.contextSize, maximumContextTokens)) * contextFraction)
            let fixed: Int
            if #available(iOS 26.4, macOS 26.4, *) {
                fixed =
                    try await model.tokenCount(for: Instructions(instructions))
                    + model.tokenCount(for: GeneratedTopicShift.generationSchema)
            } else {
                // Schema estimate: its JSON plus the guided-generation framing.
                fixed = TopicLabelPrompt.estimatedTokens(instructions) + 200
            }
            let budget = window - fixed - maximumResponseTokens
            guard budget > 0 else { throw TopicLabelerError.contextWindowExceeded }
            return budget
        }

        private func countTokens(_ prompt: String) async throws -> Int {
            if #available(iOS 26.4, macOS 26.4, *) {
                return try await model.tokenCount(for: prompt)
            }
            return TopicLabelPrompt.estimatedTokens(prompt)
        }

        /// Maps the framework's errors to the ones the labeler acts on:
        /// context overflow (retry smaller), guardrails and refusals (retry as
        /// text) and
        /// the `TopicLabelerError`s the service logs. iOS 26 throws
        /// `LanguageModelSession.GenerationError`; iOS 27 also has
        /// `LanguageModelError`.
        static func map(_ error: any Error) -> any Error {
            if let error = error as? LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize: return TopicLabelerError.contextWindowExceeded
                case .guardrailViolation, .refusal: return SensitiveContent()
                case .assetsUnavailable: return TopicLabelerError.unavailable("assetsUnavailable")
                case .decodingFailure: return TopicLabelerError.invalidResponse("decodingFailure")
                default: return error
                }
            }
            if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return TopicLabelerError.contextWindowExceeded
                case .guardrailViolation, .refusal: return SensitiveContent()
                default: return error
                }
            }
            return error
        }
    }
#endif
