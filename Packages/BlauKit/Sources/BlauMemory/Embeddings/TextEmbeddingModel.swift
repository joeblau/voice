import BlauCore
import BlauTelemetry
import CoreML
import Foundation
import os

/// Turns text into token IDs for a text-embedding model.
public protocol TextTokenizing: Sendable {
    /// The IDs of `text`, special tokens included, cut to at most
    /// `maximumLength` IDs.
    func encode(_ text: String, maximumLength: Int?) -> HuggingFaceTokenizer.Encoding
}

extension HuggingFaceTokenizer: TextTokenizing {}

/// A loaded text-embedding model: tokenizer, Core ML network and the spec
/// that says how to prompt it and store its vectors. The shared embedding
/// service behind memory search (#62, #64) and topic segmentation (#52).
///
/// ```swift
/// let model = try await TextEmbeddingModel.load(bundle: TextEmbeddingBundle(directory: directory))
/// let chunks = try await model.embed(exchanges, as: .document)   // batches of 32
/// let query = try await model.embed("when did I start running?", as: .query)
/// chunks[0].cosineSimilarity(to: query)
/// ```
///
/// Every text gets the spec's task prompt, is tokenized and cut to the
/// model's sequence length (`maximumTokens`, prompt and special tokens
/// included; `TextEmbedding.truncatedTokens` says how much was lost, and
/// `tokenCount(of:as:)` lets the indexer chunk text so nothing is), and runs
/// through the network. The full-width output is cut to the Matryoshka
/// prefix (256-d), L2-normalized and quantized to int8 with one scale per
/// vector. Each vector carries `modelVersion`.
///
/// `embed(_:as:)` processes at most `batchSize` texts per batch, each inside
/// one `memory.embed` signpost interval. A non-finite model output (the
/// float16 failure #59 warns about) becomes a zero vector and a fault in
/// the log rather than a NaN in the index.
public actor TextEmbeddingModel {
    /// What the model has done since it was loaded.
    public struct Statistics: Hashable, Sendable {
        public var texts = 0
        public var batches = 0
        public var tokens = 0
        public var truncatedTexts = 0
        public var nonFiniteVectors = 0
        /// Wall time of the most recent batch.
        public var lastBatchDuration: Duration?
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The network's output isn't `fullDimensions` wide.
        case unexpectedWidth(expected: Int, got: Int)
        /// The Core ML model accepts fewer tokens than the bundle claims.
        case sequenceLengthMismatch(model: Int, bundle: Int)

        public var description: String {
            switch self {
            case .unexpectedWidth(let expected, let got): "The model returned \(got) values, expected \(expected)"
            case .sequenceLengthMismatch(let model, let bundle):
                "The model takes \(model) tokens but its bundle says \(bundle)"
            }
        }
    }

    /// The batch size the memory indexer uses (#60's acceptance criterion
    /// is measured on it).
    public static let defaultBatchSize = 32

    public nonisolated let spec: TextEmbeddingModelSpec
    /// Recorded with every vector; see `TextEmbeddingBundle.modelVersion`.
    public nonisolated let modelVersion: String
    /// Longest input in tokens, prompt and special tokens included.
    public nonisolated let maximumTokens: Int
    /// Width of the stored vectors.
    public nonisolated let storedDimensions: Int
    public nonisolated let batchSize: Int

    public private(set) var statistics = Statistics()

    private let tokenizer: any TextTokenizing
    private let network: any TokenEmbeddingModel
    private let clock: any BlauClock
    private let signposter: Signposter

    /// Assembles a model from parts that are already loaded. `load(bundle:)`
    /// is the production path; tests pass fakes.
    public init(
        spec: TextEmbeddingModelSpec,
        modelVersion: String,
        tokenizer: any TextTokenizing,
        network: any TokenEmbeddingModel,
        maximumTokens: Int,
        batchSize: Int = TextEmbeddingModel.defaultBatchSize,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory
    ) {
        self.spec = spec
        self.modelVersion = modelVersion
        self.tokenizer = tokenizer
        self.network = network
        self.maximumTokens = maximumTokens
        self.storedDimensions = min(spec.storedDimensions, spec.fullDimensions)
        self.batchSize = max(1, batchSize)
        self.clock = clock
        self.signposter = signposter
    }

    /// Loads an installed bundle: the tokenizer and the Core ML model (with
    /// its token table) in parallel. The first load on a device compiles the
    /// model for its Neural Engine; `ModelManager`'s warm-up normally did
    /// that already.
    ///
    /// - Parameters:
    ///   - revision: The installed files' pinned revision, for
    ///     `modelVersion`.
    ///   - computeUnits: Where Core ML runs the model. The Neural Engine with
    ///     CPU fallback by default, like every other Blau model.
    @concurrent
    public static func load(
        bundle: TextEmbeddingBundle,
        revision: String? = nil,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        batchSize: Int = defaultBatchSize,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory
    ) async throws -> TextEmbeddingModel {
        let started = clock.uptime
        let network = CoreMLTokenEmbeddingModel(
            url: bundle.modelURL, computeUnits: computeUnits, tokenEmbeddings: bundle.tokenEmbeddingsURL)
        // Parsing the tokenizer (tens of MB of JSON) overlaps the Core ML load.
        async let tokenizer = HuggingFaceTokenizer(contentsOf: bundle.tokenizerURL)
        let loadedTokenizer: HuggingFaceTokenizer
        do {
            try await network.load()
            loadedTokenizer = try await tokenizer
        } catch {
            await network.unload()
            throw error
        }

        let accepted = await network.maximumSequenceLength
        guard accepted >= bundle.maximumTokens else {
            await network.unload()
            throw Failure.sequenceLengthMismatch(model: accepted, bundle: bundle.maximumTokens)
        }
        let model = TextEmbeddingModel(
            spec: bundle.spec,
            modelVersion: bundle.modelVersion(revision: revision),
            tokenizer: loadedTokenizer,
            network: network,
            maximumTokens: bundle.maximumTokens,
            batchSize: batchSize,
            clock: clock,
            signposter: signposter
        )
        let elapsed = clock.uptime - started
        Log.memory.notice(
            """
            Loaded text embedding model \(model.modelVersion, privacy: .public) \
            (\(bundle.maximumTokens, privacy: .public) tokens) in \
            \(Int((elapsed / .milliseconds(1)).rounded()), privacy: .public) ms
            """
        )
        return model
    }

    /// The text the model sees for `text`: the task prompt plus the text.
    public nonisolated func prompted(_ text: String, as task: TextEmbeddingTask) -> String {
        switch task {
        case .query: spec.queryText(text)
        case .document: spec.documentText(text)
        }
    }

    /// How many tokens `text` takes as `task`, prompt and special tokens
    /// included, without truncation. More than `maximumTokens` means the
    /// embedding will only cover the start of the text.
    public nonisolated func tokenCount(of text: String, as task: TextEmbeddingTask) -> Int {
        tokenizer.encode(prompted(text, as: task), maximumLength: nil).ids.count
    }

    /// Embeds one text.
    public func embed(_ text: String, as task: TextEmbeddingTask) async throws -> TextEmbedding {
        try await embed([text], as: task)[0]
    }

    /// Embeds `texts`, in order, `batchSize` at a time.
    ///
    /// - Throws: `CancellationError` between texts, or the network's error.
    public func embed(_ texts: [String], as task: TextEmbeddingTask) async throws -> [TextEmbedding] {
        var embeddings: [TextEmbedding] = []
        embeddings.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let end = min(texts.count, start + batchSize)
            embeddings += try await embedBatch(texts[start..<end], as: task)
            start = end
        }
        return embeddings
    }

    private func embedBatch(_ texts: ArraySlice<String>, as task: TextEmbeddingTask) async throws -> [TextEmbedding] {
        let interval = signposter.beginInterval(.memoryEmbed)
        let started = clock.uptime
        var tokenTotal = 0
        defer {
            interval.end(message: "\(texts.count) texts, \(tokenTotal) tokens")
        }

        let encodings = texts.map { tokenizer.encode(prompted($0, as: task), maximumLength: maximumTokens) }
        tokenTotal = encodings.reduce(0) { $0 + $1.ids.count }
        let outputs = try await network.embed(batch: encodings.map(\.ids))

        var embeddings: [TextEmbedding] = []
        embeddings.reserveCapacity(texts.count)
        var nonFinite = 0
        for (encoding, output) in zip(encodings, outputs) {
            guard output.count == spec.fullDimensions else {
                throw Failure.unexpectedWidth(expected: spec.fullDimensions, got: output.count)
            }
            var vector = output
            if !vector.allSatisfy(\.isFinite) {
                nonFinite += 1
                vector = [Float](repeating: 0, count: output.count)
            }
            embeddings.append(
                TextEmbedding(
                    fullOutput: vector, dimensions: storedDimensions, modelVersion: modelVersion,
                    tokenCount: encoding.ids.count, truncatedTokens: encoding.truncatedTokens))
        }

        let elapsed = clock.uptime - started
        let truncated = encodings.filter(\.wasTruncated).count
        statistics.texts += texts.count
        statistics.batches += 1
        statistics.tokens += tokenTotal
        statistics.truncatedTexts += truncated
        statistics.nonFiniteVectors += nonFinite
        statistics.lastBatchDuration = elapsed

        if nonFinite > 0 {
            Log.memory.fault(
                "\(nonFinite, privacy: .public) of \(texts.count, privacy: .public) embeddings were not finite; stored as zero vectors"
            )
        }
        Log.memory.debug(
            """
            Embedded \(texts.count, privacy: .public) \(task.rawValue, privacy: .public) texts \
            (\(tokenTotal, privacy: .public) tokens, \(truncated, privacy: .public) truncated) in \
            \(Int((elapsed / .milliseconds(1)).rounded()), privacy: .public) ms
            """
        )
        return embeddings
    }
}
