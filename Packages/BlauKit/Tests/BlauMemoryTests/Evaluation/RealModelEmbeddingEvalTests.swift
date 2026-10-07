import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Testing

#if canImport(CoreML)
    import CoreML
#endif
#if canImport(NaturalLanguage)
    import NaturalLanguage
#endif

/// Runs the personal retrieval eval (#59) on real models on this Mac. Off by
/// default (`BLAU_DEVICE_TESTS=1`, part of `make bench-kit`):
///
///     # Apple's NLContextualEmbedding baseline (skips if the OS assets are missing)
///     BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModelEmbeddingEvalTests
///
///     # A Core ML model from scripts/embeddings/convert_coreml.py
///     BLAU_DEVICE_TESTS=1 BLAU_EMBEDDING_MODEL=<dir>/Qwen3Embedding06B.mlpackage \
///       BLAU_EMBEDDING_TOKENS=<dir>/Qwen3Embedding06B.eval-tokens.json \
///       BLAU_EMBEDDING_SPEC=qwen3-embedding-0.6b BLAU_EMBEDDING_COMPUTE_UNITS=cpuAndNeuralEngine \
///       swift test -c release --filter RealModelEmbeddingEvalTests
///
/// Prints a Markdown summary; `BLAU_BENCH_OUTPUT=<dir>` also keeps the JSON.
@Suite(
    "Real-model embedding retrieval eval (BLAU_DEVICE_TESTS=1)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .serialized
)
struct RealModelEmbeddingEvalTests {
    static let environment = ProcessInfo.processInfo.environment

    static func report(_ evaluation: EmbeddingRetrievalEvaluator.Evaluation, name: String) throws {
        let r = evaluation.result.overall
        func format(_ value: Double) -> String { String(format: "%.3f", value) }
        var lines = [
            "## \(name) (\(evaluation.modelIdentifier), \(evaluation.storedDimensions)-d int8 of \(evaluation.fullDimensions))",
            "",
            "| Slice | Queries | Recall@5 | Hit@5 | MRR@10 | nDCG@10 |",
            "| --- | --- | --- | --- | --- | --- |",
            "| all | \(r.count) | \(format(r.recallAt5)) | \(format(r.hitAt5)) | \(format(r.mrrAt10)) | \(format(r.ndcgAt10)) |",
        ]
        for (slice, m) in evaluation.result.byCategory.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "| \(slice) | \(m.count) | \(format(m.recallAt5)) | \(format(m.hitAt5)) | \(format(m.mrrAt10)) | \(format(m.ndcgAt10)) |"
            )
        }
        if let documents = evaluation.documentLatency, let queries = evaluation.queryLatency {
            lines.append("")
            lines.append(
                "Embed latency p50 / p95: documents \(format(documents.p50)) / \(format(documents.p95)) ms, "
                    + "queries \(format(queries.p50)) / \(format(queries.p95)) ms. "
                    + "Non-finite vectors: \(evaluation.nonFiniteVectors).")
        }
        print(lines.joined(separator: "\n"))
        if let directory = environment["BLAU_BENCH_OUTPUT"] {
            let url = URL(filePath: directory).appendingPathComponent("retrieval-\(name).json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evaluation).write(to: url)
        }
    }

    #if canImport(NaturalLanguage)
        /// Mean-pooled `NLContextualEmbedding`, the same pooling as BlauTopics'
        /// `NLContextualTextEmbedder` (which BlauMemory can't import).
        actor ContextualEmbedder: TextEmbedder {
            nonisolated let modelIdentifier: String
            private let embedding: NLContextualEmbedding

            init?() {
                guard let embedding = NLContextualEmbedding(language: .english), embedding.hasAvailableAssets else {
                    return nil
                }
                self.embedding = embedding
                modelIdentifier = "nl-contextual-\(embedding.modelIdentifier)-r\(embedding.revision)"
            }

            func load() throws { try embedding.load() }

            func embed(_ text: String) async throws -> [Float] {
                var sum = [Double](repeating: 0, count: embedding.dimension)
                var tokens = 0
                let result = try embedding.embeddingResult(for: text, language: .english)
                result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                    for index in vector.indices where index < sum.count { sum[index] += vector[index] }
                    tokens += 1
                    return true
                }
                return sum.map { Float($0 / Double(max(tokens, 1))) }
            }
        }

        @Test func nlContextualEmbeddingBaseline() async throws {
            guard let embedder = ContextualEmbedder() else {
                print("NLContextualEmbedding assets aren't on this machine; skipping")
                return
            }
            try await embedder.load()
            let evaluation = try await EmbeddingRetrievalEvaluator(spec: .nlContextualEmbedding)
                .evaluate(PersonalEvalSet.load(), embedder: embedder)
            try Self.report(evaluation, name: "nl-contextual-embedding")
            #expect(evaluation.nonFiniteVectors == 0)
            #expect(evaluation.result.overall.count == 200)
        }
    #endif

    #if canImport(CoreML)
        @Test(.enabled(if: environment["BLAU_EMBEDDING_MODEL"] != nil && environment["BLAU_EMBEDDING_TOKENS"] != nil))
        func coreMLModel() async throws {
            let modelURL = URL(filePath: try #require(Self.environment["BLAU_EMBEDDING_MODEL"]))
            let tokensURL = URL(filePath: try #require(Self.environment["BLAU_EMBEDDING_TOKENS"]))
            let specID = Self.environment["BLAU_EMBEDDING_SPEC"] ?? TextEmbeddingModelSpec.chosen.id
            let spec = try #require(TextEmbeddingModelSpec.candidates.first { $0.id == specID })
            let units: MLComputeUnits =
                switch Self.environment["BLAU_EMBEDDING_COMPUTE_UNITS"] {
                case "cpuOnly": .cpuOnly
                case "all": .all
                case "cpuAndGPU": .cpuAndGPU
                default: .cpuAndNeuralEngine
                }

            // Latency per sequence length, the existing #22 case.
            let latency = await BenchmarkRunner().run(
                TextEmbeddingBenchmark(
                    id: "memory.\(spec.id)", title: spec.displayName,
                    model: { CoreMLTokenEmbeddingModel(url: modelURL, computeUnits: units) }))
            print(BenchmarkReport(device: .current, startedAt: latency.startedAt, results: [latency]).markdownSummary)
            if case .failed(let message) = latency.outcome { Issue.record("Latency case failed: \(message)") }

            // Retrieval quality through the Core ML runtime.
            let model = CoreMLTokenEmbeddingModel(url: modelURL, computeUnits: units)
            try await model.load()
            let embedder = try PretokenizedTextEmbedder(model: model, tableURL: tokensURL)
            let evaluation = try await EmbeddingRetrievalEvaluator(spec: spec, storedDimensions: spec.storedDimensions)
                .evaluate(PersonalEvalSet.load(), embedder: embedder)
            await model.unload()
            try Self.report(
                evaluation,
                name: "\(spec.id)-\(Self.environment["BLAU_EMBEDDING_COMPUTE_UNITS"] ?? "cpuAndNeuralEngine")")
            #expect(evaluation.nonFiniteVectors == 0)
        }
    #endif
}
