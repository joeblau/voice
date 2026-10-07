import Testing

@testable import BlauMemory

@Suite("Rank fusion")
struct RankFusionTests {
    @Test func scoresAreWeightedReciprocalRanks() throws {
        let fused = RankFusion(k: 60).fuse([
            .init(["a", "b"], weight: 1),
            .init(["b", "c"], weight: 0.5),
        ])
        let scores = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.score) })
        let expected: [String: Double] = ["a": 1.0 / 61, "b": 1.0 / 62 + 0.5 / 61, "c": 0.5 / 62]
        for (id, score) in expected {
            let actual = try #require(scores[id])
            #expect(abs(actual - score) < 1e-12, "\(id)")
        }
        #expect(fused.map(\.id) == ["b", "a", "c"])
    }

    @Test func agreementBeatsOneFirstPlace() {
        let fused = RankFusion().fuse([.init(["x", "y"]), .init(["z", "y"])])
        #expect(fused.first?.id == "y")
    }

    @Test func aLowerKFavorsTheHeadOfARanking() {
        // "a" leads the dense list; "b" is second there and third in BM25.
        let rankings: [RankFusion.Ranking<String>] = [.init(["a", "b"]), .init(["c", "d", "b"], weight: 0.4)]
        #expect(RankFusion(k: 60).fuse(rankings).first?.id == "b")
        #expect(RankFusion(k: 1).fuse(rankings).first?.id == "a")
    }

    @Test func tiesKeepFirstSeenOrder() {
        let fused = RankFusion().fuse([.init(["p", "q"]), .init(["q", "p"])])
        #expect(fused.map(\.id) == ["p", "q"])
    }

    @Test func repeatsCountOnceAndZeroWeightsOnlyOrder() {
        let fused = RankFusion(k: 0).fuse([.init(["a", "a", "b"]), .init(["c"], weight: 0)])
        #expect(fused.map(\.id) == ["a", "b", "c"])
        #expect(fused[0].score == 1)
        #expect(fused[2].score == 0)
    }

    @Test func emptyRankings() {
        #expect(RankFusion().fuse([RankFusion.Ranking<Int>]()).isEmpty)
        #expect(RankFusion().fuse([RankFusion.Ranking<Int>([])]).isEmpty)
    }

    /// The equal-weight string helper the eval scripts mirror delegates to it.
    @Test func reciprocalRankFusionHelperMatches() {
        let rankings = [["a", "b", "c"], ["c", "b"]]
        #expect(reciprocalRankFusion(rankings) == RankFusion().fuse(rankings.map { .init($0) }).map(\.id))
    }
}
