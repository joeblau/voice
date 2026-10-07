import Foundation
import Testing

@testable import BlauMemory

/// Sweeps `MemorySearch.Configuration` on the memory eval set (retrieval
/// only), the way #64 swept #59's set: docs/memory-eval.md#tuning.
/// Opt-in: `BLAU_MEMORY_EVAL_TUNING=1 swift test --filter MemoryEvalTuningTests`.
@Suite(
    "Memory eval tuning sweep",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_MEMORY_EVAL_TUNING"] == "1")
)
struct MemoryEvalTuningTests {
    @Test func sweepFusionAndExpansion() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        let vectors = try MemoryEvalFixtures.vectors()
        let index = try await MemoryEvaluator(dataset: dataset).buildIndex(embedder: vectors)

        func measure(_ search: MemorySearch.Configuration) async throws -> MemoryEvalRetrievalMetrics {
            var configuration = MemoryEvaluator.Configuration()
            configuration.search = search
            configuration.systems = [.hybrid]
            let evaluator = MemoryEvaluator(dataset: dataset, configuration: configuration)
            var parts: [MemoryEvalRetrievalMetrics] = []
            for question in dataset.questions where question.type != .abstention {
                let run = try await evaluator.search(question, system: .hybrid, index: index, embeddings: vectors)
                parts.append(.init(ranking: run.ranking, evidence: question.evidence, stale: question.stale))
            }
            return MemoryEvalRetrievalMetrics(averaging: parts)
        }

        func line(_ label: String, _ metrics: MemoryEvalRetrievalMetrics) -> String {
            String(
                format: "%@: Recall@5 %.3f, Complete@5 %.3f, MRR@10 %.3f, current first %.3f", label,
                metrics.recallAt5, metrics.completeAt5, metrics.mrrAt10, metrics.currentFirst ?? 0)
        }

        for keywordWeight in [0.2, 0.4, 0.6, 0.8, 1.0, 1.5] {
            for k in [10.0, 20.0, 60.0] {
                var search = MemorySearch.Configuration()
                search.keywordWeight = keywordWeight
                search.fusion = RankFusion(k: k)
                print(line(String(format: "keyword %.2f k %.0f", keywordWeight, k), try await measure(search)))
            }
        }
        for decay in [0.0, 0.25, 0.5, 1.0] {
            var search = MemorySearch.Configuration()
            search.expansionDecay = decay
            print(line(String(format: "expansion decay %.2f", decay), try await measure(search)))
        }
        for timeWeight in [0.0, 0.5, 1.0, 2.0] {
            var search = MemorySearch.Configuration()
            search.timeWeight = timeWeight
            print(line(String(format: "time weight %.2f", timeWeight), try await measure(search)))
        }
    }
}
