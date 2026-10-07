/// Verification scores split by ground truth: target trials (the probe is
/// the enrolled speaker) and non-target trials (anyone or anything else).
public struct VoiceIDScores: Hashable, Codable, Sendable {
    public var target: [Float]
    public var nonTarget: [Float]

    public init(target: [Float] = [], nonTarget: [Float] = []) {
        self.target = target
        self.nonTarget = nonTarget
    }

    /// Whether both kinds of trial are present, so error rates are defined.
    public var isComplete: Bool { !target.isEmpty && !nonTarget.isEmpty }

    public mutating func append(contentsOf other: VoiceIDScores) {
        target += other.target
        nonTarget += other.nonTarget
    }
}

/// The error rates at one threshold, where a trial is accepted when its
/// score is at or above the threshold.
public struct VoiceIDOperatingPoint: Hashable, Codable, Sendable {
    public let threshold: Float
    /// Non-target trials accepted / non-target trials.
    public let falseAcceptRate: Double
    /// Target trials rejected / target trials.
    public let falseRejectRate: Double

    public init(threshold: Float, falseAcceptRate: Double, falseRejectRate: Double) {
        self.threshold = threshold
        self.falseAcceptRate = falseAcceptRate
        self.falseRejectRate = falseRejectRate
    }
}

/// The detection error trade-off (DET) of a set of scores: false accept
/// against false reject rate over every threshold, and the summary numbers
/// taken from it (EER, FAR at a fixed FRR, thresholds for target rates).
///
/// A trial is accepted when `score >= threshold`. Rates are empirical, so
/// they move in steps of `1 / count`; check the trial counts before trusting
/// a rate far below `1 / nonTargetCount`.
public struct DETCurve: Sendable {
    /// Target scores, ascending.
    public let target: [Float]
    /// Non-target scores, ascending.
    public let nonTarget: [Float]

    /// One point per distinct threshold that changes a rate, ascending by
    /// threshold (so FAR falls and FRR rises along the array). The first
    /// point accepts every trial; the last accepts none.
    public let points: [VoiceIDOperatingPoint]

    /// - Precondition: `scores` has both target and non-target trials, all
    ///   finite.
    public init(_ scores: VoiceIDScores) {
        precondition(scores.isComplete, "A DET curve needs target and non-target scores")
        precondition(
            scores.target.allSatisfy(\.isFinite) && scores.nonTarget.allSatisfy(\.isFinite),
            "Scores must be finite")
        let target = scores.target.sorted()
        let nonTarget = scores.nonTarget.sorted()
        self.target = target
        self.nonTarget = nonTarget

        var thresholds = Array(Set(target + nonTarget)).sorted()
        // One past the highest score: nothing is accepted.
        thresholds.append(thresholds[thresholds.count - 1].nextUp)
        self.points = thresholds.map { Self.point(at: $0, target: target, nonTarget: nonTarget) }
    }

    /// The error rates at `threshold`.
    public func rates(at threshold: Float) -> VoiceIDOperatingPoint {
        Self.point(at: threshold, target: target, nonTarget: nonTarget)
    }

    /// The equal error rate: where FAR and FRR cross, interpolated linearly
    /// between the two thresholds that straddle the crossing.
    public var equalErrorRate: Double { equalErrorPoint.falseAcceptRate }

    /// The operating point at the EER, with an interpolated threshold.
    public var equalErrorPoint: VoiceIDOperatingPoint {
        // FAR - FRR starts at 1 (accept all) and ends at -1 (accept none).
        guard let crossing = points.firstIndex(where: { $0.falseAcceptRate <= $0.falseRejectRate }) else {
            preconditionFailure("The last point accepts nothing, so FAR <= FRR there")
        }
        let after = points[crossing]
        guard crossing > 0 else { return after }
        let before = points[crossing - 1]
        let gapBefore = before.falseAcceptRate - before.falseRejectRate  // > 0
        let gapAfter = after.falseAcceptRate - after.falseRejectRate  // <= 0
        let fraction = gapBefore / (gapBefore - gapAfter)
        let rate = before.falseAcceptRate + fraction * (after.falseAcceptRate - before.falseAcceptRate)
        let threshold = before.threshold + Float(fraction) * (after.threshold - before.threshold)
        return VoiceIDOperatingPoint(threshold: threshold, falseAcceptRate: rate, falseRejectRate: rate)
    }

    /// The lowest threshold whose FAR is at most `maximumFalseAcceptRate`:
    /// the accept threshold (`T_hi`) for a false accept budget.
    public func threshold(forFalseAcceptRate maximumFalseAcceptRate: Double) -> VoiceIDOperatingPoint {
        // FAR only falls as the threshold rises, and the last point's FAR is 0.
        points.first { $0.falseAcceptRate <= maximumFalseAcceptRate } ?? points[points.count - 1]
    }

    /// The highest threshold whose FRR is at most `maximumFalseRejectRate`:
    /// the reject threshold (`T_lo`) for a false reject budget.
    public func threshold(forFalseRejectRate maximumFalseRejectRate: Double) -> VoiceIDOperatingPoint {
        // FRR only rises with the threshold, and the first point's FRR is 0.
        points.last { $0.falseRejectRate <= maximumFalseRejectRate } ?? points[0]
    }

    /// FAR at the highest threshold that keeps FRR at most
    /// `falseRejectRate`.
    public func falseAcceptRate(atFalseRejectRate falseRejectRate: Double) -> Double {
        threshold(forFalseRejectRate: falseRejectRate).falseAcceptRate
    }

    /// FRR at the lowest threshold that keeps FAR at most `falseAcceptRate`.
    public func falseRejectRate(atFalseAcceptRate falseAcceptRate: Double) -> Double {
        threshold(forFalseAcceptRate: falseAcceptRate).falseRejectRate
    }

    /// At most `maximumCount` points spread evenly along the curve's length
    /// in probit (normal deviate) space, the space DET plots use, always
    /// keeping both ends. For plots and compact reports.
    public func thinnedPoints(maximumCount: Int = 200) -> [VoiceIDOperatingPoint] {
        precondition(maximumCount >= 2)
        guard points.count > maximumCount else { return points }
        let coordinates = points.map { (Probit.deviate($0.falseAcceptRate), Probit.deviate($0.falseRejectRate)) }
        var length = [0.0]
        length.reserveCapacity(points.count)
        for index in 1..<points.count {
            let dx = coordinates[index].0 - coordinates[index - 1].0
            let dy = coordinates[index].1 - coordinates[index - 1].1
            length.append(length[index - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = length[length.count - 1]
        guard total > 0 else { return [points[0], points[points.count - 1]] }
        var kept: [VoiceIDOperatingPoint] = []
        var cursor = 0
        var lastKept = -1
        for slot in 0..<maximumCount {
            let goal = total * Double(slot) / Double(maximumCount - 1)
            while cursor < points.count - 1 && length[cursor] < goal { cursor += 1 }
            if cursor != lastKept {
                kept.append(points[cursor])
                lastKept = cursor
            }
        }
        if lastKept != points.count - 1 { kept.append(points[points.count - 1]) }
        return kept
    }

    private static func point(at threshold: Float, target: [Float], nonTarget: [Float]) -> VoiceIDOperatingPoint {
        let rejectedTargets = lowerBound(of: threshold, in: target)
        let acceptedNonTargets = nonTarget.count - lowerBound(of: threshold, in: nonTarget)
        return VoiceIDOperatingPoint(
            threshold: threshold,
            falseAcceptRate: Double(acceptedNonTargets) / Double(nonTarget.count),
            falseRejectRate: Double(rejectedTargets) / Double(target.count)
        )
    }

    /// The number of elements of ascending `sorted` below `value`.
    static func lowerBound(of value: Float, in sorted: [Float]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
