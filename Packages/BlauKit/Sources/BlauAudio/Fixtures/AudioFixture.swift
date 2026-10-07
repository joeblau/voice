@preconcurrency import AVFAudio
import BlauCore
import Foundation
import Synchronization

/// A clip of 16 kHz mono audio used to drive benchmarks and evaluations.
///
/// Three sources, from most to least realistic:
///
/// - `load(contentsOf:)`: a recording on disk, in any format AVFoundation
///   reads, downmixed and resampled to 16 kHz.
/// - `synthesizedSpeech(_:language:)`: text rendered to speech on device
///   with `AVSpeechSynthesizer`, so benchmarks get real speech without
///   shipping a recording.
/// - `syntheticSignal(duration:seed:)`: a deterministic, speech-shaped
///   signal (voiced harmonics with a syllable-rate envelope). Hermetic, but
///   an ASR model decodes few tokens from it, so decoder cost is
///   underestimated.
///
/// `source` says which one produced the clip; benchmark results record it.
public struct AudioFixture: Hashable, Sendable {
    public static let sampleRate = AudioFrame.captureSampleRate

    /// Mono samples at `sampleRate`, nominally in `-1...1`.
    public let samples: [Float]
    /// Where the audio came from, for example `file benchmark.wav` or
    /// `synthesized speech (en-US)`.
    public let source: String

    public init(samples: [Float], source: String) {
        self.samples = samples
        self.source = source
    }

    public var duration: Duration { .samples(Int64(samples.count), sampleRate: Self.sampleRate) }

    public var seconds: Double { Double(samples.count) / Double(Self.sampleRate) }

    /// The clip repeated (and truncated) to exactly `duration`.
    ///
    /// - Precondition: the clip is not empty.
    public func looped(to duration: Duration) -> AudioFixture {
        precondition(!samples.isEmpty, "Can't loop an empty fixture")
        let count = Int(duration.sampleCount(sampleRate: Self.sampleRate))
        var looped: [Float] = []
        looped.reserveCapacity(count)
        while looped.count < count {
            looped.append(contentsOf: samples.prefix(count - looped.count))
        }
        let label = count > samples.count ? "\(source), looped" : source
        return AudioFixture(samples: looped, source: label)
    }

    /// `seconds` of audio starting `offset` seconds in, wrapping around the
    /// end of the clip.
    ///
    /// - Precondition: the clip is not empty and both values are
    ///   non-negative.
    public func window(seconds: Double, offset: Double = 0) -> [Float] {
        precondition(!samples.isEmpty, "Can't take a window of an empty fixture")
        precondition(seconds >= 0 && offset >= 0, "Window bounds must not be negative")
        let count = Int((seconds * Double(Self.sampleRate)).rounded())
        let start = Int((offset * Double(Self.sampleRate)).rounded()) % samples.count
        var window: [Float] = []
        window.reserveCapacity(count)
        var index = start
        while window.count < count {
            let end = min(samples.count, index + count - window.count)
            window.append(contentsOf: samples[index..<end])
            index = end == samples.count ? 0 : end
        }
        return window
    }

    // MARK: - File

    /// Reads an audio file and converts it to 16 kHz mono.
    public static func load(contentsOf url: URL) throws -> AudioFixture {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            return AudioFixture(samples: [], source: "file \(url.lastPathComponent)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioFixtureError.unsupportedFormat(format.description)
        }
        try file.read(into: buffer)
        let samples = try AudioFixtureConverter.monoSamples(from: buffer, sampleRate: Self.sampleRate)
        return AudioFixture(samples: samples, source: "file \(url.lastPathComponent)")
    }

    // MARK: - Synthesized speech

    /// Renders `text` to speech with the system synthesizer, at 16 kHz mono.
    ///
    /// Uses whatever voice the system has for `language` (no download is
    /// triggered). Throws `AudioFixtureError.synthesisTimedOut` if the
    /// synthesizer doesn't finish within `timeout`.
    ///
    /// The synthesizer emits an empty buffer at each paragraph break, not
    /// only at the end, so completion comes from the delegate's
    /// `didFinish`.
    public static func synthesizedSpeech(
        _ text: String = benchmarkPassage,
        language: String = "en-US",
        timeout: Duration = .seconds(120)
    ) async throws -> AudioFixture {
        let collector = SpeechCollector()
        let samples = try await withThrowingTaskGroup(of: [Float].self) { group in
            group.addTask {
                let synthesizer = AVSpeechSynthesizer()
                let delegate = SpeechCompletionDelegate(collector: collector)
                synthesizer.delegate = delegate
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: language)
                let samples = try await withCheckedThrowingContinuation { continuation in
                    collector.start(continuation)
                    synthesizer.write(utterance) { buffer in
                        collector.receive(buffer)
                    }
                }
                // The synthesizer holds its delegate weakly; keep both alive
                // until every buffer has been delivered.
                withExtendedLifetime((synthesizer, delegate)) {}
                return samples
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                collector.fail(AudioFixtureError.synthesisTimedOut)
                throw AudioFixtureError.synthesisTimedOut
            }
            defer { group.cancelAll() }
            guard let samples = try await group.next() else { throw AudioFixtureError.synthesisTimedOut }
            return samples
        }
        guard !samples.isEmpty else { throw AudioFixtureError.noSpeechProduced }
        return AudioFixture(samples: samples, source: "synthesized speech (\(language))")
    }

    /// About 70 seconds of conversational English when spoken: varied
    /// vocabulary, numbers and questions, the kind of thing Blau hears.
    public static let benchmarkPassage = """
        Okay, so here is where I am with the launch. We moved the beta to the twenty first of October, \
        mostly because the onboarding flow still takes too long. Last week about forty percent of new \
        people dropped off before they finished recording their voice sample. I think the fix is to cut \
        it down to three short prompts instead of five, and to explain why we need it. Can you remind me \
        what we decided about the pricing page? I remember we talked about a monthly plan at nine dollars \
        and an annual plan, but I don't remember if we agreed on a free trial. Also, I need to prepare \
        for the interview on Thursday. They will probably ask how we are different from the big \
        assistants, and the honest answer is that we remember the whole conversation and we only listen \
        to you. Let me think about that for a second. Actually, one more thing. My sister is visiting \
        next weekend, so I want to block Saturday morning and maybe find a good place for brunch near \
        the park. What would you suggest?
        """

    // MARK: - Synthetic signal

    /// A deterministic speech-shaped signal: a voiced source at 110 to
    /// 220 Hz with five harmonics, an envelope at a syllable rate of about
    /// 4 Hz, short pauses, and a little noise. Identical for the same `seed`.
    public static func syntheticSignal(duration: Duration, seed: UInt64 = 0x5EED) -> AudioFixture {
        let count = Int(duration.sampleCount(sampleRate: sampleRate))
        var generator = SplitMix64(seed: seed)
        var samples = [Float](repeating: 0, count: count)
        let rate = Double(sampleRate)

        var phase = 0.0
        var index = 0
        while index < count {
            // One "syllable": 150-350 ms of voicing, sometimes followed by a pause.
            let syllableLength = Int(rate * (0.15 + 0.2 * generator.nextUnit()))
            let pauseLength = generator.nextUnit() < 0.2 ? Int(rate * (0.1 + 0.4 * generator.nextUnit())) : 0
            let pitch = 110 + 110 * generator.nextUnit()
            let end = min(count, index + syllableLength)
            for sampleIndex in index..<end {
                let progress = Double(sampleIndex - index) / Double(max(1, syllableLength))
                let envelope = sin(Double.pi * progress)
                phase += 2 * Double.pi * pitch / rate
                var value = 0.0
                for harmonic in 1...5 {
                    value += sin(phase * Double(harmonic)) / Double(harmonic)
                }
                let noise = (generator.nextUnit() - 0.5) * 0.05
                samples[sampleIndex] = Float(0.25 * envelope * value + noise)
            }
            index = min(count, end + pauseLength)
        }
        return AudioFixture(samples: samples, source: "synthetic signal (seed \(seed))")
    }
}

public enum AudioFixtureError: Error, Hashable, Sendable, CustomStringConvertible {
    case unsupportedFormat(String)
    case conversionFailed(String)
    case synthesisTimedOut
    case noSpeechProduced

    public var description: String {
        switch self {
        case .unsupportedFormat(let format): "Unsupported audio format: \(format)"
        case .conversionFailed(let reason): "Audio conversion failed: \(reason)"
        case .synthesisTimedOut: "Speech synthesis timed out"
        case .noSpeechProduced: "Speech synthesis produced no audio"
        }
    }
}

// MARK: - Conversion

/// Downmixes and resamples PCM buffers to mono float at a target rate.
enum AudioFixtureConverter {
    /// The buffer's audio as mono float samples at `sampleRate`.
    static func monoSamples(from buffer: AVAudioPCMBuffer, sampleRate: Int) throws -> [Float] {
        let mono = try downmix(buffer)
        guard Int(mono.format.sampleRate) != sampleRate else {
            return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
        }
        return try resample(mono, to: sampleRate)
    }

    /// A mono float32 copy of `buffer` at its own sample rate (channels
    /// averaged).
    static func downmix(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let source = try floatBuffer(buffer)
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate, channels: 1,
                interleaved: false),
            let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
            let input = source.floatChannelData, let output = mono.floatChannelData
        else {
            throw AudioFixtureError.unsupportedFormat(buffer.format.description)
        }
        mono.frameLength = AVAudioFrameCount(frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += input[channel][frame]
            }
            output[0][frame] = sum * scale
        }
        return mono
    }

    /// `buffer` as deinterleaved float32, converting integer formats.
    static func floatBuffer(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved {
            return buffer
        }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                channels: buffer.format.channelCount, interleaved: false),
            let converter = AVAudioConverter(from: buffer.format, to: format),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, 1))
        else {
            throw AudioFixtureError.unsupportedFormat(buffer.format.description)
        }
        try converter.convert(to: output, from: buffer)
        return output
    }

    /// Resamples a mono float32 buffer to `sampleRate`.
    static func resample(_ mono: AVAudioPCMBuffer, to sampleRate: Int) throws -> [Float] {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: mono.format, to: format)
        else {
            throw AudioFixtureError.unsupportedFormat(mono.format.description)
        }
        let ratio = Double(sampleRate) / mono.format.sampleRate
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioFixtureError.unsupportedFormat(format.description)
        }

        let feed = SingleBufferFeed(mono)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        if status == .error {
            throw AudioFixtureError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// Hands one buffer to `AVAudioConverter`'s input block, then reports the
/// end of the stream. The converter calls the block synchronously on the
/// converting thread, so the flag needs no lock.
private final class SingleBufferFeed {
    private let buffer: AVAudioPCMBuffer
    private var delivered = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if delivered {
            status.pointee = .endOfStream
            return nil
        }
        delivered = true
        status.pointee = .haveData
        return buffer
    }
}

// MARK: - Speech collection

/// Finishes the collector when the synthesizer finishes (or is cancelled).
private final class SpeechCompletionDelegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let collector: SpeechCollector

    init(collector: SpeechCollector) {
        self.collector = collector
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        collector.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        collector.fail(AudioFixtureError.noSpeechProduced)
    }
}

/// Gathers `AVSpeechSynthesizer.write` buffers and resumes the waiting task
/// once: when the synthesizer finishes, fails or times out.
private final class SpeechCollector: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[Float], any Error>?
        var finished = false
        var samples: [Float] = []
        var sourceRate: Double?
        var error: (any Error)?
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<[Float], any Error>) {
        let earlyError: (any Error)? = state.withLock { state in
            if state.finished { return state.error ?? AudioFixtureError.synthesisTimedOut }
            state.continuation = continuation
            return nil
        }
        if let earlyError {
            continuation.resume(throwing: earlyError)
        }
    }

    func receive(_ buffer: AVAudioBuffer) {
        // Empty buffers mark paragraph breaks, not the end.
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
        do {
            let mono = try AudioFixtureConverter.downmix(pcm)
            let samples = Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
            state.withLock { state in
                guard !state.finished else { return }
                state.sourceRate = state.sourceRate ?? mono.format.sampleRate
                state.samples.append(contentsOf: samples)
            }
        } catch {
            fail(error)
        }
    }

    func fail(_ error: any Error) {
        let continuation: CheckedContinuation<[Float], any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            state.error = error
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: error)
    }

    func finish() {
        let (continuation, samples, rate): (CheckedContinuation<[Float], any Error>?, [Float], Double?) =
            state.withLock { state in
                guard !state.finished else { return (nil, [], nil) }
                state.finished = true
                defer { state.continuation = nil }
                return (state.continuation, state.samples, state.sourceRate)
            }
        guard let continuation else { return }
        do {
            continuation.resume(returning: try Self.resampled(samples, from: rate))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private static func resampled(_ samples: [Float], from rate: Double?) throws -> [Float] {
        guard let rate, !samples.isEmpty else { return [] }
        guard Int(rate) != AudioFixture.sampleRate else { return samples }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw AudioFixtureError.conversionFailed("could not allocate a \(rate) Hz buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return try AudioFixtureConverter.resample(buffer, to: AudioFixture.sampleRate)
    }
}

// MARK: - Random numbers

/// SplitMix64: a tiny, fast, seedable generator, so synthetic fixtures are
/// identical on every run and platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `0..<1`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
