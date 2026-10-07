import BlauCore

/// The streaming topic segmentation engine: a TextTiling depth score over
/// exchange embeddings, with hysteresis so it doesn't flap.
///
/// Pure and deterministic: it takes units and their embeddings and returns
/// events, with no clock, I/O or concurrency, so the same input always gives
/// the same boundaries. `StreamingTopicSegmenter` wraps it with an embedder
/// and instrumentation.
///
/// ## How it decides
///
/// Gap `g` sits between unit `g − 1` and unit `g`. Once `rightWindow` units
/// after it have arrived, it gets a similarity
///
///     sim(g) = cos(mean(units g−L ..< g), mean(units g ..< g+R))
///
/// and a TextTiling depth `(leftPeak − sim) + (rightPeak − sim)`, where the
/// peaks are found by climbing the similarity curve away from `g` while it
/// keeps rising. Depths that have settled feed a running mean `μ` and
/// standard deviation `σ`.
///
/// 1. **Candidate.** A recent gap whose score (depth, plus a boost when the
///    user said "let's switch gears") exceeds `max(minimumDepth, μ + kσ)`,
///    and which would close a topic of at least `minimumTopicUnits` units and
///    `minimumTopicDuration`, raises `.candidate(at:)`.
/// 2. **Hysteresis.** While the candidate is pending, the units before the
///    dip are compared with the newest units. If that similarity recovers to
///    `dip + recoveryFraction × (leftPeak − dip)` the conversation came back:
///    `.rejected(_, reason: .recovered)`, and the digression's units are left
///    out of later similarity windows so the way back isn't another dip.
/// 3. **Confirmation.** Once `sustainUnits` more units have arrived since
///    the deepest dip was scored without a recovery, the similarity has
///    stopped falling, and `cooldown` has passed since the previous
///    confirmation, the boundary is confirmed at the deepest dip seen while
///    it was pending (`.confirmed`), which may be earlier or later than the
///    candidate.
///
/// See docs/topics.md for the full description and the tuning notes.
public struct TopicSegmenter: Sendable {
    /// Gaps a depth score waits for on its right before it counts towards
    /// `μ` and `σ`, so the right-hand peak has had a chance to form.
    static let settleLag = 2

    /// How close the newest units must be to the old topic, relative to the
    /// units since the dip, to count as a return. See `hasRecovered`.
    static let recoveryAffinity = 0.5

    public let config: TopicConfig
    private let cueDetector: TopicCueDetector

    /// Every unit appended so far, in order.
    public private(set) var units: [TopicUnit] = []
    /// Unit-length embeddings, parallel to `units`.
    private var embeddings: [[Float]] = []
    /// Whether each unit's user text contains an explicit cue.
    private var cues: [Bool] = []
    /// Units inside a rejected digression. Similarity windows computed
    /// after the rejection skip them.
    private var isDigression: [Bool] = []
    /// `similarities[g]` for gap `g`; index 0 is a placeholder (there is no
    /// gap before the first unit).
    private var similarities: [Double] = [.nan]
    private var dimension: Int?

    private var statistics = RunningStatistics()
    /// The last gap whose depth went into `statistics`.
    private var settledThrough = 0

    /// Index of the current topic's first unit.
    public private(set) var currentTopicStart = 0
    /// Gaps before this one are never scored again: they're inside a closed
    /// topic or a rejected digression.
    private var scanFrom = 1
    /// Audio-timeline time (end of the newest unit) of the last confirmation.
    private var lastConfirmation: Duration?
    private var pending: Pending?

    /// Every confirmed boundary, in order.
    public private(set) var boundaries: [TopicBoundary] = []

    private struct Pending: Sendable {
        /// The gap that was raised as the candidate.
        let gap: Int
        let candidate: TopicBoundary
    }

    /// - Precondition: `config.validationError == nil`.
    public init(config: TopicConfig = .default) {
        if let problem = config.validationError {
            preconditionFailure("Invalid TopicConfig: \(problem)")
        }
        self.config = config
        self.cueDetector = TopicCueDetector(phrases: config.cuePhrases)
    }

    // MARK: Streaming

    /// Adds the next finalized unit and its embedding, and returns what the
    /// engine decided.
    ///
    /// Returns at most one event in practice: a new candidate, or the
    /// confirmation or rejection of the pending one.
    ///
    /// - Throws: When the embedding is empty, not finite or a different
    ///   length from earlier ones, or the unit starts before the previous
    ///   one. The engine's state is unchanged when it throws.
    public mutating func append(
        _ unit: TopicUnit,
        embedding: [Float]
    ) throws(TopicSegmenterError) -> [TopicSegmentationEvent] {
        try validate(unit, embedding: embedding)

        dimension = embedding.count
        units.append(unit)
        embeddings.append(VectorMath.normalized(embedding))
        cues.append(cueDetector.containsCue(unit.userText))
        isDigression.append(false)

        guard let gap = latestGap else { return [] }
        precondition(similarities.count == gap, "Gaps must be scored in order")
        similarities.append(similarity(at: gap))
        settleStatistics()

        if pending != nil {
            return resolvePending()
        }
        return scanForCandidate()
    }

    /// Ends the stream. A pending candidate can't be sustained any more, so
    /// it is rejected with `.endOfStream`. More units may be appended later;
    /// they continue the same conversation. The scan position is left where
    /// it was, so a dip that was cut off by `finish()` can be raised again
    /// (and confirmed) once units resume, for example after a session
    /// restart.
    public mutating func finish() -> [TopicSegmentationEvent] {
        guard let pending else { return [] }
        self.pending = nil
        return [.rejected(pending.candidate, reason: .endOfStream)]
    }

    // MARK: Inspection

    /// The candidate waiting to be confirmed or rejected.
    public var pendingCandidate: TopicBoundary? { pending?.candidate }

    /// The running statistics of settled depth scores.
    public var depthStatistics: DepthStatistics {
        DepthStatistics(
            count: statistics.count,
            mean: statistics.mean,
            standardDeviation: statistics.standardDeviation
        )
    }

    /// The current entry threshold, `max(minimumDepth, μ + kσ)`, or `nil`
    /// until `minimumSamples` depths have settled.
    public var threshold: Double? {
        guard statistics.count >= config.minimumSamples else { return nil }
        let adaptive = statistics.mean + config.thresholdSigmas * statistics.standardDeviation
        return max(config.minimumDepth, adaptive)
    }

    /// The scores at gap `gap` (before unit `gap`), or `nil` if it hasn't
    /// been scored yet.
    public func gapScore(at gap: Int) -> GapScore? {
        guard let latestGap, gap >= 1, gap <= latestGap else { return nil }
        let peaks = depth(at: gap)
        return GapScore(
            gap: gap,
            similarity: similarities[gap],
            leftPeak: peaks.leftPeak,
            rightPeak: peaks.rightPeak,
            depth: peaks.depth,
            hasExplicitCue: cues[gap]
        )
    }

    // MARK: Scoring

    /// The newest gap with a full right window, or `nil` before there is one.
    private var latestGap: Int? {
        let gap = units.count - config.rightWindow
        return gap >= 1 ? gap : nil
    }

    /// The sum of the embeddings in `range`, leaving out digression units.
    private func windowSum(_ range: Range<Int>) -> [Float] {
        let clamped = range.clamped(to: 0..<embeddings.count)
        return VectorMath.sum(
            clamped.lazy.filter { !self.isDigression[$0] }.map { self.embeddings[$0] }, dimension: dimension ?? 0)
    }

    /// The sum of the `leftWindow` units before `gap`, skipping digression
    /// units so a rejected digression doesn't pull later similarities down.
    private func leftWindowSum(before gap: Int) -> [Float] {
        var indices: [Int] = []
        var index = gap - 1
        while index >= 0, indices.count < config.leftWindow {
            if !isDigression[index] { indices.append(index) }
            index -= 1
        }
        return VectorMath.sum(indices.lazy.map { self.embeddings[$0] }, dimension: dimension ?? 0)
    }

    private func similarity(at gap: Int) -> Double {
        let left = leftWindowSum(before: gap)
        let right = windowSum(gap..<(gap + config.rightWindow))
        return VectorMath.cosine(left, right)
    }

    /// TextTiling depth at `gap`: climb left and right while the similarity
    /// keeps rising, then add up how far the gap sits below each peak.
    private func depth(at gap: Int) -> (depth: Double, leftPeak: Double, rightPeak: Double) {
        let latest = latestGap ?? gap
        let value = similarities[gap]

        var leftPeak = value
        var index = gap - 1
        var steps = 0
        while index >= 1, steps < config.peakSearchLimit, similarities[index] >= leftPeak {
            leftPeak = similarities[index]
            index -= 1
            steps += 1
        }

        var rightPeak = value
        index = gap + 1
        steps = 0
        while index <= latest, steps < config.peakSearchLimit, similarities[index] >= rightPeak {
            rightPeak = similarities[index]
            index += 1
            steps += 1
        }

        return ((leftPeak - value) + (rightPeak - value), leftPeak, rightPeak)
    }

    private func score(at gap: Int, threshold: Double) -> Double {
        depth(at: gap).depth + (cues[gap] ? config.cueBoost * threshold : 0)
    }

    private mutating func settleStatistics() {
        guard let latestGap else { return }
        while settledThrough + Self.settleLag <= latestGap {
            settledThrough += 1
            statistics.add(depth(at: settledThrough).depth)
        }
    }

    /// Whether a boundary at `gap` would close a long enough topic and lies
    /// in the part of the conversation still open for scoring.
    private func isEligible(_ gap: Int) -> Bool {
        guard gap >= scanFrom, gap >= 1, gap - currentTopicStart >= config.minimumTopicUnits else { return false }
        let length = units[gap].timeRange.start - units[currentTopicStart].timeRange.start
        return length >= config.minimumTopicDuration
    }

    /// The eligible gap in `range` with the highest score (the earliest on a
    /// tie).
    private func deepestGap(in range: ClosedRange<Int>, threshold: Double) -> (gap: Int, score: Double)? {
        var best: (gap: Int, score: Double)?
        for gap in range where isEligible(gap) {
            let value = score(at: gap, threshold: threshold)
            if value > best?.score ?? -.infinity {
                best = (gap, value)
            }
        }
        return best
    }

    private func boundary(at gap: Int, threshold: Double) -> TopicBoundary {
        let peaks = depth(at: gap)
        let unit = units[gap]
        return TopicBoundary(
            unitIndex: gap,
            unitID: unit.id,
            time: unit.timeRange.start,
            startedAt: unit.startedAt,
            closedTopic: currentTopicStart..<gap,
            similarity: similarities[gap],
            depth: peaks.depth,
            score: score(at: gap, threshold: threshold),
            threshold: threshold,
            hasExplicitCue: cues[gap]
        )
    }

    // MARK: Decisions

    /// Steady state: raise a candidate for the deepest recent gap that
    /// clears the threshold.
    private mutating func scanForCandidate() -> [TopicSegmentationEvent] {
        guard let latestGap, let threshold else { return [] }
        // Only recent gaps: a dip that didn't clear the threshold while it
        // was fresh isn't raised later just because the threshold drifted.
        let lookback = config.leftWindow + config.rightWindow
        let lower = max(scanFrom, latestGap - lookback + 1, 1)
        guard lower <= latestGap,
            let best = deepestGap(in: lower...latestGap, threshold: threshold),
            best.score > threshold
        else { return [] }

        let candidate = boundary(at: best.gap, threshold: threshold)
        pending = Pending(gap: best.gap, candidate: candidate)
        return [.candidate(at: candidate)]
    }

    /// A candidate is pending: reject it if the conversation recovered,
    /// confirm it once the deepest dip has been sustained, or keep waiting.
    private mutating func resolvePending() -> [TopicSegmentationEvent] {
        guard let pending, let latestGap, let threshold else { return [] }
        let newest = units.count - 1

        guard let deepest = deepestGap(in: pending.gap...latestGap, threshold: threshold) else {
            return reject(pending, reason: .belowThreshold, scanFrom: latestGap + 1)
        }

        if hasRecovered(from: deepest.gap, newest: newest) {
            // The units from the dip up to the newest window were a
            // digression. Leave them out of later similarity windows, or the
            // way back would look like another dip.
            let newestStart = newest - config.rightWindow + 1
            for index in deepest.gap..<newestStart {
                isDigression[index] = true
            }
            return reject(pending, reason: .recovered, scanFrom: latestGap + 1)
        }

        // Safety valve: a candidate never stays pending indefinitely.
        let overdue = latestGap - pending.gap > config.peakSearchLimit

        // Sustained: `sustainUnits` units have arrived since the deepest dip
        // was first scored (when its right window filled).
        let scoredAt = deepest.gap + config.rightWindow - 1
        guard overdue || newest - scoredAt >= config.sustainUnits else { return [] }

        // While the similarity is still falling at the newest gap, a deeper
        // dip may be forming; its depth isn't known until the curve turns.
        let stillFalling = latestGap > deepest.gap && similarities[latestGap] < similarities[latestGap - 1]
        guard overdue || !stillFalling else { return [] }

        guard deepest.score > threshold else {
            return reject(pending, reason: .belowThreshold, scanFrom: latestGap + 1)
        }

        if !overdue, let lastConfirmation, units[newest].timeRange.end - lastConfirmation < config.cooldown {
            return []
        }

        return confirm(at: deepest.gap, threshold: threshold, newest: newest)
    }

    /// Whether the newest units are back on the topic before the dip at
    /// `gap`. Two conditions, both measured on the newest `rightWindow`
    /// units:
    ///
    /// - Their similarity to the units before the dip has climbed back to
    ///   `dip + recoveryFraction × (leftPeak − dip)`: the exit threshold of the
    ///   hysteresis, well above the dip that raised the candidate.
    /// - They are at least `recoveryAffinity` times as similar to the units
    ///   before the dip as to the units since it. A coherent new topic that
    ///   happens to share a few words with the old one stays much closer to
    ///   its own start, so it isn't mistaken for a return.
    private func hasRecovered(from gap: Int, newest: Int) -> Bool {
        let newestStart = newest - config.rightWindow + 1
        // Until the newest window is entirely past the dip's own right
        // window, this would just re-measure the dip.
        guard newestStart >= gap + config.rightWindow else { return false }
        let before = leftWindowSum(before: gap)
        let since = windowSum(gap..<newestStart)
        let latest = windowSum(newestStart..<(newest + 1))
        let backToBefore = VectorMath.cosine(before, latest)
        let stayedWithNew = VectorMath.cosine(since, latest)

        let peaks = depth(at: gap)
        let dip = similarities[gap]
        let recoveryLevel = dip + config.recoveryFraction * (peaks.leftPeak - dip)
        return backToBefore >= recoveryLevel && backToBefore >= Self.recoveryAffinity * stayedWithNew
    }

    private mutating func reject(
        _ pending: Pending,
        reason: TopicRejectionReason,
        scanFrom newScanFrom: Int
    ) -> [TopicSegmentationEvent] {
        self.pending = nil
        scanFrom = max(scanFrom, newScanFrom)
        return [.rejected(pending.candidate, reason: reason)]
    }

    private mutating func confirm(at gap: Int, threshold: Double, newest: Int) -> [TopicSegmentationEvent] {
        let confirmed = boundary(at: gap, threshold: threshold)
        boundaries.append(confirmed)
        pending = nil
        currentTopicStart = gap
        scanFrom = gap + 1
        lastConfirmation = units[newest].timeRange.end
        return [.confirmed(confirmed)]
    }

    // MARK: Validation

    private func validate(_ unit: TopicUnit, embedding: [Float]) throws(TopicSegmenterError) {
        guard !embedding.isEmpty else { throw .emptyEmbedding }
        if let dimension, embedding.count != dimension {
            throw .dimensionMismatch(expected: dimension, actual: embedding.count)
        }
        guard embedding.allSatisfy(\.isFinite) else { throw .nonFiniteEmbedding }
        if let previous = units.last, unit.timeRange.start < previous.timeRange.start {
            throw .outOfOrder(previousStart: previous.timeRange.start, start: unit.timeRange.start)
        }
    }
}

/// Why `TopicSegmenter.append(_:embedding:)` refused a unit.
public enum TopicSegmenterError: Error, Hashable, Sendable {
    case emptyEmbedding
    case dimensionMismatch(expected: Int, actual: Int)
    case nonFiniteEmbedding
    /// Units must be appended in the order they started.
    case outOfOrder(previousStart: Duration, start: Duration)
}

/// The scores at one gap, for debugging and the performance HUD.
public struct GapScore: Hashable, Sendable {
    /// The gap, which is also the index of the unit after it.
    public let gap: Int
    public let similarity: Double
    public let leftPeak: Double
    public let rightPeak: Double
    public let depth: Double
    public let hasExplicitCue: Bool
}

/// Mean and standard deviation of the settled depth scores.
public struct DepthStatistics: Hashable, Sendable {
    public let count: Int
    public let mean: Double
    public let standardDeviation: Double
}

/// Welford's online mean and (population) variance.
struct RunningStatistics: Hashable, Sendable {
    private(set) var count = 0
    private(set) var mean = 0.0
    private var sumOfSquares = 0.0

    mutating func add(_ value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        sumOfSquares += delta * (value - mean)
    }

    var variance: Double { count > 0 ? max(0, sumOfSquares / Double(count)) : 0 }

    var standardDeviation: Double { variance.squareRoot() }
}
