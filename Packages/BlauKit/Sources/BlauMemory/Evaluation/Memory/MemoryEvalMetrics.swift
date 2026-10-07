import Foundation

/// Retrieval quality for memory questions, LongMemEval style, averaged over
/// questions.
///
/// A question needs one or more pieces of evidence, each satisfied by any
/// of its alternatives (`MemoryEvalDataset.Evidence`); a ranking is
/// evidence ids, best first, one per record (several chunks of one
/// document count once).
///
/// - **Recall@k**: the share of a question's evidence pieces in the top k.
/// - **Complete@k**: 1 if every piece is in the top k (LongMemEval's
///   recall_all@k), which multi-hop and temporal-difference questions need.
/// - **Hit@k**: 1 if any piece is in the top k (recall_any@k).
/// - **MRR@10**: 1 / rank of the first evidence, 0 past rank 10.
/// - **nDCG@10**: binary gain for the first record of each piece.
/// - **Current first**: for a knowledge update, 1 if the current evidence
///   is in the top 10 and ranks above every superseded record.
public struct MemoryEvalRetrievalMetrics: Codable, Hashable, Sendable {
    public var count: Int
    public var recallAt5: Double
    public var recallAt10: Double
    public var completeAt5: Double
    public var completeAt10: Double
    public var hitAt1: Double
    public var hitAt5: Double
    public var mrrAt10: Double
    public var ndcgAt10: Double
    /// Questions with superseded records that `currentFirst` averages.
    public var updateCount: Int
    public var currentFirst: Double?

    public init(
        count: Int = 0, recallAt5: Double = 0, recallAt10: Double = 0, completeAt5: Double = 0,
        completeAt10: Double = 0, hitAt1: Double = 0, hitAt5: Double = 0, mrrAt10: Double = 0, ndcgAt10: Double = 0,
        updateCount: Int = 0, currentFirst: Double? = nil
    ) {
        self.count = count
        self.recallAt5 = recallAt5
        self.recallAt10 = recallAt10
        self.completeAt5 = completeAt5
        self.completeAt10 = completeAt10
        self.hitAt1 = hitAt1
        self.hitAt5 = hitAt5
        self.mrrAt10 = mrrAt10
        self.ndcgAt10 = ndcgAt10
        self.updateCount = updateCount
        self.currentFirst = currentFirst
    }

    /// One question's metrics.
    ///
    /// - Parameters:
    ///   - ranking: Evidence ids, best first (only the top 10 count).
    ///   - evidence: The pieces the answer needs; at least one.
    ///   - stale: Superseded records (knowledge updates).
    public init(ranking: [String], evidence: [MemoryEvalDataset.Evidence], stale: [String] = []) {
        precondition(!evidence.isEmpty, "A question needs at least one piece of evidence")
        let top = Array(ranking.prefix(10))
        // The rank (from 0) at which each piece is first satisfied.
        let firstRank = evidence.map { piece in top.firstIndex(where: piece.alternatives.contains) }
        func recall(_ k: Int) -> Double {
            Double(firstRank.filter { $0.map { $0 < k } ?? false }.count) / Double(evidence.count)
        }
        func complete(_ k: Int) -> Double { firstRank.allSatisfy { $0.map { $0 < k } ?? false } ? 1 : 0 }
        let best = firstRank.compactMap { $0 }.min()
        var dcg = 0.0
        for rank in Set(firstRank.compactMap { $0 }) {
            dcg += 1 / log2(Double(rank + 2))
        }
        let ideal = (0..<min(evidence.count, 10)).reduce(0.0) { $0 + 1 / log2(Double($1 + 2)) }
        var currentFirst: Double?
        if !stale.isEmpty {
            let staleRank = top.firstIndex(where: stale.contains) ?? Int.max
            currentFirst = best.map { $0 < staleRank ? 1 : 0 } ?? 0
        }
        self.init(
            count: 1, recallAt5: recall(5), recallAt10: recall(10), completeAt5: complete(5),
            completeAt10: complete(10), hitAt1: best == 0 ? 1 : 0, hitAt5: best.map { $0 < 5 ? 1 : 0 } ?? 0,
            mrrAt10: best.map { 1 / Double($0 + 1) } ?? 0, ndcgAt10: dcg / ideal,
            updateCount: currentFirst == nil ? 0 : 1, currentFirst: currentFirst)
    }

    /// The mean of per-question (or already averaged) metrics, weighted by
    /// `count` (and `updateCount` for `currentFirst`).
    public init(averaging parts: some Sequence<MemoryEvalRetrievalMetrics>) {
        var total = MemoryEvalRetrievalMetrics()
        var currentFirst = 0.0
        for part in parts {
            let weight = Double(part.count)
            total.count += part.count
            total.recallAt5 += part.recallAt5 * weight
            total.recallAt10 += part.recallAt10 * weight
            total.completeAt5 += part.completeAt5 * weight
            total.completeAt10 += part.completeAt10 * weight
            total.hitAt1 += part.hitAt1 * weight
            total.hitAt5 += part.hitAt5 * weight
            total.mrrAt10 += part.mrrAt10 * weight
            total.ndcgAt10 += part.ndcgAt10 * weight
            if let value = part.currentFirst {
                total.updateCount += part.updateCount
                currentFirst += value * Double(part.updateCount)
            }
        }
        guard total.count > 0 else {
            self = total
            return
        }
        let n = Double(total.count)
        self.init(
            count: total.count, recallAt5: total.recallAt5 / n, recallAt10: total.recallAt10 / n,
            completeAt5: total.completeAt5 / n, completeAt10: total.completeAt10 / n, hitAt1: total.hitAt1 / n,
            hitAt5: total.hitAt5 / n, mrrAt10: total.mrrAt10 / n, ndcgAt10: total.ndcgAt10 / n,
            updateCount: total.updateCount,
            currentFirst: total.updateCount > 0 ? currentFirst / Double(total.updateCount) : nil)
    }

    /// The value of a metric by its name in thresholds and tables.
    public func value(of metric: Metric) -> Double? {
        switch metric {
        case .recallAt5: recallAt5
        case .recallAt10: recallAt10
        case .completeAt5: completeAt5
        case .completeAt10: completeAt10
        case .hitAt1: hitAt1
        case .hitAt5: hitAt5
        case .mrrAt10: mrrAt10
        case .ndcgAt10: ndcgAt10
        case .currentFirst: currentFirst
        }
    }

    /// The metrics by name, as thresholds and reports spell them.
    public enum Metric: String, Codable, CaseIterable, Hashable, Sendable, CodingKeyRepresentable {
        case recallAt5 = "Recall@5"
        case recallAt10 = "Recall@10"
        case completeAt5 = "Complete@5"
        case completeAt10 = "Complete@10"
        case hitAt1 = "Hit@1"
        case hitAt5 = "Hit@5"
        case mrrAt10 = "MRR@10"
        case ndcgAt10 = "nDCG@10"
        case currentFirst = "Current first"
    }
}

/// End-to-end answer accuracy: the share of questions whose answer the
/// judge accepted. A question whose reader or judge failed (an error, or a
/// verdict that wasn't yes or no) counts as wrong and is counted in
/// `failures`.
public struct MemoryEvalAnswerMetrics: Codable, Hashable, Sendable {
    public var count: Int
    public var correct: Int
    public var failures: Int

    public init(count: Int = 0, correct: Int = 0, failures: Int = 0) {
        self.count = count
        self.correct = correct
        self.failures = failures
    }

    public var accuracy: Double { count == 0 ? 0 : Double(correct) / Double(count) }

    public init(summing parts: some Sequence<MemoryEvalAnswerMetrics>) {
        self.init()
        for part in parts {
            count += part.count
            correct += part.correct
            failures += part.failures
        }
    }
}
