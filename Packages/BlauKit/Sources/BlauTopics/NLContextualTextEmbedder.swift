#if canImport(NaturalLanguage)
    import BlauCore
    import BlauTelemetry
    import NaturalLanguage
    import os

    /// Embeds text with Apple's on-device `NLContextualEmbedding` (a
    /// BERT-style transformer), mean-pooling its subword token vectors into one
    /// vector.
    ///
    /// The first `TextEmbedder` the topic segmenter uses in production. M3
    /// replaces it with the shared EmbeddingGemma service (#60), which plugs in
    /// through the same protocol.
    ///
    /// The model's assets are downloaded by the OS on demand. `embed(_:)`
    /// never downloads: call `prepare(allowAssetDownload: true)` from a place
    /// where a download is acceptable (onboarding, model setup), and fall back
    /// to `LexicalTextEmbedder` while `hasAvailableAssets` is `false`.
    ///
    /// An actor because `NLContextualEmbedding` is not `Sendable`: the model
    /// object never leaves this actor.
    public actor NLContextualTextEmbedder: TextEmbedder {
        public enum Failure: Error, Hashable, Sendable {
            /// The model's assets aren't on the device and a download wasn't
            /// allowed, failed, or isn't possible.
            case assetsUnavailable
        }

        public nonisolated let modelIdentifier: String

        /// Length of every vector `embed(_:)` returns.
        public nonisolated let dimension: Int

        private let embedding: NLContextualEmbedding
        private let language: NLLanguage
        private var isLoaded = false

        /// Returns `nil` when the OS has no contextual embedding model for
        /// `language`.
        public init?(language: NLLanguage = .english) {
            guard let embedding = NLContextualEmbedding(language: language) else { return nil }
            self.embedding = embedding
            self.language = language
            self.modelIdentifier = "nl-contextual-\(embedding.modelIdentifier)-r\(embedding.revision)"
            self.dimension = embedding.dimension
        }

        /// Whether the model's assets are already on the device.
        public var hasAvailableAssets: Bool { embedding.hasAvailableAssets }

        /// Loads the model, first asking the OS to download its assets if they
        /// are missing and `allowAssetDownload` is `true`.
        ///
        /// - Throws: `Failure.assetsUnavailable`, or the model's load error.
        public func prepare(allowAssetDownload: Bool) async throws {
            guard !isLoaded else { return }
            if !embedding.hasAvailableAssets {
                guard allowAssetDownload else { throw Failure.assetsUnavailable }
                let result = try await requestAssets()
                guard result == .available else {
                    Log.topics.error("Contextual embedding assets unavailable: \(result.rawValue, privacy: .public)")
                    throw Failure.assetsUnavailable
                }
            }
            try embedding.load()
            isLoaded = true
            Log.topics.notice(
                "Loaded contextual embedding \(self.modelIdentifier, privacy: .public), \(self.dimension, privacy: .public)-d"
            )
        }

        /// Frees the model's memory. The next `embed(_:)` loads it again.
        public func unload() {
            guard isLoaded else { return }
            embedding.unload()
            isLoaded = false
        }

        /// The mean of the token vectors of `text`, or a zero vector for text
        /// with no tokens. Text past the model's maximum sequence length is
        /// truncated by the model.
        ///
        /// - Throws: `Failure.assetsUnavailable` when the assets aren't on the
        ///   device (it never downloads), or the model's error.
        public func embed(_ text: String) async throws -> [Float] {
            try await prepare(allowAssetDownload: false)
            var sum = [Double](repeating: 0, count: dimension)
            guard !text.isEmpty else { return [Float](repeating: 0, count: dimension) }

            let result = try embedding.embeddingResult(for: text, language: language)
            var tokens = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                guard vector.count == sum.count else { return true }
                for index in vector.indices {
                    sum[index] += vector[index]
                }
                tokens += 1
                return true
            }
            guard tokens > 0 else { return [Float](repeating: 0, count: dimension) }
            let scale = 1 / Double(tokens)
            return sum.map { Float($0 * scale) }
        }

        private func requestAssets() async throws -> NLContextualEmbedding.AssetsResult {
            try await withCheckedThrowingContinuation { continuation in
                embedding.requestAssets { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
        }
    }
#endif
