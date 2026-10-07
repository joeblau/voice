import BlauCore
import BlauTelemetry
import Testing

@testable import BlauAudio

@Suite("Speech audio from the capture history")
struct CaptureSpeechAudioTests {
    @Test func readsASegmentAndAnOnsetBackSampleAccurately() throws {
        let hub = CaptureHub(signposter: .disabled(.audio))
        hub.append((0..<48_000).map { Float($0) })
        hub.flush()

        let segment = SpeechSegment(
            id: 0, sampleRange: 16_123..<20_000, sampleRate: 16_000, endReason: .silence, detectedAt: 25_000,
            peakProbability: 1, meanProbability: 1)
        let audio = try #require(hub.audio(for: segment))
        #expect(audio.sampleOffset == 16_123)
        #expect(audio.samples == (16_123..<20_000).map { Float($0) })

        let onset = SpeechOnset(
            segmentID: 0, startOffset: 16_123, sampleRate: 16_000, isContinuation: false, detectedAt: 20_000)
        let start = try #require(hub.audio(from: onset, to: 16_123 + 24_000))
        #expect(start.sampleOffset == 16_123)
        #expect(start.sampleCount == 24_000)
        #expect(hub.audio(from: onset, to: 16_123) == nil)
    }

    @Test func segmentsOlderThanTheHistoryAreGone() {
        let hub = CaptureHub(configuration: .init(historyDuration: .seconds(1)), signposter: .disabled(.audio))
        hub.append([Float](repeating: 0.5, count: 64_000))
        hub.flush()
        let old = SpeechSegment(
            id: 0, sampleRange: 0..<16_000, sampleRate: 16_000, endReason: .silence, detectedAt: 20_000,
            peakProbability: 1, meanProbability: 1)
        #expect(hub.audio(for: old) == nil)
    }
}
