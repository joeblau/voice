import BlauCore
import BlauTelemetry
import CoreML
import Foundation

/// The shared text-embedding service the way the memory indexer drives it
/// (#60): a batch of 32 chunks, each filled close to the model's sequence
/// length, through the whole path (prompt, tokenizer, token table, Core ML,
/// Matryoshka 256-d, int8). The acceptance criterion: **a batch of 32
/// embeds within the budget from #59**, an iPhone `embed.128tok` p95 of at
/// most 50 ms, so at most 1.6 s per batch.
///
/// Records `load`, `embed.batch32` (the whole batch), `embed.batch32.chunk`
/// (per chunk), `tokens.mean`, `budget.batch32` and a verdict note. Skipped
/// when no converted model is installed.
public struct TextEmbeddingBatchBenchmark: BenchmarkCase {
    /// The budget per chunk from #59 (`EmbeddingModelSelection`).
    public static let chunkBudget: Duration = .milliseconds(50)

    public let id: String
    public let title: String
    public var category: LogCategory { .memory }

    private let load: @Sendable () async throws -> TextEmbeddingModel
    private let batchSize: Int
    private let batches: Int
    private let warmupBatches: Int

    public init(
        id: String = "memory.embed.batch32",
        title: String = "Shared text embedding, batch of 32",
        batchSize: Int = TextEmbeddingModel.defaultBatchSize,
        batches: Int = 10,
        warmupBatches: Int = 2,
        load: @escaping @Sendable () async throws -> TextEmbeddingModel
    ) {
        self.id = id
        self.title = title
        self.load = load
        self.batchSize = batchSize
        self.batches = batches
        self.warmupBatches = warmupBatches
    }

    /// The first bundle (a folder with `blau-embedding.json`, as
    /// `convert_coreml.py` writes for hosting and `ModelManager` installs)
    /// in `directories` or their immediate subfolders, loaded with Core ML.
    public static func installed(
        searching directories: [URL], computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) -> TextEmbeddingBatchBenchmark {
        TextEmbeddingBatchBenchmark {
            guard let directory = locateBundle(in: directories) else {
                throw BenchmarkSkip(
                    "No folder with \(TextEmbeddingBundle.metadataFileName) in "
                        + directories.map(\.path).joined(separator: ", ") + "; see docs/benchmarks.md")
            }
            return try await TextEmbeddingModel.load(
                bundle: TextEmbeddingBundle(directory: directory), computeUnits: computeUnits)
        }
    }

    static func locateBundle(in directories: [URL]) -> URL? {
        let fileManager = FileManager.default
        for directory in directories {
            let candidates =
                [directory]
                + ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in candidates {
                let metadata = candidate.appending(path: TextEmbeddingBundle.metadataFileName)
                if fileManager.fileExists(atPath: metadata.path(percentEncoded: false)) { return candidate }
            }
        }
        return nil
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        var memory = context.memoryWatermark()
        recorder.progress(nil, "Loading model")
        let (model, loadTime) = try await context.measure { try await load() }
        recorder.record("load", loadTime)
        memory.sample()

        let chunks = Self.chunks(count: batchSize, filling: model)
        let tokens = chunks.map { min(model.tokenCount(of: $0, as: .document), model.maximumTokens) }
        recorder.note(
            "\(model.modelVersion); \(batchSize) chunks of \(tokens.min() ?? 0)–\(tokens.max() ?? 0) tokens "
                + "(sequence length \(model.maximumTokens))")

        var latencies: [Duration] = []
        let total = warmupBatches + batches
        for iteration in 0..<total {
            try Task.checkCancellation()
            let (embeddings, elapsed) = try await context.measure { try await model.embed(chunks, as: .document) }
            guard embeddings.count == chunks.count else {
                throw TextEmbeddingModel.Failure.unexpectedWidth(expected: chunks.count, got: embeddings.count)
            }
            if iteration >= warmupBatches { latencies.append(elapsed) }
            memory.sample()
            recorder.progress(Double(iteration + 1) / Double(total), "Batch \(iteration + 1) of \(total)")
        }

        recorder.recordLatencies("embed.batch\(batchSize)", latencies)
        recorder.recordLatencies("embed.batch\(batchSize).chunk", latencies.map { $0 / batchSize })
        recorder.record("tokens.mean", Double(tokens.reduce(0, +)) / Double(max(1, tokens.count)), unit: .count)
        let budget = Self.chunkBudget * batchSize
        recorder.record("budget.batch\(batchSize)", budget)
        if let p95 = LatencySummary(latencies)?.p95 {
            let budgetMilliseconds = budget / .milliseconds(1)
            recorder.note(
                p95 <= budgetMilliseconds
                    ? "Within budget: p95 \(Int(p95.rounded())) ms ≤ \(Int(budgetMilliseconds)) ms per batch"
                    : "Over budget: p95 \(Int(p95.rounded())) ms > \(Int(budgetMilliseconds)) ms per batch")
        }
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }

    /// `count` distinct, deterministic exchange-like chunks, each about 90%
    /// of the model's sequence length once prompted and tokenized, so the
    /// batch costs what full-length indexing chunks cost.
    static func chunks(count: Int, filling model: TextEmbeddingModel) -> [String] {
        let target = max(1, model.maximumTokens * 9 / 10)
        var generator = SplitMix(seed: 60)
        return (0..<count).map { index in
            var text = "User: \(sentence(&generator)) Blau:"
            var guardCount = 0
            while model.tokenCount(of: text, as: .document) < target, guardCount < 200 {
                text += " " + sentence(&generator)
                guardCount += 1
            }
            return "\(index). " + text
        }
    }

    private static let words = [
        "we", "talked", "about", "the", "launch", "plan", "for", "next", "quarter", "and", "how", "revenue", "grew",
        "after", "pricing", "changed", "my", "marathon", "training", "is", "going", "well", "since", "I", "added",
        "tempo", "runs", "on", "tuesdays", "investors", "asked", "about", "churn", "retention", "cohorts", "team",
        "hiring", "engineers", "in", "Lisbon", "restaurant", "kitchens", "inventory", "software", "customers",
        "love", "the", "new", "dashboard", "because", "it", "saves", "hours", "every", "week", "remember", "that",
    ]

    private static func sentence(_ generator: inout SplitMix) -> String {
        let length = 8 + Int(generator.next() % 8)
        let words = (0..<length).map { _ in Self.words[Int(generator.next() % UInt64(Self.words.count))] }
        return words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + "."
    }

    struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
