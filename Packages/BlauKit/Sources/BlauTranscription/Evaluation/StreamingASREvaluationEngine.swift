import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization

/// Evaluates the production streaming path: `VoiceActivitySegmenter` finds
/// the speech and `ParakeetStreamingTranscriber` turns it into partials and
/// finals, with every endpointing rule of docs/asr.md.
///
/// Each fixture is replayed as fast as the models allow, in 20 ms capture
/// frames:
///
/// 1. **VAD.** The fixture runs through the segmenter first. Each event is
///    stamped with the stream position at which VAD decided it
///    (`detectedAt`), as it would be live.
/// 2. **ASR.** The frames go to the transcriber in order; each VAD event is
///    handed over before the first frame that starts at or after its
///    `detectedAt` (live, VAD and ASR read the same capture stream). Every
///    `ingest` call is timed, and the events it emitted are stamped with the
///    stream position and that call's compute.
///
/// RTF counts both passes. VAD's own compute (about 1 ms per 256 ms chunk)
/// is not added to the latency of the events it triggers.
public struct StreamingASREvaluationEngine: ASREvaluationEngine {
    /// Supplies the recognizer for a fixture, normally the same loaded
    /// `ParakeetEouRecognizer` every time (the engine resets it). Tests
    /// build a simulated one from the fixture's labels.
    public typealias RecognizerSource =
        @Sendable (ASREvaluationFixture) async throws -> any StreamingSpeechRecognizer

    public let descriptor: ASREngineDescriptor
    private let recognizer: RecognizerSource
    private let speechModel: any SpeechProbabilityModel
    private let transcriberConfiguration: StreamingTranscriberConfiguration
    private let vadConfiguration: VoiceActivityConfiguration
    private let frameLength: Int

    /// - Parameters:
    ///   - descriptor: How the engine appears in reports.
    ///   - recognizer: The recognizer for a fixture.
    ///   - speechModel: VAD's speech classifier, normally
    ///     `SileroSpeechProbabilityModel`; reset before every fixture.
    ///   - transcriberConfiguration: The transcriber's endpointing.
    ///   - vadConfiguration: The segmenter's thresholds.
    ///   - frameLength: Samples per capture frame (320 = 20 ms, as captured).
    public init(
        descriptor: ASREngineDescriptor,
        recognizer: @escaping RecognizerSource,
        speechModel: any SpeechProbabilityModel,
        transcriberConfiguration: StreamingTranscriberConfiguration = .standard,
        vadConfiguration: VoiceActivityConfiguration = .standard,
        frameLength: Int = 320
    ) {
        precondition(frameLength > 0, "Frames must hold audio")
        self.descriptor = descriptor
        self.recognizer = recognizer
        self.speechModel = speechModel
        self.transcriberConfiguration = transcriberConfiguration
        self.vadConfiguration = vadConfiguration
        self.frameLength = frameLength
    }

    /// Warms both models up on two seconds of a quiet tone; the result is
    /// discarded.
    public func prepare() async throws {
        let samples = (0..<(AudioFrame.captureSampleRate * 2)).map { Float(sin(Double($0) * 0.07)) * 0.05 }
        let warmUp = ASREvaluationFixture(
            id: "warm-up", category: "warm-up", samples: samples,
            utterances: [ASRReferenceUtterance(range: 0..<Int64(samples.count), text: "warm up")])
        _ = try await transcribe(warmUp)
    }

    public func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript {
        let clock = ContinuousClock()
        let frames = Self.frames(of: fixture.samples, length: frameLength)

        // 1. VAD over the whole fixture.
        await speechModel.reset()
        let segmenter = VoiceActivitySegmenter(
            model: speechModel, configuration: vadConfiguration, signposter: .disabled(.asr))
        let vadStream = segmenter.events()
        let vadStarted = clock.now
        for frame in frames {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        let vadTime = clock.now - vadStarted
        var vadEvents: [VoiceActivityEvent] = []
        for await event in vadStream { vadEvents.append(event) }

        // 2. ASR, with VAD's events in stream order.
        let recognizer = try await recognizer(fixture)
        await recognizer.reset()
        let source = ReplayCaptureSource(samples: fixture.samples)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: SilentVoiceActivity(),
            configuration: transcriberConfiguration, signposter: .disabled(.asr))
        let stream = transcriber.events
        let collector = Task {
            var collected: [TranscriptEvent] = []
            for await event in stream { collected.append(event) }
            return collected
        }

        var pending = vadEvents.sorted { $0.decisionPosition < $1.decisionPosition }[...]
        var stamps: [(position: Int64, compute: Duration)] = []
        var asrTime = Duration.zero
        func emittedCount() -> Int {
            let statistics = transcriber.statistics
            return Int(statistics.partialsEmitted + statistics.utterancesCommitted)
        }

        for frame in frames {
            var due: [VoiceActivityEvent] = []
            while let next = pending.first, next.decisionPosition <= frame.sampleOffset {
                due.append(next)
                pending.removeFirst()
            }
            source.advance(to: frame.nextSampleOffset)
            let started = clock.now
            await transcriber.ingest(due, frame: frame)
            let elapsed = clock.now - started
            asrTime += elapsed
            while stamps.count < emittedCount() { stamps.append((frame.nextSampleOffset, elapsed)) }
        }
        let started = clock.now
        await transcriber.audioDidEnd(pending: Array(pending))
        let elapsed = clock.now - started
        asrTime += elapsed
        while stamps.count < emittedCount() { stamps.append((fixture.sampleCount, elapsed)) }
        await transcriber.finish()

        let collected = await collector.value
        func samples(_ range: TimeRange) -> Range<Int64> {
            let rate = AudioFrame.captureSampleRate
            return range.start.sampleCount(sampleRate: rate)..<range.end.sampleCount(sampleRate: rate)
        }
        let events = zip(collected, stamps).map { event, stamp -> ASRTimedEvent in
            switch event {
            case .partial(let text, let range):
                ASRTimedEvent(
                    kind: .partial, text: text, range: samples(range), audioPosition: stamp.position,
                    computeLag: stamp.compute)
            case .final(let utterance):
                ASRTimedEvent(
                    kind: .final, text: utterance.text, range: samples(utterance.timeRange),
                    audioPosition: stamp.position, computeLag: stamp.compute)
            }
        }
        return ASREngineTranscript(events: events, computeTime: vadTime + asrTime)
    }

    static func frames(of samples: [Float], length: Int) -> [AudioFrame] {
        stride(from: 0, to: samples.count, by: length).map { start in
            AudioFrame(
                samples: Array(samples[start..<min(start + length, samples.count)]), sampleOffset: Int64(start))
        }
    }
}

extension StreamingASREvaluationEngine {
    /// Parakeet realtime EOU 120M at 320 ms chunks behind Silero VAD, loaded
    /// from the directories `ModelManager` installed. Id `parakeet-eou-320ms`.
    public static func parakeetRealtimeEOU(
        modelDirectory: URL,
        vadModelDirectory: URL,
        endOfUtteranceDebounce: Duration = ParakeetEouRecognizer.defaultEndOfUtteranceDebounce,
        configuration: StreamingTranscriberConfiguration = .standard,
        revision: String? = nil
    ) async throws -> StreamingASREvaluationEngine {
        let recognizer = try await ParakeetEouRecognizer.load(
            modelDirectory: modelDirectory, endOfUtteranceDebounce: endOfUtteranceDebounce,
            signposter: .disabled(.asr))
        let vad = try await SileroSpeechProbabilityModel(modelDirectory: vadModelDirectory)
        let descriptor = ASREngineDescriptor(
            id: "parakeet-eou-320ms",
            title: "Parakeet realtime EOU 120M, 320 ms chunks + Silero VAD (streaming)",
            kind: .streaming,
            model: revision.map { "\(ModelID.parakeetRealtimeEOU.rawValue)@\($0.prefix(8))" },
            settings: [
                "eouDebounce": "\(Int(endOfUtteranceDebounce.timeInterval * 1_000)) ms",
                "silenceCommitDelay": "\(Int(configuration.silenceCommitDelay.timeInterval * 1_000)) ms",
                "maximumUtterance": "\(Int(configuration.maximumUtteranceDuration.timeInterval)) s",
            ])
        return StreamingASREvaluationEngine(
            descriptor: descriptor, recognizer: { _ in recognizer }, speechModel: vad,
            transcriberConfiguration: configuration)
    }
}

extension VoiceActivityEvent {
    /// The stream position at which VAD decided the event.
    var decisionPosition: Int64 {
        switch self {
        case .speechStarted(let onset): onset.detectedAt
        case .speechEnded(let segment): segment.detectedAt
        }
    }
}

/// A capture stream over a fixture for the replay: `history(in:)` returns
/// the audio received so far (`advance(to:)`), as `CaptureHub` does.
final class ReplayCaptureSource: CaptureFrameSource {
    private let samples: [Float]
    private let position = Mutex<Int64>(0)

    init(samples: [Float]) {
        self.samples = samples
    }

    func advance(to offset: Int64) {
        position.withLock { $0 = min(offset, Int64(samples.count)) }
    }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        // The replay calls `ingest` directly; nothing subscribes.
        AsyncStream { $0.finish() }
    }

    func history(in range: Range<Int64>) -> AudioFrame? {
        let upper = min(range.upperBound, position.withLock { $0 })
        let lower = max(range.lowerBound, 0)
        guard lower < upper else { return nil }
        return AudioFrame(samples: Array(samples[Int(lower)..<Int(upper)]), sampleOffset: lower)
    }
}

/// The transcriber's `voiceActivity` during a replay: events are handed to
/// `ingest` directly instead.
struct SilentVoiceActivity: VoiceActivitySource {
    func events() -> AsyncStream<VoiceActivityEvent> { AsyncStream { $0.finish() } }
    func speechAudio() -> AsyncStream<SpeechAudioEvent> { AsyncStream { $0.finish() } }
    var isSpeechActive: Bool { false }
}
