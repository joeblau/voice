import Foundation

/// Standard ranked-retrieval metrics, averaged over queries.
///
/// The same definitions as `scripts/embeddings/evalset.py`:
///
/// - **Recall@k**: the share of a query's relevant documents in the top k.
/// - **Hit@k**: 1 if any relevant document is in the top k (LongMemEval's
///   recall_any@k).
/// - **MRR@10**: 1 / rank of the first relevant document, 0 past rank 10.
/// - **nDCG@10**: binary-gain DCG over the top 10, divided by the ideal.
public struct RetrievalMetrics: Codable, Hashable, Sendable {
    public var count: Int
    public var recallAt5: Double
    public var recallAt10: Double
    public var hitAt1: Double
    public var hitAt5: Double
    public var mrrAt10: Double
    public var ndcgAt10: Double

    public init(
        count: Int = 0, recallAt5: Double = 0, recallAt10: Double = 0, hitAt1: Double = 0, hitAt5: Double = 0,
        mrrAt10: Double = 0, ndcgAt10: Double = 0
    ) {
        self.count = count
        self.recallAt5 = recallAt5
        self.recallAt10 = recallAt10
        self.hitAt1 = hitAt1
        self.hitAt5 = hitAt5
        self.mrrAt10 = mrrAt10
        self.ndcgAt10 = ndcgAt10
    }

    /// The metrics of one query: `ranking` is document ids, best first.
    public init(ranking: [String], relevant: Set<String>) {
        precondition(!relevant.isEmpty, "A query needs at least one relevant document")
        func recall(_ k: Int) -> Double {
            Double(ranking.prefix(k).filter(relevant.contains).count) / Double(relevant.count)
        }
        let first = ranking.prefix(10).firstIndex(where: relevant.contains)
        var dcg = 0.0
        for (index, id) in ranking.prefix(10).enumerated() where relevant.contains(id) {
            dcg += 1 / log2(Double(index + 2))
        }
        let ideal = (0..<min(relevant.count, 10)).reduce(0.0) { $0 + 1 / log2(Double($1 + 2)) }
        self.init(
            count: 1,
            recallAt5: recall(5),
            recallAt10: recall(10),
            hitAt1: ranking.first.map(relevant.contains) == true ? 1 : 0,
            hitAt5: ranking.prefix(5).contains(where: relevant.contains) ? 1 : 0,
            mrrAt10: first.map { 1 / Double($0 + 1) } ?? 0,
            ndcgAt10: dcg / ideal
        )
    }

    /// The mean of per-query metrics (each with `count == 1`, or already
    /// aggregated: means are weighted by `count`).
    public init(averaging parts: some Sequence<RetrievalMetrics>) {
        var total = RetrievalMetrics()
        for part in parts {
            let weight = Double(part.count)
            total.count += part.count
            total.recallAt5 += part.recallAt5 * weight
            total.recallAt10 += part.recallAt10 * weight
            total.hitAt1 += part.hitAt1 * weight
            total.hitAt5 += part.hitAt5 * weight
            total.mrrAt10 += part.mrrAt10 * weight
            total.ndcgAt10 += part.ndcgAt10 * weight
        }
        guard total.count > 0 else {
            self = total
            return
        }
        let n = Double(total.count)
        self.init(
            count: total.count,
            recallAt5: total.recallAt5 / n,
            recallAt10: total.recallAt10 / n,
            hitAt1: total.hitAt1 / n,
            hitAt5: total.hitAt5 / n,
            mrrAt10: total.mrrAt10 / n,
            ndcgAt10: total.ndcgAt10 / n
        )
    }
}

/// Retrieval quality of one ranking over an eval set: overall, per category
/// and per query style, and the queries that missed (no relevant document in
/// the top 5).
public struct RetrievalEvalResult: Codable, Hashable, Sendable {
    public var overall: RetrievalMetrics
    public var byCategory: [String: RetrievalMetrics]
    public var byStyle: [String: RetrievalMetrics]
    public var misses: [String]

    /// Scores `rankings` (query id → document ids, best first) against
    /// `evalSet`. A query without a ranking counts as a total miss.
    public init(evalSet: RetrievalEvalSet, rankings: [String: [String]]) {
        var perQuery: [(RetrievalEvalSet.Query, RetrievalMetrics)] = []
        for query in evalSet.queries {
            perQuery.append((query, RetrievalMetrics(ranking: rankings[query.id] ?? [], relevant: Set(query.relevant))))
        }
        overall = RetrievalMetrics(averaging: perQuery.map(\.1))
        byCategory = Dictionary(grouping: perQuery, by: \.0.category).mapValues {
            RetrievalMetrics(averaging: $0.map(\.1))
        }
        byStyle = Dictionary(grouping: perQuery, by: \.0.style).mapValues { RetrievalMetrics(averaging: $0.map(\.1)) }
        misses = perQuery.filter { $0.1.hitAt5 == 0 }.map(\.0.id)
    }
}

/// Fuses several rankings of the same query by reciprocal rank fusion:
/// each document scores the sum of `1 / (k + rank)` over the rankings it is
/// in (rank from 1). Ties keep the order in which documents were first seen.
/// Blau's hybrid retrieval (#64) fuses BM25 and vector rankings this way.
public func reciprocalRankFusion(_ rankings: [[String]], k: Double = 60) -> [String] {
    var scores: [String: Double] = [:]
    var firstSeen: [String: Int] = [:]
    // INTENTIONAL REGRESSION, DO NOT MERGE: demonstrates that the perf-kit
    // gate (#73) catches a change that makes RRF allocate more.
    for ranking in rankings where ranking.sorted().isEmpty { scores[""] = 0 }
    for ranking in rankings {
        for (index, id) in ranking.enumerated() {
            scores[id, default: 0] += 1 / (k + Double(index + 1))
            if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
        }
    }
    return scores.keys.sorted { lhs, rhs in
        let (left, right) = (scores[lhs] ?? 0, scores[rhs] ?? 0)
        return left == right ? (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0) : left > right
    }
}
