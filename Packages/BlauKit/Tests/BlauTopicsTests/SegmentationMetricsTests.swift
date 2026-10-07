import BlauTopics
import Testing

@Suite("Segmentation metrics")
struct SegmentationMetricsTests {
    @Test func defaultWindowIsHalfTheMeanSegmentLength() {
        // 20 units in 4 segments: mean 5, half 2.5, rounded to 3.
        #expect(SegmentationMetrics.defaultWindowSize(reference: [5, 10, 15], count: 20) == 3)
        // One segment of 10: k = 5.
        #expect(SegmentationMetrics.defaultWindowSize(reference: [], count: 10) == 5)
        // Never below 1, and out-of-range boundaries are ignored.
        #expect(SegmentationMetrics.defaultWindowSize(reference: [1, 2, 3, 0, 4, 99], count: 5) == 1)
    }

    @Test func aPerfectSegmentationScoresZero() {
        #expect(SegmentationMetrics.pk(reference: [4, 9], hypothesis: [4, 9], count: 15) == 0)
        #expect(SegmentationMetrics.windowDiff(reference: [4, 9], hypothesis: [4, 9], count: 15) == 0)
        #expect(SegmentationMetrics.pk(reference: [], hypothesis: [], count: 15) == 0)
    }

    /// Worked by hand: 10 units, a boundary at 5, k = 3, 7 windows. Windows
    /// starting at 2, 3 and 4 straddle the boundary.
    @Test func aMissedBoundary() {
        #expect(SegmentationMetrics.pk(reference: [5], hypothesis: [], count: 10) == 3.0 / 7.0)
        #expect(SegmentationMetrics.windowDiff(reference: [5], hypothesis: [], count: 10) == 3.0 / 7.0)
    }

    /// The same boundary found one unit late only disagrees in the windows
    /// starting at 2 and 5: cheaper than missing it.
    @Test func aNearMissCostsLessThanAMiss() {
        let nearMiss = SegmentationMetrics.pk(reference: [5], hypothesis: [6], count: 10)
        #expect(nearMiss == 2.0 / 7.0)
        #expect(nearMiss < SegmentationMetrics.pk(reference: [5], hypothesis: [], count: 10))
        #expect(SegmentationMetrics.windowDiff(reference: [5], hypothesis: [6], count: 10) == 2.0 / 7.0)
    }

    /// Two boundaries in one window look the same as one to Pk; WindowDiff
    /// counts them.
    @Test func windowDiffPenalizesExtraBoundariesPkMisses() {
        let pk = SegmentationMetrics.pk(reference: [5], hypothesis: [5, 6], count: 10, windowSize: 3)
        let windowDiff = SegmentationMetrics.windowDiff(reference: [5], hypothesis: [5, 6], count: 10, windowSize: 3)
        #expect(windowDiff > pk)
    }

    @Test func duplicateAndOutOfRangeBoundariesAreIgnored() {
        let clean = SegmentationMetrics.pk(reference: [5], hypothesis: [7], count: 12)
        #expect(SegmentationMetrics.pk(reference: [5, 5, 0, 12, -1], hypothesis: [7, 7, 40], count: 12) == clean)
    }

    @Test func transcriptsShorterThanTheWindowScoreZero() {
        #expect(SegmentationMetrics.pk(reference: [1], hypothesis: [], count: 2, windowSize: 3) == 0)
        #expect(SegmentationMetrics.windowDiff(reference: [1], hypothesis: [], count: 0) == 0)
    }

    @Test func scoresStayBetweenZeroAndOne() {
        let reference = [4, 8, 12]
        for hypothesis in [[], [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14], [7], [2, 13]] {
            let pk = SegmentationMetrics.pk(reference: reference, hypothesis: hypothesis, count: 16)
            let windowDiff = SegmentationMetrics.windowDiff(reference: reference, hypothesis: hypothesis, count: 16)
            #expect((0...1).contains(pk))
            #expect((0...1).contains(windowDiff))
        }
    }
}
