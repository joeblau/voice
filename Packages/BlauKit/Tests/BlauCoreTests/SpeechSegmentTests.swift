import BlauCore
import Testing

@Suite("SpeechSegment")
struct SpeechSegmentTests {
    private func segment(_ range: Range<Int64>, detectedAt: Int64 = 0) -> SpeechSegment {
        SpeechSegment(
            id: 3, sampleRange: range, sampleRate: 16_000, endReason: .silence, detectedAt: detectedAt,
            peakProbability: 1, meanProbability: 0.9)
    }

    @Test func timesComeFromAbsoluteSampleOffsets() {
        let segment = segment(16_000..<40_000)
        #expect(segment.sampleCount == 24_000)
        #expect(segment.duration == .milliseconds(1_500))
        #expect(segment.timeRange == TimeRange(start: .seconds(1), end: .milliseconds(2_500)))
    }

    @Test func endDetectionLatencyIsTheDelayAfterTheSpeech() {
        #expect(segment(0..<16_000, detectedAt: 24_000).endDetectionLatency == .milliseconds(500))
        // Never negative.
        #expect(segment(0..<16_000, detectedAt: 8_000).endDetectionLatency == .zero)
    }

    @Test func onsetLatencyAndStart() {
        let onset = SpeechOnset(
            segmentID: 1, startOffset: 32_000, sampleRate: 16_000, isContinuation: false, detectedAt: 40_000)
        #expect(onset.start == .seconds(2))
        #expect(onset.detectionLatency == .milliseconds(500))
    }
}
