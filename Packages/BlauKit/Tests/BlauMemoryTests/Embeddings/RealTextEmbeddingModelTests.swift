import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Testing

#if canImport(CoreML)
    import CoreML

    /// The shared text-embedding service on a real converted model (#60):
    /// a hosting folder from `scripts/embeddings/convert_coreml.py`, loaded
    /// exactly as the app loads an installed model. Opt-in, because the
    /// model is hundreds of megabytes and not in the repository:
    ///
    ///     BLAU_TEXT_EMBEDDING_BUNDLE=<hosting folder>[:<another>] \
    ///       swift test -Xswiftc -O --scratch-path .build/optimized --filter RealTextEmbeddingModelTests
    ///
    /// For each bundle it reports the load time, retrieval quality on the
    /// personal eval set through the full Swift path (tokenizer, token table,
    /// Core ML, Matryoshka 256-d, int8), and the latency of a batch of 32
    /// chunks against the budget from #59 (p95 ≤ 50 ms per 128-token chunk
    /// on an iPhone, so ≤ 1.6 s per batch of 32).
    /// `BLAU_EMBEDDING_COMPUTE_UNITS=cpuOnly` runs on the CPU instead of the
    /// Neural Engine.
    @Suite(
        "Real text embedding model (BLAU_TEXT_EMBEDDING_BUNDLE)",
        .enabled(if: ProcessInfo.processInfo.environment["BLAU_TEXT_EMBEDDING_BUNDLE"] != nil),
        .serialized
    )
    struct RealTextEmbeddingModelTests {
        static let environment = ProcessInfo.processInfo.environment

        static var bundles: [URL] {
            (environment["BLAU_TEXT_EMBEDDING_BUNDLE"] ?? "")
                .split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        }

        static var computeUnits: MLComputeUnits {
            environment["BLAU_EMBEDDING_COMPUTE_UNITS"] == "cpuOnly" ? .cpuOnly : .cpuAndNeuralEngine
        }

        @Test(arguments: bundles)
        func embedsTheEvalSetAndABatchOf32WithinBudget(directory: URL) async throws {
            let clock = SystemClock()
            let bundle = try TextEmbeddingBundle(directory: directory)
            let loadStart = clock.uptime
            let model = try await TextEmbeddingModel.load(bundle: bundle, computeUnits: Self.computeUnits)
            let loadTime = clock.uptime - loadStart
            #expect(model.storedDimensions == 256)
            #expect(model.modelVersion.hasPrefix(bundle.spec.vectorIdentifier))

            // Retrieval quality through the whole Swift path.
            let evalSet = try PersonalEvalSet.load()
            let documents = try await model.embed(evalSet.documents.map(\.text), as: .document)
            let queries = try await model.embed(evalSet.queries.map(\.text), as: .query)
            var rankings: [String: [String]] = [:]
            for (query, embedding) in zip(evalSet.queries, queries) {
                rankings[query.id] = EmbeddingRetrievalEvaluator.rank(
                    query: embedding.codes, documents: documents.map(\.codes)
                ).map { evalSet.documents[$0].id }
            }
            let result = RetrievalEvalResult(evalSet: evalSet, rankings: rankings)
            let statistics = await model.statistics
            #expect(statistics.nonFiniteVectors == 0)
            #expect(documents.allSatisfy { $0.modelVersion == model.modelVersion && !$0.isZero })

            // A batch of 32 exchange-sized chunks, as the indexer sends them.
            let chunks = Array(evalSet.documents.map(\.text).sorted { $0.count > $1.count }.prefix(32))
            let tokens = chunks.map { model.tokenCount(of: $0, as: .document) }
            var batches: [Duration] = []
            for iteration in 0..<12 {
                let start = clock.uptime
                let embeddings = try await model.embed(chunks, as: .document)
                let elapsed = clock.uptime - start
                #expect(embeddings.count == 32)
                if iteration >= 2 { batches.append(elapsed) }  // 2 warm-up batches
            }
            let summary = try #require(LatencySummary(batches))
            let budget = 32.0 * 50.0
            func format(_ value: Double) -> String { String(format: "%.1f", value) }
            print(
                """
                ## \(model.modelVersion) (\(Self.computeUnits == .cpuOnly ? "cpuOnly" : "cpuAndNeuralEngine"))

                | Metric | Value |
                | --- | --- |
                | load (tokenizer + Core ML) | \(format(loadTime / .milliseconds(1))) ms |
                | Recall@5 / Hit@5 / MRR@10 | \(String(format: "%.3f / %.3f / %.3f", result.overall.recallAt5, result.overall.hitAt5, result.overall.mrrAt10)) |
                | truncated eval texts | \(statistics.truncatedTexts) of \(statistics.texts) |
                | batch of 32 (\(tokens.min() ?? 0)–\(tokens.max() ?? 0) tokens) p50 / p95 | \(format(summary.p50)) / \(format(summary.p95)) ms (budget \(format(budget)) ms) |
                | per chunk p50 | \(format(summary.p50 / 32)) ms |
                """)
            #expect(summary.p95 <= budget, "a batch of 32 took \(summary.p95) ms at p95, over \(budget) ms")
        }

        /// The on-device benchmark case (`memory.embed.batch32`): 32 chunks
        /// filled to ~90% of the sequence length, the worst case the budget
        /// is defined for.
        @Test(arguments: bundles)
        func fullLengthBatchBenchmark(directory: URL) async throws {
            let result = await BenchmarkRunner().run(
                TextEmbeddingBatchBenchmark.installed(searching: [directory], computeUnits: Self.computeUnits))
            print(BenchmarkReport(device: .current, startedAt: result.startedAt, results: [result]).markdownSummary)
            #expect(result.outcome == .completed, "\(result.outcome)")
            let batch = try #require(result.latencies["embed.batch32"])
            #expect(batch.p95 <= 1_600, "p95 \(batch.p95) ms per batch of 32")
            #expect(result.notes.contains { $0.hasPrefix("Within budget") })
        }
    }
#endif
