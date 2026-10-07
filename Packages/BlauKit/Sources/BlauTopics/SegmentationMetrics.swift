/// Standard error metrics for text segmentation, used to evaluate the topic
/// segmenter against transcripts with labelled boundaries.
///
/// A segmentation of `count` units is the set of boundary positions: each is
/// the index of the first unit of a new segment, in `1..<count`. Both
/// metrics slide a window of `k` units across the transcript and count the
/// windows where the hypothesis disagrees with the reference, so 0 is
/// perfect and lower is better. Near misses cost less than with plain
/// precision and recall.
///
/// - Pk (Beeferman, Berger & Lafferty, 1999): whether the two ends of the
///   window fall in the same segment.
/// - WindowDiff (Pevzner & Hearst, 2002): whether the window contains the
///   same number of boundaries. Stricter than Pk about extra or missing
///   boundaries close together.
public enum SegmentationMetrics {
    /// The conventional window: half the mean reference segment length,
    /// rounded, and at least 1.
    public static func defaultWindowSize(reference: [Int], count: Int) -> Int {
        let segments = Set(reference.filter { $0 > 0 && $0 < count }).count + 1
        let mean = Double(count) / Double(segments)
        return max(1, Int((mean / 2).rounded()))
    }

    /// Pk: the probability that two units `k` apart are wrongly classified as
    /// being in the same or in different segments.
    ///
    /// - Parameters:
    ///   - reference: The true boundaries.
    ///   - hypothesis: The boundaries to evaluate.
    ///   - count: Number of units in the transcript.
    ///   - windowSize: `k`; defaults to `defaultWindowSize(reference:count:)`.
    public static func pk(reference: [Int], hypothesis: [Int], count: Int, windowSize: Int? = nil) -> Double {
        let k = windowSize ?? defaultWindowSize(reference: reference, count: count)
        let windows = count - k
        guard windows > 0 else { return 0 }
        let referenceSegments = segmentIndices(boundaries: reference, count: count)
        let hypothesisSegments = segmentIndices(boundaries: hypothesis, count: count)
        var errors = 0
        for start in 0..<windows {
            let referenceSame = referenceSegments[start] == referenceSegments[start + k]
            let hypothesisSame = hypothesisSegments[start] == hypothesisSegments[start + k]
            if referenceSame != hypothesisSame { errors += 1 }
        }
        return Double(errors) / Double(windows)
    }

    /// WindowDiff: the fraction of windows of `k` units in which the
    /// hypothesis has a different number of boundaries from the reference.
    public static func windowDiff(reference: [Int], hypothesis: [Int], count: Int, windowSize: Int? = nil) -> Double {
        let k = windowSize ?? defaultWindowSize(reference: reference, count: count)
        let windows = count - k
        guard windows > 0 else { return 0 }
        let referenceCounts = boundaryPrefixCounts(boundaries: reference, count: count)
        let hypothesisCounts = boundaryPrefixCounts(boundaries: hypothesis, count: count)
        var errors = 0
        for start in 0..<windows {
            // Boundaries b with start < b <= start + k.
            let referenceInWindow = referenceCounts[start + k] - referenceCounts[start]
            let hypothesisInWindow = hypothesisCounts[start + k] - hypothesisCounts[start]
            if referenceInWindow != hypothesisInWindow { errors += 1 }
        }
        return Double(errors) / Double(windows)
    }

    /// The segment number of each unit.
    private static func segmentIndices(boundaries: [Int], count: Int) -> [Int] {
        boundaryPrefixCounts(boundaries: boundaries, count: count)
    }

    /// `result[i]` = number of distinct boundaries `b` with `0 < b <= i`,
    /// which is also unit `i`'s segment number.
    private static func boundaryPrefixCounts(boundaries: [Int], count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var isBoundary = [Bool](repeating: false, count: count)
        for boundary in boundaries where boundary > 0 && boundary < count {
            isBoundary[boundary] = true
        }
        var result = [Int](repeating: 0, count: count)
        var running = 0
        for index in 0..<count {
            if isBoundary[index] { running += 1 }
            result[index] = running
        }
        return result
    }
}
