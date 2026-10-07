import AVFAudio
import BlauCore
import CoreMedia
import Foundation
import Testing

@testable import BlauTranscription

@Suite("AnalyzerAudioConverter")
struct AnalyzerAudioConverterTests {
    private let frame = AudioFrame(samples: [0, 0.5, -0.5, 1, -1, 2, -2], sampleOffset: 320)

    @Test func convertsTo16BitIntegersDirectly() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        #expect(AnalyzerAudioConverter.convertsDirectly(to: format))
        let buffer = try AnalyzerAudioConverter(outputFormat: format).buffer(for: frame)
        #expect(buffer.frameLength == 7)
        let samples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData?[0], count: 7))
        // Clipped to ±1 first.
        #expect(samples == [0, 16_384, -16_384, 32_767, -32_767, 32_767, -32_767])
    }

    @Test func copiesFloatSamples() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try AnalyzerAudioConverter(outputFormat: format).buffer(for: frame)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: 7))
        #expect(samples == frame.samples)
    }

    @Test func resamplesOtherFormatsWithoutSeams() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        #expect(!AnalyzerAudioConverter.convertsDirectly(to: format))
        let converter = try AnalyzerAudioConverter(outputFormat: format)
        var total: AVAudioFrameCount = 0
        for index in 0..<50 {
            let tone = (0..<320).map { Float(sin(Double(index * 320 + $0) * 2 * .pi * 440 / 16_000)) * 0.5 }
            total += try converter.buffer(for: AudioFrame(samples: tone, sampleOffset: Int64(index * 320))).frameLength
        }
        // A second of audio at 48 kHz, give or take the resampler's delay.
        #expect(abs(Int(total) - 48_000) < 200)
    }
}

#if canImport(Speech)
    @Suite("SystemSpeechAnalyzerEngine timeline")
    struct SystemSpeechAnalyzerEngineTimelineTests {
        @Test func streamOffsetsRoundTripThroughAnalyzerTime() {
            for offset: Int64 in [0, 1, 320, 16_000, 57_600_000] {
                #expect(SystemSpeechAnalyzerEngine.offset(SystemSpeechAnalyzerEngine.time(offset)) == offset)
            }
            #expect(SystemSpeechAnalyzerEngine.offset(CMTime(seconds: 1.5, preferredTimescale: 600)) == 24_000)
            #expect(SystemSpeechAnalyzerEngine.offset(.invalid) == 0)
        }

        @Test func rangesConvertToStreamOffsets() {
            let range = CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 1_000),
                duration: CMTime(seconds: 0.5, preferredTimescale: 1_000))
            #expect(SystemSpeechAnalyzerEngine.range(range) == 32_000..<40_000)
            #expect(SystemSpeechAnalyzerEngine.range(.invalid) == 0..<0)
        }

        @Test func appendingBeforeStartingThrows() async {
            let engine = SystemSpeechAnalyzerEngine(locale: Locale(identifier: "en_US"))
            await #expect(throws: AppleSpeechError.notStarted) {
                try await engine.append(AudioFrame(samples: [0], sampleOffset: 0))
            }
            // Nothing to finish or cancel: no-ops.
            await engine.finish()
            await engine.cancel()
            await engine.requestFinalization(through: 0)
        }
    }
#endif
