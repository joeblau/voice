import BlauMemory
import Foundation
import Testing

@Suite("Retrieval metrics")
struct RetrievalMetricsTests {
    @Test func firstRelevantAtRankThree() {
        let m = RetrievalMetrics(ranking: ["x", "y", "a", "z", "b", "c"], relevant: ["a", "b"])
        #expect(m.count == 1)
        #expect(m.recallAt5 == 1)
        #expect(m.recallAt10 == 1)
        #expect(m.hitAt1 == 0)
        #expect(m.hitAt5 == 1)
        #expect(abs(m.mrrAt10 - 1.0 / 3) < 1e-12)
        let dcg = 1 / log2(4.0) + 1 / log2(6.0)
        let ideal = 1 / log2(2.0) + 1 / log2(3.0)
        #expect(abs(m.ndcgAt10 - dcg / ideal) < 1e-12)
    }

    @Test func partialRecallAndMissPastTen() {
        let ranking = (0..<12).map { "d\($0)" }
        let partial = RetrievalMetrics(ranking: ranking, relevant: ["d0", "d7"])
        #expect(partial.recallAt5 == 0.5)
        #expect(partial.recallAt10 == 1)
        #expect(partial.hitAt1 == 1)
        #expect(partial.mrrAt10 == 1)

        let miss = RetrievalMetrics(ranking: ranking, relevant: ["d11"])
        #expect(miss.recallAt10 == 0)
        #expect(miss.mrrAt10 == 0)
        #expect(miss.ndcgAt10 == 0)
    }

    @Test func averagingWeighsByCount() {
        let a = RetrievalMetrics(ranking: ["a"], relevant: ["a"])
        let b = RetrievalMetrics(ranking: ["x"], relevant: ["b"])
        let pair = RetrievalMetrics(averaging: [a, b])
        #expect(pair.count == 2)
        #expect(pair.hitAt1 == 0.5)
        let three = RetrievalMetrics(averaging: [pair, a])
        #expect(three.count == 3)
        #expect(abs(three.mrrAt10 - 2.0 / 3) < 1e-12)
        #expect(RetrievalMetrics(averaging: []).count == 0)
    }

    @Test func resultGroupsByCategoryAndStyleAndListsMisses() throws {
        let set = try RetrievalEvalSet(
            documents: [.init(id: "a", kind: "fact", text: "A"), .init(id: "b", kind: "fact", text: "B")],
            queries: [
                .init(id: "q1", text: "a?", relevant: ["a"], category: "one", style: "keyword"),
                .init(id: "q2", text: "b?", relevant: ["b"], category: "two"),
            ])
        let result = RetrievalEvalResult(evalSet: set, rankings: ["q1": ["a", "b"]])
        #expect(result.overall.hitAt1 == 0.5)
        #expect(result.byCategory["one"]?.hitAt1 == 1)
        #expect(result.byCategory["two"]?.hitAt5 == 0)
        #expect(result.byStyle["keyword"]?.count == 1)
        #expect(result.misses == ["q2"])
    }

    @Test func reciprocalRankFusionRewardsAgreement() {
        let fused = reciprocalRankFusion([["a", "b", "c"], ["b", "c", "a"]])
        #expect(fused == ["b", "a", "c"])
        // Equal scores keep first-seen order.
        #expect(reciprocalRankFusion([["x", "y"], ["y", "x"]]) == ["x", "y"])
    }
}
