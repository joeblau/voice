import Foundation
import Testing

@testable import BlauMemory

@Suite("Memory eval metrics")
struct MemoryEvalMetricsTests {
    typealias Metrics = MemoryEvalRetrievalMetrics
    typealias Evidence = MemoryEvalDataset.Evidence

    @Test func oneHitAtTheTop() {
        let metrics = Metrics(ranking: ["a", "x", "y"], evidence: [Evidence(["a"])])
        #expect(metrics.recallAt5 == 1)
        #expect(metrics.completeAt5 == 1)
        #expect(metrics.hitAt1 == 1)
        #expect(metrics.mrrAt10 == 1)
        #expect(metrics.ndcgAt10 == 1)
        #expect(metrics.currentFirst == nil)
        #expect(metrics.updateCount == 0)
    }

    @Test func anyAlternativeSatisfiesAPiece() {
        let metrics = Metrics(ranking: ["x", "fact-b"], evidence: [Evidence(["turn-b", "fact-b"])])
        #expect(metrics.recallAt5 == 1)
        #expect(metrics.hitAt1 == 0)
        #expect(metrics.mrrAt10 == 0.5)
        #expect(abs(metrics.ndcgAt10 - 1 / log2(3.0)) < 1e-12)
    }

    @Test func multiHopNeedsEveryPiece() {
        // Piece one at rank 2, piece two at rank 7.
        let ranking = ["x", "a", "x2", "x3", "x4", "x5", "b"]
        let metrics = Metrics(ranking: ranking, evidence: [Evidence(["a"]), Evidence(["b"])])
        #expect(metrics.recallAt5 == 0.5)
        #expect(metrics.completeAt5 == 0)
        #expect(metrics.recallAt10 == 1)
        #expect(metrics.completeAt10 == 1)
        #expect(metrics.hitAt5 == 1)
        #expect(metrics.mrrAt10 == 0.5)
        let dcg = 1 / log2(3.0) + 1 / log2(8.0)
        let ideal = 1 + 1 / log2(3.0)
        #expect(abs(metrics.ndcgAt10 - dcg / ideal) < 1e-12)
    }

    @Test func onlyTheTopTenCount() {
        let ranking = (0..<10).map { "x\($0)" } + ["a"]
        let metrics = Metrics(ranking: ranking, evidence: [Evidence(["a"])])
        #expect(metrics.recallAt10 == 0)
        #expect(metrics.mrrAt10 == 0)
        #expect(metrics.ndcgAt10 == 0)
    }

    @Test func currentEvidenceMustOutrankStaleRecords() {
        let evidence = [Evidence(["new"])]
        #expect(Metrics(ranking: ["new", "old"], evidence: evidence, stale: ["old"]).currentFirst == 1)
        #expect(Metrics(ranking: ["old", "new"], evidence: evidence, stale: ["old"]).currentFirst == 0)
        // The stale record missing is fine; the current one missing isn't.
        #expect(Metrics(ranking: ["new"], evidence: evidence, stale: ["old"]).currentFirst == 1)
        #expect(Metrics(ranking: ["old"], evidence: evidence, stale: ["old"]).currentFirst == 0)
        #expect(Metrics(ranking: [], evidence: evidence, stale: ["old"]).updateCount == 1)
    }

    @Test func averagingWeighsByCount() {
        let hit = Metrics(ranking: ["a"], evidence: [Evidence(["a"])], stale: ["s"])
        let miss = Metrics(ranking: ["x"], evidence: [Evidence(["a"])])
        let pair = Metrics(averaging: [hit, miss])
        #expect(pair.count == 2)
        #expect(pair.recallAt5 == 0.5)
        #expect(pair.currentFirst == 1)
        #expect(pair.updateCount == 1)
        let all = Metrics(averaging: [pair, miss])
        #expect(all.count == 3)
        #expect(abs(all.recallAt5 - 1.0 / 3) < 1e-12)
        #expect(Metrics(averaging: []).count == 0)
        #expect(Metrics(averaging: [miss]).currentFirst == nil)
    }

    @Test func metricNamesRoundTrip() throws {
        let metrics = Metrics(ranking: ["a"], evidence: [Evidence(["a"])])
        for metric in Metrics.Metric.allCases where metric != .currentFirst {
            #expect(metrics.value(of: metric) != nil)
        }
        let limits: [Metrics.Metric: Double] = [.recallAt5: 0.8, .currentFirst: 0.5]
        let json = try JSONEncoder().encode(limits)
        let decoded = try JSONDecoder().decode([Metrics.Metric: Double].self, from: json)
        #expect(decoded == limits)
        #expect(String(decoding: json, as: UTF8.self).contains("\"Recall@5\""))
    }

    @Test func answerAccuracy() {
        let total = MemoryEvalAnswerMetrics(
            summing: [
                MemoryEvalAnswerMetrics(count: 1, correct: 1), MemoryEvalAnswerMetrics(count: 1, failures: 1),
                MemoryEvalAnswerMetrics(count: 2, correct: 1),
            ])
        #expect(total.count == 4)
        #expect(total.correct == 2)
        #expect(total.failures == 1)
        #expect(total.accuracy == 0.5)
        #expect(MemoryEvalAnswerMetrics().accuracy == 0)
    }
}
