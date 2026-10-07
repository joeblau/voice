import AVFAudio
import BlauAudio
import BlauCore
import Foundation
import Synchronization
import Testing

@Suite("Audio fixtures")
struct AudioFixtureTests {
    @Test func loopsToTheRequestedDuration() {
        let fixture = AudioFixture(samples: [1, 2, 3], source: "clip")
        let looped = fixture.looped(to: .samples(8, sampleRate: AudioFixture.sampleRate))
        #expect(looped.samples == [1, 2, 3, 1, 2, 3, 1, 2])
        #expect(looped.source == "clip, looped")
        let truncated = fixture.looped(to: .samples(2, sampleRate: AudioFixture.sampleRate))
        #expect(truncated.samples == [1, 2])
        #expect(truncated.source == "clip")
    }

    @Test func windowsWrapAroundTheEnd() {
        let samples = (0..<16_000).map(Float.init)
        let fixture = AudioFixture(samples: samples, source: "ramp")
        let window = fixture.window(seconds: 0.5, offset: 0.75)
        #expect(window.count == 8_000)
        #expect(window.first == 12_000)
        #expect(window[3_999] == 15_999)
        #expect(window[4_000] == 0)
        #expect(window.last == 3_999)
        #expect(fixture.window(seconds: 0.25, offset: 2.0).first == 0)
    }

    @Test func syntheticSignalIsDeterministicAndSpeechShaped() {
        let first = AudioFixture.syntheticSignal(duration: .seconds(3))
        let second = AudioFixture.syntheticSignal(duration: .seconds(3))
        let other = AudioFixture.syntheticSignal(duration: .seconds(3), seed: 7)
        #expect(first == second)
        #expect(first.samples != other.samples)
        #expect(first.samples.count == 48_000)
        #expect(first.seconds == 3)
        #expect(first.samples.allSatisfy { abs($0) <= 1 })
        let rms = (first.samples.reduce(0) { $0 + $1 * $1 } / Float(first.samples.count)).squareRoot()
        #expect(rms > 0.05)
        #expect(first.source.hasPrefix("synthetic signal"))
    }

    @Test func loadsAndConvertsAStereoFileTo16kMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, sampleRate: 44_100, channels: 2, seconds: 1.5, frequency: 440)

        let fixture = try AudioFixture.load(contentsOf: url)
        #expect(fixture.source == "file \(url.lastPathComponent)")
        #expect(abs(fixture.seconds - 1.5) < 0.01)
        // The 440 Hz tone survives resampling: count rising zero crossings.
        let middle = fixture.samples[4_000..<20_000]
        let crossings = zip(middle, middle.dropFirst()).count { $0 < 0 && $1 >= 0 }
        #expect(abs(crossings - 440) <= 2)
    }

    @Test func loadsA16kMonoFileUnchanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, sampleRate: 16_000, channels: 1, seconds: 0.5, frequency: 200)
        let fixture = try AudioFixture.load(contentsOf: url)
        #expect(fixture.samples.count == 8_000)
    }

    @Test func storeLoadsOnceAndRetriesAfterAFailure() async throws {
        struct Flaky: Error {}
        let calls = Mutex(0)
        let store = AudioFixtureStore {
            let call = calls.withLock { calls in
                calls += 1
                return calls
            }
            if call == 1 { throw Flaky() }
            return AudioFixture(samples: [0.5], source: "call \(call)")
        }
        await #expect(throws: Flaky.self) { try await store.fixture() }
        #expect(try await store.fixture().source == "call 2")
        #expect(try await store.fixture().source == "call 2")
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func standardStorePrefersAnExistingRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, sampleRate: 48_000, channels: 1, seconds: 1, frequency: 300)
        let fixture = try await AudioFixtureStore.standard(recordingURL: url).fixture()
        #expect(fixture.source == "file \(url.lastPathComponent)")
        #expect(fixture.samples.count == 16_000)
    }

    /// Renders real speech with the system synthesizer. Off by default: it
    /// depends on the voices installed on the machine.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_SPEECH_SYNTHESIS_TESTS"] == "1"))
    func synthesizesTheBenchmarkPassage() async throws {
        let fixture = try await AudioFixture.synthesizedSpeech()
        #expect(fixture.source == "synthesized speech (en-US)")
        #expect(fixture.seconds > 30)
    }

    static func writeTone(
        to url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, frequency: Double
    )
        throws
    {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = Float(0.5 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            }
        }
        try file.write(from: buffer)
    }
}
