import BlauCore
import BlauTelemetry
import Foundation

/// A text-embedding model fed token IDs directly, as the benchmark sees it.
///
/// Latency depends on how many tokens go in, not on which ones, so the
/// benchmark feeds deterministic synthetic token IDs and needs no
/// tokenizer.
public protocol TokenEmbeddingModel: Sendable {
    /// Loads (and if needed compiles) the model. Timed as `load`.
    func load() async throws
    /// The longest sequence the model accepts.
    var maximumSequenceLength: Int { get async }
    /// The model's full-width embedding for `tokenIDs`.
    func embed(tokenIDs: [Int32]) async throws -> [Float]
    /// The embeddings of several sequences, in order. The default embeds
    /// them one after another.
    func embed(batch: [[Int32]]) async throws -> [[Float]]
    func unload() async
}

extension TokenEmbeddingModel {
    public func embed(batch: [[Int32]]) async throws -> [[Float]] {
        var outputs: [[Float]] = []
        outputs.reserveCapacity(batch.count)
        for tokenIDs in batch {
            try Task.checkCancellation()
            outputs.append(try await embed(tokenIDs: tokenIDs))
        }
        return outputs
    }
}

/// Measures a Matryoshka text-embedding model the way the memory indexer
/// uses it (#60): embed an exchange-sized chunk, keep the first 256
/// dimensions, L2-normalize and quantize to int8. Latency covers all of it.
public struct TextEmbeddingBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        /// Chunk lengths in tokens. Lengths above the model's maximum are
        /// skipped.
        public var sequenceLengths: [Int]
        /// Matryoshka truncation width.
        public var dimensions: Int
        public var iterations: Int
        public var warmupIterations: Int

        public init(
            sequenceLengths: [Int] = [64, 128, 256],
            dimensions: Int = 256,
            iterations: Int = 30,
            warmupIterations: Int = 3
        ) {
            self.sequenceLengths = sequenceLengths
            self.dimensions = dimensions
            self.iterations = iterations
            self.warmupIterations = warmupIterations
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .memory }

    private let model: @Sendable () throws -> any TokenEmbeddingModel
    private let configuration: Configuration
    private let signposter: Signposter

    /// - Parameter model: Makes the model. Throw `BenchmarkSkip` from it when
    ///   the model isn't installed.
    public init(
        id: String,
        title: String,
        model: @escaping @Sendable () throws -> any TokenEmbeddingModel,
        configuration: Configuration = Configuration(),
        signposter: Signposter = Signposts.memory
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.configuration = configuration
        self.signposter = signposter
    }

    /// EmbeddingGemma-300M as a Core ML model found by
    /// `CoreMLTokenEmbeddingModel.locate(named:in:)`, id
    /// `memory.embeddinggemma`. Skipped when no model is installed.
    public static func embeddingGemma(searching directories: [URL], configuration: Configuration = Configuration())
        -> TextEmbeddingBenchmark
    {
        TextEmbeddingBenchmark(
            id: "memory.embeddinggemma",
            title: "EmbeddingGemma-300M, 256-d int8",
            model: {
                guard let url = CoreMLTokenEmbeddingModel.locate(named: "EmbeddingGemma", in: directories) else {
                    throw BenchmarkSkip(
                        "No EmbeddingGemma*.mlmodelc or .mlpackage in "
                            + directories.map(\.path).joined(separator: ", ") + "; see docs/benchmarks.md")
                }
                return CoreMLTokenEmbeddingModel(url: url)
            },
            configuration: configuration
        )
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        let model = try model()
        var memory = context.memoryWatermark()
        recorder.progress(nil, "Loading model")
        let (_, loadTime) = try await context.measure { try await model.load() }
        recorder.record("load", loadTime)
        memory.sample()

        let maximum = await model.maximumSequenceLength
        let lengths = configuration.sequenceLengths.filter { $0 <= maximum }
        guard !lengths.isEmpty else {
            throw BenchmarkSkip("The model accepts at most \(maximum) tokens")
        }
        recorder.note("Synthetic token IDs; maximum sequence length \(maximum)")

        var fullDimensions = 0
        var generator = TokenGenerator(seed: 22)
        for (index, length) in lengths.enumerated() {
            var latencies: [Duration] = []
            let total = configuration.warmupIterations + configuration.iterations
            for iteration in 0..<total {
                try Task.checkCancellation()
                let tokens = generator.tokens(count: length)
                let (vector, elapsed) = try await context.measure {
                    try await signposter.withInterval(.memoryEmbed) {
                        let full = try await model.embed(tokenIDs: tokens)
                        let truncated = MatryoshkaEmbedding.truncatedAndNormalized(full, to: configuration.dimensions)
                        return (full.count, MatryoshkaEmbedding.quantized(truncated))
                    }
                }
                fullDimensions = vector.0
                if iteration >= configuration.warmupIterations { latencies.append(elapsed) }
                recorder.progress(
                    Double(index * total + iteration + 1) / Double(lengths.count * total), "\(length)-token chunks")
            }
            recorder.recordLatencies("embed.\(length)tok", latencies)
            memory.sample()
        }
        recorder.record("dimensions.full", Double(fullDimensions), unit: .count)
        recorder.record("dimensions.kept", Double(min(configuration.dimensions, fullDimensions)), unit: .count)
        recorder.recordMemory(memory)
        await model.unload()
        recorder.progress(1, "Done")
    }
}

/// Matryoshka truncation and int8 quantization, as the memory index stores
/// vectors (#60, #62).
public enum MatryoshkaEmbedding {
    /// The first `dimensions` components, L2-normalized. Returns the input
    /// unchanged (but normalized) when it is shorter.
    public static func truncatedAndNormalized(_ vector: [Float], to dimensions: Int) -> [Float] {
        let prefix = Array(vector.prefix(max(0, dimensions)))
        let norm = prefix.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return prefix }
        return prefix.map { $0 / norm }
    }

    /// Symmetric int8 quantization: `value ≈ Float(code) * scale`, with the
    /// largest magnitude mapped to ±127.
    public static func quantized(_ vector: [Float]) -> (codes: [Int8], scale: Float) {
        let largest = vector.reduce(0) { max($0, abs($1)) }
        guard largest > 0 else { return (Array(repeating: 0, count: vector.count), 0) }
        let scale = largest / 127
        let codes = vector.map { Int8(clamping: Int(($0 / scale).rounded())) }
        return (codes, scale)
    }
}

/// Deterministic token IDs in an ordinary-vocabulary range (avoiding the
/// low IDs where tokenizers keep special tokens).
struct TokenGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func tokens(count: Int) -> [Int32] {
        (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int32(1_000 + Int((state >> 33) % 30_000))
        }
    }
}
