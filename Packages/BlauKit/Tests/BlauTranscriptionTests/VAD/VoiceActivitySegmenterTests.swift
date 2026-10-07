import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The streaming wrapper around the state machine: chunking, the model
/// seam, power saving, gaps, streams and telemetry.
@Suite("Voice activity segmenter")
struct VoiceActivitySegmenterTests {
    /// `seconds` of 20 ms frames: room tone at `noise` dBFS (or digital
    /// silence), with a -20 dBFS tone in `speech` (seconds).
    static func frames(
        seconds: Double,
        noise: Float? = -55,
        speech: [ClosedRange<Double>] = [],
        muted: [Range<Double>] = [],
        startingAt start: Int64 = 0
    ) -> [AudioFrame] {
        let count = Int((seconds * 16_000).rounded())
        var samples =
            noise.map { roomNoise(count: count, levelDecibels: $0, seed: 11) } ?? [Float](repeating: 0, count: count)
        let amplitude = Float(0.1 * 2.0.squareRoot())
        for range in speech {
            for index in Int(range.lowerBound * 16_000)..<min(Int(range.upperBound * 16_000), count) {
                samples[index] += amplitude * sin(2 * .pi * 220 * Float(index) / 16_000)
            }
        }
        for range in muted {
            for index in Int(range.lowerBound * 16_000)..<min(Int(range.upperBound * 16_000), count) {
                samples[index] = 0
            }
        }
        return stride(from: 0, to: count, by: 320).map {
            AudioFrame(samples: Array(samples[$0..<min($0 + 320, count)]), sampleOffset: start + Int64($0))
        }
    }

    /// Chunk indices (4096 samples) covering `seconds`.
    static func chunks(_ seconds: ClosedRange<Double>) -> Range<Int> {
        Int(seconds.lowerBound * 16_000 / 4_096)..<Int((seconds.upperBound * 16_000 / 4_096).rounded(.up))
    }

    @Test func digitalSilenceNeverRunsTheModel() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        let run = await SegmenterRun.run(Self.frames(seconds: 30, noise: nil), model: model)
        #expect(await model.calls == 0)
        #expect(run.statistics.chunksAnalyzed == 0)
        // 117 full chunks; the last 768 samples are too few to analyse.
        #expect(run.statistics.chunksSkipped == 117)
        #expect(run.statistics.skippedFraction == 1)
        #expect(run.events.isEmpty)
        #expect(run.audio.isEmpty)
    }

    @Test func roomToneRunsTheModelOncePerChunk() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        let run = await SegmenterRun.run(Self.frames(seconds: 30, noise: -50), model: model)
        #expect(await model.calls == 117)
        #expect(run.statistics.chunksAnalyzed == 117)
        #expect(run.statistics.chunksSkipped == 0)
        #expect(run.statistics.samplesProcessed == 117 * 4_096)
    }

    @Test func theModelIsResetAfterSkippedAudio() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        // Room tone with 2 s of digital silence in the middle.
        let run = await SegmenterRun.run(Self.frames(seconds: 6, noise: -50, muted: [2..<4]), model: model)
        #expect(run.statistics.chunksSkipped == 7)
        // Once at the start of the stream, once after the skipped chunks.
        #expect(await model.resets == 2)
    }

    @Test func skippingCanBeTurnedOff() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        var configuration = VoiceActivityConfiguration.standard
        configuration.modelSkipLevelDecibels = nil
        _ = await SegmenterRun.run(Self.frames(seconds: 4, noise: nil), model: model, configuration: configuration)
        #expect(await model.calls == 16)
    }

    @Test func findsSpeechInScriptedAudio() async throws {
        // A tone from 1 s to 3 s; the model agrees with the energy.
        let model = ScriptedSpeechProbabilityModel(speechChunks: [Self.chunks(1...3)])
        let run = await SegmenterRun.run(Self.frames(seconds: 5, speech: [1...3]), model: model)
        let segment = try #require(run.segments.first)
        #expect(run.segments.count == 1)
        #expect(abs(segment.sampleRange.lowerBound - 16_000) <= 1_600)
        #expect(abs(segment.sampleRange.upperBound - 48_000) <= 1_600)
        #expect(run.onsets.first?.segmentID == segment.id)
        #expect(run.statistics.segments == 1)
        #expect(run.statistics.speechSamples == segment.sampleCount)
    }

    @Test func isSpeechActiveFollowsTheSegments() async {
        let model = ScriptedSpeechProbabilityModel(speechChunks: [Self.chunks(1...3)])
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        var states: [Bool] = []
        for frame in Self.frames(seconds: 5, speech: [1...3]) {
            await segmenter.process(frame)
            if states.last != segmenter.isSpeechActive {
                states.append(segmenter.isSpeechActive)
            }
        }
        await segmenter.finish()
        #expect(states == [false, true, false])
    }

    @Test func modelFailuresCountAsSilence() async {
        // The model throws on chunks 5...7, in the middle of the speech.
        let model = ScriptedSpeechProbabilityModel(failing: [5, 6, 7]) { index in
            Self.chunks(1...4).contains(index) ? 0.95 : 0.02
        }
        let run = await SegmenterRun.run(Self.frames(seconds: 6, speech: [1...4]), model: model)
        #expect(run.statistics.modelFailures == 3)
        // The speech's energy carries the segment across the failed chunks.
        #expect(run.segments.count == 1)
        // A failure resets the model before the next call.
        #expect(await model.resets >= 2)
    }

    @Test func shortInputGapsAreFilledWithSilence() async throws {
        let model = ScriptedSpeechProbabilityModel(speechChunks: [Self.chunks(2...3)])
        var frames = Self.frames(seconds: 4, speech: [2...3])
        // Capture lost 200 ms (frames 25..<35) before the speech.
        frames.removeSubrange(25..<35)
        let run = await SegmenterRun.run(frames, model: model)
        #expect(run.statistics.gaps == 1)
        let segment = try #require(run.segments.first)
        // Offsets stay aligned with the capture stream.
        #expect(abs(segment.sampleRange.lowerBound - 32_000) <= 1_600)
        #expect(run.statistics.samplesProcessed == 4 * 16_000)
    }

    @Test func aLongInputGapEndsTheSegmentAndRestarts() async throws {
        let model = ScriptedSpeechProbabilityModel { _ in 0.95 }
        var frames = Self.frames(seconds: 2, speech: [0...2])
        // Five seconds lost, then more speech.
        frames += Self.frames(seconds: 2, speech: [0...2], startingAt: 7 * 16_000)
        let run = await SegmenterRun.run(frames, model: model)
        #expect(run.statistics.gaps == 1)
        #expect(run.segments.count == 2)
        #expect(run.segments.first?.endReason == .streamEnded)
        #expect(run.segments.first.map { $0.sampleRange.upperBound <= 2 * 16_000 } == true)
        #expect(run.segments.last.map { $0.sampleRange.lowerBound >= 7 * 16_000 } == true)
    }

    /// Regression (PR #107 review): a frame that arrives while the model is
    /// running, after a gap of more than 1 s, restarts the stream under the
    /// suspended analysis. The chunk in flight belongs to the old stream and
    /// is dropped, instead of reaching the state machine out of order
    /// ("Chunks must be contiguous").
    @Test func aLongGapArrivingWhileTheModelRunsDropsTheChunkInFlight() async {
        let model = GatedSpeechProbabilityModel(gatedCall: 0)
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let events = segmenter.events()

        let tone = Self.frames(seconds: 1, speech: [0...1])
        let first = Task {
            await segmenter.process(AudioFrame(samples: Array(tone.flatMap(\.samples).prefix(4_096)), sampleOffset: 0))
        }
        await model.waitForGatedCall()
        // Re-entrant, 76 ms of audio 5 s after the first frame.
        await segmenter.process(AudioFrame(samples: [Float](repeating: 0.1, count: 320), sampleOffset: 80_000))
        await model.open()
        await first.value
        await segmenter.finish()

        var collected: [VoiceActivityEvent] = []
        for await event in events { collected.append(event) }
        let segments = collected.compactMap { if case .speechEnded(let segment) = $0 { segment } else { nil } }
        #expect(segments.count <= 1)
        #expect(segments.allSatisfy { $0.endReason == .streamEnded })
        #expect(segmenter.statistics.gaps == 1)
        // The stale chunk ran through the model but was not analysed.
        #expect(segmenter.statistics.samplesProcessed == 0)
    }

    /// The same race with a confirmed segment open and a full chunk after
    /// the gap: the first segment ends at the gap, the chunk in flight is
    /// dropped, and the running drain goes on with the audio after the gap.
    @Test func aLongGapWhileTheModelRunsEndsTheSegmentAndAnalysesWhatFollows() async throws {
        let model = GatedSpeechProbabilityModel(gatedCall: 2)
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let events = segmenter.events()

        let speech = Self.frames(seconds: 1, speech: [0...1]).flatMap(\.samples)
        // Two chunks are analysed and confirm the speech; the model hangs on
        // the third.
        let first = Task {
            await segmenter.process(AudioFrame(samples: Array(speech.prefix(3 * 4_096)), sampleOffset: 0))
        }
        await model.waitForGatedCall()
        #expect(segmenter.isSpeechActive)
        let resumeAt: Int64 = 10 * 16_000
        await segmenter.process(AudioFrame(samples: Array(speech.prefix(4_096)), sampleOffset: resumeAt))
        // The restart closed the open segment.
        #expect(!segmenter.isSpeechActive)
        await model.open()
        await first.value
        await segmenter.finish()

        var segments: [SpeechSegment] = []
        for await event in events {
            if case .speechEnded(let segment) = event { segments.append(segment) }
        }
        #expect(segments.count == 2)
        let before = try #require(segments.first)
        let after = try #require(segments.last)
        #expect(before.endReason == .streamEnded)
        #expect(before.sampleRange.upperBound <= 3 * 4_096)
        #expect(after.endReason == .streamEnded)
        #expect(after.sampleRange.lowerBound >= resumeAt)
        // Two chunks before the gap and the one after it; not the stale one.
        #expect(segmenter.statistics.samplesProcessed == 3 * 4_096)
        #expect(await model.calls == 4)
    }

    @Test func overlappingFramesAreIgnored() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let frames = Self.frames(seconds: 2)
        for frame in frames {
            await segmenter.process(frame)
            // A replayed copy of the same frame adds nothing.
            await segmenter.process(frame)
        }
        await segmenter.finish()
        #expect(segmenter.statistics.samplesProcessed == 2 * 16_000)
    }

    @Test func framesAtTheWrongRateAreDropped() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.95 }
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        await segmenter.process(
            AudioFrame(samples: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000, sampleOffset: 0))
        await segmenter.finish()
        #expect(segmenter.statistics.samplesProcessed == 0)
        #expect(await model.calls == 0)
    }

    @Test func finishEndsTheStreamsAndLaterAudioIsIgnored() async {
        let model = ScriptedSpeechProbabilityModel { _ in 0.95 }
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let events = segmenter.events()
        for frame in Self.frames(seconds: 1, speech: [0...1]) {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        await segmenter.finish()
        await segmenter.process(Self.frames(seconds: 1, speech: [0...1], startingAt: 16_000)[0])

        var collected: [VoiceActivityEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.count == 2)
        if case .speechEnded(let segment) = collected.last {
            #expect(segment.endReason == .streamEnded)
        } else {
            Issue.record("Expected the open segment to end with the stream")
        }
        // Subscribing after the end finishes at once.
        var late = 0
        for await _ in segmenter.events() { late += 1 }
        #expect(late == 0)
    }

    @Test func runConsumesACaptureSourceUntilItEnds() async throws {
        let source = FrameListSource(Self.frames(seconds: 5, speech: [1...3]))
        let model = ScriptedSpeechProbabilityModel(speechChunks: [Self.chunks(1...3)])
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let events = segmenter.events()
        await segmenter.run(on: source)
        var segments: [SpeechSegment] = []
        for await event in events {
            if case .speechEnded(let segment) = event { segments.append(segment) }
        }
        #expect(segments.count == 1)
    }

    @Test func everyModelCallIsAVADChunkInterval() async {
        let backend = RecordingSignpostBackend()
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        let segmenter = VoiceActivitySegmenter(
            model: model, signposter: Signposter(category: .asr, backend: backend))
        for frame in Self.frames(seconds: 3, noise: -50) {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        let calls = await model.calls
        #expect(calls == 12)
        #expect(backend.completedIntervals == Array(repeating: "vad.chunk", count: calls))
        #expect(backend.openIntervals.isEmpty)
    }

    @Test func modelTimeIsMeasuredWithTheInjectedClock() async {
        let clock = ManualClock()
        let model = AdvancingModel(clock: clock, perCall: .milliseconds(2))
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr), clock: clock)
        for frame in Self.frames(seconds: 4.096, noise: -50) {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        #expect(segmenter.statistics.chunksAnalyzed == 16)
        #expect(segmenter.statistics.modelTime == .milliseconds(32))
        #expect(abs(segmenter.statistics.modelLoad - 0.032 / 4.096) < 1e-6)
    }

    /// The segmenter's own work (chunking, levels, the state machine,
    /// streams) on a minute of room tone, with a model that costs nothing:
    /// far below the 3% silence budget, so the budget is the model's.
    @Test func ownOverheadInSilenceIsFarBelowThreePercent() async {
        let frames = Self.frames(seconds: 60, noise: -50)
        let model = ScriptedSpeechProbabilityModel { _ in 0.01 }
        let segmenter = VoiceActivitySegmenter(model: model, signposter: .disabled(.asr))
        let started = ContinuousClock.now
        for frame in frames {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        let elapsed = ContinuousClock.now - started
        // Wall time bounds CPU time from above, even on a busy test host.
        #expect(elapsed < .milliseconds(1_800), "60 s of audio took \(elapsed)")
    }
}

/// A `CaptureFrameSource` over a fixed list of frames.
struct FrameListSource: CaptureFrameSource {
    let frames: [AudioFrame]

    init(_ frames: [AudioFrame]) { self.frames = frames }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func history(in range: Range<Int64>) -> AudioFrame? { nil }
}

/// A speech model (0.95 for every chunk) whose call number `gatedCall`
/// (from 0) suspends until `open()`, so a test can act while the segmenter
/// awaits the model, deterministically.
actor GatedSpeechProbabilityModel: SpeechProbabilityModel {
    nonisolated let chunkLength = 4_096
    private let gatedCall: Int
    private(set) var calls = 0
    private var isOpen = false
    private var gate: CheckedContinuation<Void, Never>?
    private var reachedGate = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(gatedCall: Int) {
        self.gatedCall = gatedCall
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) async throws -> Float {
        let call = calls
        calls += 1
        if call == gatedCall, !isOpen {
            reachedGate = true
            for waiter in gateWaiters { waiter.resume() }
            gateWaiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        return 0.95
    }

    /// Returns once the gated call is suspended in the model.
    func waitForGatedCall() async {
        guard !reachedGate else { return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }

    func reset() {}
}

/// A model that advances a manual clock by a fixed time per call.
actor AdvancingModel: SpeechProbabilityModel {
    nonisolated let chunkLength = 4_096
    let clock: ManualClock
    let perCall: Duration

    init(clock: ManualClock, perCall: Duration) {
        self.clock = clock
        self.perCall = perCall
    }

    func speechProbability(of samples: [Float], at sampleOffset: Int64) -> Float {
        clock.advance(by: perCall)
        return 0.01
    }

    func reset() {}
}
