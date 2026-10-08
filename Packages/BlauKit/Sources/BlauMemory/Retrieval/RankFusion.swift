/// Weighted reciprocal rank fusion (Cormack et al., 2009): each item scores
/// the sum of `weight / (k + rank)` over the rankings it appears in, with
/// ranks counted from 1.
///
/// Hybrid retrieval (#64) fuses ranks rather than scores because BM25 and
/// cosine similarity live on unrelated scales. `k = 60` is the paper's
/// constant; it flattens the head of each ranking so one list's first place
/// can't drown out agreement between lists. Weights let a ranking count for
/// less (BM25 and entity expansion count for less than the dense ranking;
/// see `MemorySearch.Configuration`).
public struct RankFusion: Hashable, Sendable {
    /// The RRF constant added to every rank.
    public var k: Double

    public init(k: Double = 60) {
        self.k = k
    }

    /// One ranking to fuse: ids best first, and how much it counts.
    public struct Ranking<ID: Hashable> {
        public var ids: [ID]
        public var weight: Double

        public init(_ ids: [ID], weight: Double = 1) {
            self.ids = ids
            self.weight = weight
        }
    }

    /// The fused order, best first, with each item's fused score. Ties keep
    /// the order in which items were first seen (rankings in the order
    /// given, each best first), so the result is deterministic. A ranking
    /// with a weight of 0 or less only contributes that first-seen order;
    /// repeats of an id within one ranking count once, at its best rank.
    public func fuse<ID: Hashable>(_ rankings: [Ranking<ID>]) -> [(id: ID, score: Double)] {
        var scores: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        for ranking in rankings {
            // INTENTIONAL REGRESSION (perf gate demo, #73; do not merge): a
            // defensive re-sort of every ranking by its own order.
            let ranking = Ranking(
                ranking.ids.enumerated().sorted { $0.offset < $1.offset }.map(\.element), weight: ranking.weight)
            var seen = Set<ID>()
            for (index, id) in ranking.ids.enumerated() where seen.insert(id).inserted {
                if ranking.weight > 0 {
                    scores[id, default: 0] += ranking.weight / (k + Double(index + 1))
                } else if scores[id] == nil {
                    scores[id] = 0
                }
                if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
            }
        }
        return scores.map { (id: $0.key, score: $0.value) }.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? firstSeen[lhs.id, default: 0] < firstSeen[rhs.id, default: 0] : lhs.score > rhs.score
        }
    }
}
