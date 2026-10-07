import BlauCore
import Foundation

/// Offline re-segmentation (#55): once a conversation has ended, every
/// exchange embedding is available at once, so the topic boundaries the
/// streaming segmenter chose with two exchanges of look-ahead can be
/// checked against the whole conversation.
///
/// The engine is TreeSeg-style divisive clustering (Gklezakos et al., 2024):
/// a topic's coherence is the squared distance of its exchange embeddings
/// to their mean, and a boundary is worth having where cutting a stretch of
/// the conversation in two removes a lot of that spread. Instead of
/// replacing the streaming segmentation with its own, the engine starts from
/// it and only proposes changes that clearly improve coherence:
///
/// 1. **Merge.** A streaming boundary is removed when the two topics either
///    side of it are not distinct: keeping the cut explains less than
///    `mergeThreshold` exchanges' worth of spread. This is how a digression
///    the hysteresis didn't catch is folded back into its topic.
/// 2. **Move.** A remaining boundary moves up to `moveRadius` exchanges when
///    that explains at least `moveMargin` exchanges' worth more spread.
/// 3. **Split.** Each topic is split top-down, TreeSeg's divisive step, at
///    the cut that explains the most spread, as long as that is at least
///    `splitThreshold` exchanges' worth and both parts are a full topic
///    (`minimumTopicUnits`, `minimumTopicDuration`). This recovers a change
///    of subject the streaming threshold missed. Repeats with `σ²` measured
///    again on the new topics until nothing more is added.
/// 4. **Merge again.** A streaming boundary that the new ones left between
///    two parts of the same topic is removed (new boundaries are kept).
///
/// "Exchanges' worth of spread" is the gain of a cut divided by the
/// conversation's mean within-topic spread per exchange, `σ²`, which makes
/// the thresholds independent of the embedder's similarity scale (an
/// F-statistic; a cut through a single topic gains about 1). The gap
/// between `mergeThreshold` and `splitThreshold` is a hysteresis: between
/// them the streaming decision stands.
///
/// Each original boundary gets at most one change (`removed` or `moved`),
/// and `changes` lists them in an order that can be applied one by one.
///
/// Ranges in `locked` (topics the user named, merged or split, and topics
/// from an earlier session) are left exactly as they are: no boundary is
/// added inside them and their edges never move. `pinned` boundaries (a
/// change of subject the user announced) never move or go away.
///
/// Pure and deterministic, like `TopicSegmenter`: no clock, I/O or
/// concurrency.
public struct TopicResegmenter: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// A new boundary must explain at least this many exchanges' worth
        /// of within-topic spread.
        public var splitThreshold: Double
        /// A streaming boundary that explains less than this many exchanges'
        /// worth of spread is removed. At most `splitThreshold`.
        public var mergeThreshold: Double
        /// How far, in exchanges, a streaming boundary may move.
        public var moveRadius: Int
        /// A move must explain at least this many more exchanges' worth of
        /// spread than the boundary where it was.
        public var moveMargin: Double
        /// Shortest topic, in exchanges. Same meaning as in `TopicConfig`.
        public var minimumTopicUnits: Int
        /// Shortest topic: from the start of its first exchange to the start
        /// of the next topic (or the end of its last exchange).
        public var minimumTopicDuration: Duration

        public init(
            splitThreshold: Double = 2.5,
            mergeThreshold: Double = 1.5,
            moveRadius: Int = 2,
            moveMargin: Double = 0.25,
            minimumTopicUnits: Int = TopicConfig.default.minimumTopicUnits,
            minimumTopicDuration: Duration = TopicConfig.default.minimumTopicDuration
        ) {
            self.splitThreshold = splitThreshold
            self.mergeThreshold = mergeThreshold
            self.moveRadius = moveRadius
            self.moveMargin = moveMargin
            self.minimumTopicUnits = minimumTopicUnits
            self.minimumTopicDuration = minimumTopicDuration
        }

        /// The tuned thresholds (docs/topics.md, "Offline re-segmentation").
        public static let standard = Configuration()

        /// These thresholds with the shortest topic of `topicConfig`, so the
        /// offline pass never makes a topic the streaming segmenter couldn't.
        public func matching(_ topicConfig: TopicConfig) -> Configuration {
            var copy = self
            copy.minimumTopicUnits = topicConfig.minimumTopicUnits
            copy.minimumTopicDuration = topicConfig.minimumTopicDuration
            return copy
        }

        /// Describes the first invalid parameter, or `nil`.
        public var validationError: String? {
            if !(splitThreshold.isFinite && splitThreshold > 0) { return "splitThreshold must be positive" }
            if !(mergeThreshold.isFinite && mergeThreshold >= 0) { return "mergeThreshold must not be negative" }
            if mergeThreshold > splitThreshold { return "mergeThreshold must not exceed splitThreshold" }
            if moveRadius < 0 { return "moveRadius must not be negative" }
            if !(moveMargin.isFinite && moveMargin >= 0) { return "moveMargin must not be negative" }
            if minimumTopicUnits < 1 { return "minimumTopicUnits must be at least 1" }
            if minimumTopicDuration < .zero { return "minimumTopicDuration must not be negative" }
            return nil
        }
    }

    public let configuration: Configuration

    /// - Precondition: `configuration.validationError == nil`.
    public init(configuration: Configuration = .standard) {
        if let problem = configuration.validationError {
            preconditionFailure("Invalid TopicResegmenter.Configuration: \(problem)")
        }
        self.configuration = configuration
    }

    /// Re-segments a finished conversation.
    ///
    /// - Parameters:
    ///   - embeddings: One embedding per exchange, in order, all the same
    ///     length. Normalized here.
    ///   - timeRanges: Each exchange's span on the audio timeline, parallel
    ///     to `embeddings`.
    ///   - boundaries: The current segmentation: the index of each topic's
    ///     first exchange after the first topic, as in `TopicBoundary`.
    ///   - locked: Exchange ranges that must stay exactly one topic each,
    ///   such as topics the user edited. Each must be a whole topic of
    ///   `boundaries`.
    ///   - pinned: Boundaries that must stay where they are, such as one the
    ///     user announced ("let's switch gears").
    /// - Returns: The proposed boundaries and the changes that lead there.
    ///   Unchanged (`changes` empty) when the input is inconsistent.
    public func resegment(
        embeddings: [[Float]],
        timeRanges: [TimeRange],
        boundaries: [Int],
        locked: [Range<Int>] = [],
        pinned: Set<Int> = []
    ) -> TopicResegmentation {
        let count = embeddings.count
        let original = Array(Set(boundaries.filter { $0 > 0 && $0 < count })).sorted()
        let edges = Set([0, count] + original)
        guard count >= 2, timeRanges.count == count, let dimension = embeddings.first?.count, dimension > 0,
            embeddings.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) }),
            // A locked range must be a whole topic of the segmentation.
            locked.allSatisfy({ edges.contains($0.lowerBound) && edges.contains($0.upperBound) })
        else {
            return TopicResegmentation(original: original, boundaries: original, changes: [], spread: 0)
        }

        var run = Run(
            configuration: configuration,
            sums: PrefixSums(embeddings.map(VectorMath.normalized)),
            starts: timeRanges.map(\.start),
            end: timeRanges.map(\.end).max() ?? .zero,
            boundaries: original,
            locked: locked,
            pinned: pinned
        )
        run.mergeIndistinctTopics()
        run.moveBoundaries()
        run.splitTopics()
        // A new boundary can leave a streaming one between two parts of the
        // same topic, measured against the refreshed `σ²`.
        run.mergeIndistinctTopics()
        return TopicResegmentation(
            original: original, boundaries: run.boundaries, changes: run.changes, spread: run.spread)
    }
}

/// What offline re-segmentation proposes.
public struct TopicResegmentation: Hashable, Sendable {
    /// One proposed change, in the order it was decided. Indices are
    /// exchange indices: a boundary at `i` starts a topic with exchange `i`.
    public enum Change: Hashable, Sendable {
        /// The topic starting at this boundary joins the one before it.
        case removed(Int)
        /// The topic starting at `from` starts at `to` instead.
        case moved(from: Int, to: Int)
        /// A new topic starts here.
        case added(Int)
    }

    /// The boundaries before.
    public let original: [Int]
    /// The proposed boundaries, sorted.
    public let boundaries: [Int]
    public let changes: [Change]
    /// `σ²`: the mean within-topic spread per exchange the thresholds were
    /// measured against, for logging.
    public let spread: Double

    public var isUnchanged: Bool { changes.isEmpty }
}

// MARK: - The algorithm

/// One re-segmentation in progress.
private struct Run {
    let configuration: TopicResegmenter.Configuration
    let sums: PrefixSums
    let starts: [Duration]
    let end: Duration
    var boundaries: [Int]
    var changes: [TopicResegmentation.Change] = []
    /// Boundaries that never move or go away: pinned ones and the edges of
    /// locked ranges.
    let fixed: Set<Int>
    /// Exchanges inside a locked range, where no boundary may be added.
    private let lockedUnits: IndexSet
    /// `σ²`: the mean within-topic spread per exchange. Measured on the
    /// starting segmentation, and again after each round of splits.
    private(set) var spread: Double

    var count: Int { sums.count }

    init(
        configuration: TopicResegmenter.Configuration,
        sums: PrefixSums,
        starts: [Duration],
        end: Duration,
        boundaries: [Int],
        locked: [Range<Int>],
        pinned: Set<Int>
    ) {
        self.configuration = configuration
        self.sums = sums
        self.starts = starts
        self.end = end
        self.boundaries = boundaries
        var fixed = pinned
        var lockedUnits = IndexSet()
        for range in locked {
            fixed.insert(range.lowerBound)
            fixed.insert(range.upperBound)
            lockedUnits.insert(integersIn: range)
        }
        self.fixed = fixed
        self.lockedUnits = lockedUnits

        self.spread = Self.pooledSpread(sums, boundaries: boundaries)
    }

    /// The pooled within-topic spread per exchange of a segmentation,
    /// `Σ SSE(topic) / (exchanges − topics)`. A floor keeps a conversation
    /// of identical exchanges from dividing by zero.
    static func pooledSpread(_ sums: PrefixSums, boundaries: [Int]) -> Double {
        let edges = [0] + boundaries + [sums.count]
        var total = 0.0
        for index in 0..<(edges.count - 1) {
            total += sums.spread(edges[index]..<edges[index + 1])
        }
        let degrees = max(1, sums.count - (edges.count - 1))
        return max(total / Double(degrees), 1e-6)
    }

    // MARK: Passes

    /// Removes the weakest free boundary while it explains less than
    /// `mergeThreshold` exchanges' worth of spread. Boundaries this run
    /// added are spared.
    mutating func mergeIndistinctTopics() {
        let added = Set(changes.compactMap { if case .added(let position) = $0 { position } else { nil } })
        while true {
            var weakest: (index: Int, score: Double)?
            for (index, boundary) in boundaries.enumerated()
            where !fixed.contains(boundary) && !added.contains(boundary) {
                let score = cutScore(previous(index), boundary, next(index))
                if score < (weakest?.score ?? .infinity) {
                    weakest = (index, score)
                }
            }
            guard let weakest, weakest.score < configuration.mergeThreshold else { return }
            remove(boundaries[weakest.index])
            boundaries.remove(at: weakest.index)
        }
    }

    /// Records the removal of `boundary`. A boundary this run moved is
    /// removed where it started, so each original boundary gets one change.
    private mutating func remove(_ boundary: Int) {
        let move = changes.firstIndex { change in
            if case .moved(_, let to) = change { to == boundary } else { false }
        }
        if let move, case .moved(let from, _) = changes[move] {
            changes[move] = .removed(from)
        } else {
            changes.append(.removed(boundary))
        }
    }

    /// Moves each free boundary to the best cut within `moveRadius`, when
    /// that is clearly better.
    mutating func moveBoundaries() {
        guard configuration.moveRadius > 0 else { return }
        for index in boundaries.indices where !fixed.contains(boundaries[index]) {
            let boundary = boundaries[index]
            let lower = previous(index)
            let upper = next(index)
            let here = cutScore(lower, boundary, upper)
            var best = (position: boundary, score: here)
            let window = (boundary - configuration.moveRadius)...(boundary + configuration.moveRadius)
            for position in window where position > lower && position < upper && position != boundary {
                guard isTopic(lower..<position), isTopic(position..<upper),
                    !crossesLock(from: boundary, to: position)
                else { continue }
                let score = cutScore(lower, position, upper)
                if score > best.score { best = (position, score) }
            }
            if best.position != boundary, best.score - here >= configuration.moveMargin {
                boundaries[index] = best.position
                changes.append(.moved(from: boundary, to: best.position))
            }
        }
    }

    /// TreeSeg's divisive step: splits each unlocked topic at its best cut
    /// while the cut explains at least `splitThreshold` exchanges' worth of
    /// spread, then tries the two halves the same way.
    ///
    /// A missed change of subject inflates `σ²` (its topics' differences
    /// count as spread), which hides other missed changes. So after a round
    /// that added boundaries, `σ²` is measured again on the new topics and
    /// the step repeats until nothing more is added.
    mutating func splitTopics() {
        var added: [Int] = []
        while true {
            let edges = [0] + boundaries + [count]
            var queue = (0..<(edges.count - 1)).map { edges[$0]..<edges[$0 + 1] }
            var round: [Int] = []
            while let segment = queue.popLast() {
                guard let cut = bestCut(in: segment), cut.score >= configuration.splitThreshold else { continue }
                round.append(cut.position)
                queue.append(segment.lowerBound..<cut.position)
                queue.append(cut.position..<segment.upperBound)
            }
            guard !round.isEmpty else { break }
            added += round
            boundaries = (boundaries + round).sorted()
            spread = min(spread, Self.pooledSpread(sums, boundaries: boundaries))
        }
        for position in added.sorted() {
            changes.append(.added(position))
        }
    }

    // MARK: Scores

    /// The best place to cut `segment` in two full topics, outside locked
    /// ranges.
    private func bestCut(in segment: Range<Int>) -> (position: Int, score: Double)? {
        guard segment.count >= 2 * configuration.minimumTopicUnits else { return nil }
        var best: (position: Int, score: Double)?
        for position in (segment.lowerBound + 1)..<segment.upperBound {
            guard !lockedUnits.contains(position), !lockedUnits.contains(position - 1),
                isTopic(segment.lowerBound..<position), isTopic(position..<segment.upperBound)
            else { continue }
            let score = cutScore(segment.lowerBound, position, segment.upperBound)
            if score > (best?.score ?? -.infinity) { best = (position, score) }
        }
        return best
    }

    /// How much spread cutting `lower..<upper` at `position` explains, in
    /// exchanges' worth: `(SSE(whole) − SSE(left) − SSE(right)) / σ²`.
    private func cutScore(_ lower: Int, _ position: Int, _ upper: Int) -> Double {
        let gain =
            sums.spread(lower..<upper) - sums.spread(lower..<position) - sums.spread(position..<upper)
        return max(0, gain) / spread
    }

    /// Whether `range` is long enough to be a topic of its own.
    private func isTopic(_ range: Range<Int>) -> Bool {
        guard range.count >= configuration.minimumTopicUnits else { return false }
        let finish = range.upperBound < count ? starts[range.upperBound] : end
        return finish - starts[range.lowerBound] >= configuration.minimumTopicDuration
    }

    /// Whether moving a boundary from `old` to `new` would take exchanges
    /// in or out of a locked range.
    private func crossesLock(from old: Int, to new: Int) -> Bool {
        let moved = min(old, new)..<max(old, new)
        return moved.contains { lockedUnits.contains($0) }
    }

    private func previous(_ index: Int) -> Int { index > 0 ? boundaries[index - 1] : 0 }

    private func next(_ index: Int) -> Int { index + 1 < boundaries.count ? boundaries[index + 1] : count }
}

/// Running sums of the embeddings and their squared lengths, so the spread
/// of any range is `O(dimension)`.
private struct PrefixSums {
    let count: Int
    let dimension: Int
    /// `(count + 1) × dimension`: row `i` is the sum of the first `i`
    /// embeddings.
    private let vectors: [Double]
    private let squares: [Double]

    init(_ embeddings: [[Float]]) {
        count = embeddings.count
        dimension = embeddings.first?.count ?? 0
        var vectors = [Double](repeating: 0, count: (count + 1) * dimension)
        var squares = [Double](repeating: 0, count: count + 1)
        for (row, embedding) in embeddings.enumerated() {
            let from = row * dimension
            let to = from + dimension
            var square = 0.0
            for column in 0..<dimension {
                let value = Double(embedding[column])
                vectors[to + column] = vectors[from + column] + value
                square += value * value
            }
            squares[row + 1] = squares[row] + square
        }
        self.vectors = vectors
        self.squares = squares
    }

    /// The sum of squared distances of the embeddings in `range` to their
    /// mean: `Σ|x|² − |Σx|² / n`.
    func spread(_ range: Range<Int>) -> Double {
        guard range.count > 1 else { return 0 }
        let lower = range.lowerBound * dimension
        let upper = range.upperBound * dimension
        var length = 0.0
        for column in 0..<dimension {
            let sum = vectors[upper + column] - vectors[lower + column]
            length += sum * sum
        }
        let total = squares[range.upperBound] - squares[range.lowerBound]
        return max(0, total - length / Double(range.count))
    }
}
