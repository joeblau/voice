import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

// MARK: - Fixture scripts

/// What is said in each VAD fixture (`scripts/make-vad-fixtures.py`), one
/// entry per labelled segment, and where a sentence ends (where a semantic
/// end-of-utterance detector should fire).
struct FixtureScript: Sendable {
    struct Line: Sendable {
        let text: String
        /// Whether the speaker finished a thought here.
        let endsUtterance: Bool
        /// `false` for speech the real model can't transcribe at all.
        var isRecognizable = true
    }

    /// The lines spoken in each labelled segment, in order.
    let segments: [[Line]]

    static let all: [String: FixtureScript] = [
        "conversation-quiet": FixtureScript(segments: [
            [Line(text: "Can you remind me what we decided about the launch date", endsUtterance: true)],
            [Line(text: "Yes", endsUtterance: true)],
            [Line(text: "I think we moved it to the second week of March", endsUtterance: true)],
            [Line(text: "Okay great", endsUtterance: true)],
            // macOS's "Fred" is a 1980s formant synthesizer: Parakeet decodes
            // no words from it at all, fed alone or in a stream (checked
            // with the raw FluidAudio manager). VAD still finds it, and the
            // transcriber drops the blank utterance.
            [Line(text: "Then let us book the venue tomorrow morning", endsUtterance: true, isRecognizable: false)],
        ]),
        "conversation-noisy": FixtureScript(segments: [
            [Line(text: "What is the weather going to be like this weekend", endsUtterance: true)],
            [Line(text: "Probably rain on Saturday", endsUtterance: true)],
            [Line(text: "Should we move the hike to Sunday then", endsUtterance: true)],
            [Line(text: "Sunday works for me", endsUtterance: true)],
        ]),
        "monologue-long": FixtureScript(segments: [
            [
                Line(
                    text: "So the first thing I want to cover is the hiring plan for next quarter", endsUtterance: false
                ),
                Line(text: "we need two more engineers on the audio team and one designer", endsUtterance: false),
                Line(text: "and I would like the offers out before the end of the month", endsUtterance: false),
                Line(
                    text: "because the candidates we interviewed are talking to other companies", endsUtterance: true),
            ]
        ]),
        "pauses": FixtureScript(segments: [
            [
                Line(text: "Let me think", endsUtterance: false),
                Line(text: "about that for a moment", endsUtterance: true),
            ],
            [Line(text: "Take your time", endsUtterance: true)],
        ]),
    ]

    /// The words of the script spread evenly over each labelled segment:
    /// a stand-in alignment for the simulated recognizer.
    func words(over labels: [Range<Int64>], offset: Int64 = 0) -> [ScriptedWord] {
        precondition(labels.count == segments.count, "One label per segment")
        var words: [ScriptedWord] = []
        for (label, lines) in zip(labels, segments) {
            let tokens = lines.flatMap { line in
                let split = line.text.split(separator: " ").map(String.init)
                return split.enumerated().map { ($1, line.endsUtterance && $0 == split.count - 1) }
            }
            let length = label.upperBound - label.lowerBound
            for (index, token) in tokens.enumerated() {
                let end = label.lowerBound + length * Int64(index + 1) / Int64(tokens.count)
                words.append(ScriptedWord(text: token.0, end: offset + end, endsUtterance: token.1))
            }
        }
        return words
    }

    /// The expected utterances' text, one per sentence (what the real model
    /// can recognize).
    var sentences: [String] { sentences(includingUnrecognizable: false) }

    func sentences(includingUnrecognizable: Bool) -> [String] {
        var sentences: [String] = []
        var current: [String] = []
        for line in segments.joined() where line.isRecognizable || includingUnrecognizable {
            current.append(line.text)
            if line.endsUtterance {
                sentences.append(current.joined(separator: " "))
                current = []
            }
        }
        return sentences
    }
}

/// One word for `SimulatedEouRecognizer`: decoded once the audio up to its
/// end has been decoded.
struct ScriptedWord: Hashable, Sendable {
    let text: String
    /// Absolute stream offset where the word ends.
    let end: Int64
    /// Whether the model's EOU head fires on the silence after it.
    let endsUtterance: Bool
}

// MARK: - Simulated recognizer

/// A recognizer with Parakeet realtime EOU's timing and FluidAudio's
/// end-of-utterance rule, transcribing from a word alignment instead of a
/// model, so the transcriber's logic is tested hermetically.
///
/// - Chunks run exactly as in `StreamingEouAsrManager`: once the buffer
///   holds `windowSamples`, then every `shiftSamples`.
/// - A chunk decodes the words that end in its output span (the first
///   `shiftSamples` of its window).
/// - The EOU head fires on a chunk with no new words whose whole output
///   span lies after a word that ends an utterance; the end is confirmed
///   with FluidAudio's debounce (`evaluateEouDebounce`): once `debounce`
///   of decoded audio has passed since that first signal with no new words.
/// - Like FluidAudio, it keeps every word since the last reset and
///   "re-decodes" all of them for each partial; `maximumHistory` records the
///   longest history, to prove the transcriber resets it.
actor SimulatedEouRecognizer: StreamingSpeechRecognizer {
    nonisolated let chunkSize: ASRChunkSize
    private let words: [ScriptedWord]
    /// The alignment repeats every `period` samples (looped fixtures).
    private let period: Int64?
    private let debounceSamples: Int64
    private let chunkTime: Duration
    private let failingChunks: Set<Int>

    private var streamStart: Int64?
    private var buffered = 0
    private var decoded: Int64 = 0
    private var history: [ScriptedWord] = []
    /// Where the current utterance starts after `startNextUtterance()`: the
    /// words decoded before it (kept in `history`, as FluidAudio keeps its
    /// tokens until a reset) and the audio decoded before it.
    private var origin: (words: Int, samples: Int64) = (0, 0)
    private var eouAnchor: Int64?
    private var eouConfirmed = false
    /// Whether `startNextUtterance()` is supported, as `ParakeetEouRecognizer`
    /// does; without it the transcriber resets the recognizer instead.
    private let continuesUtterances: Bool

    private(set) var chunksRun = 0
    private(set) var resets = 0
    private(set) var finishes = 0
    /// `startNextUtterance()` calls that carried the model on.
    private(set) var utterancesContinued = 0
    /// `unload()` calls: `ParakeetStreamingTranscriber.finish()` releases
    /// the model of a recognizer it owns (`unloadsRecognizerOnFinish`).
    private(set) var unloads = 0
    /// Calls to `append`, `finish` or `reset` after `unload()`, which a
    /// real recognizer can't serve.
    private(set) var callsAfterUnload = 0
    private(set) var maximumHistory = 0
    /// Words "re-decoded" for partials in total (the cost FluidAudio pays).
    private(set) var wordsRedecoded = 0
    /// The audio consumed, coalesced across utterances: what was
    /// transcribed, to check nothing is skipped or transcribed twice.
    private(set) var transcribed: [Range<Int64>] = []
    /// Appends that didn't continue where the previous one (since the last
    /// reset) stopped.
    private(set) var discontinuities = 0
    private var expectedNext: Int64?

    init(
        words: [ScriptedWord],
        chunkSize: ASRChunkSize = .ms320,
        debounce: Duration = .milliseconds(640),
        period: Int64? = nil,
        chunkTime: Duration = .milliseconds(12),
        failingChunks: Set<Int> = [],
        continuesUtterances: Bool = true
    ) {
        self.words = words.sorted { $0.end < $1.end }
        self.chunkSize = chunkSize
        self.debounceSamples = debounce.sampleCount(sampleRate: AudioFrame.captureSampleRate)
        self.period = period
        self.chunkTime = chunkTime
        self.failingChunks = failingChunks
        self.continuesUtterances = continuesUtterances
    }

    func append(_ frame: AudioFrame) throws -> RecognizerOutput {
        if unloads > 0 { callsAfterUnload += 1 }
        if let expectedNext, expectedNext != frame.sampleOffset {
            discontinuities += 1
        }
        if streamStart == nil { streamStart = frame.sampleOffset }

        var output = RecognizerOutput()
        var index = 0
        while index < frame.sampleCount {
            let take = min(chunkSize.windowSamples - buffered, frame.sampleCount - index)
            index += take
            guard buffered + take >= chunkSize.windowSamples else {
                buffered += take
                continue
            }
            if failingChunks.contains(chunksRun) {
                chunksRun += 1
                throw SimulatedFailure.chunkFailed
            }
            let outputStart = streamStart! + decoded
            let newWords = decodeWords(upTo: outputStart + Int64(chunkSize.shiftSamples))
            buffered = chunkSize.windowSamples - chunkSize.shiftSamples
            decoded += Int64(chunkSize.shiftSamples)
            chunksRun += 1
            output.chunks += 1
            output.modelTime += chunkTime
            if !newWords.isEmpty {
                output.hasNewText = true
                wordsRedecoded += history.count
            }
            let signal = newWords.isEmpty && (history.last.map { $0.endsUtterance && $0.end <= outputStart } ?? false)
            if evaluateDebounce(hasNewTokens: !newWords.isEmpty, signal: signal) {
                output.isEndOfUtterance = true
                break
            }
        }
        output.consumedSamples = index
        output.transcript = transcript
        output.decodedSamples = decoded - origin.samples
        output.lastTokenEnd = lastTokenEnd
        let consumed = frame.sampleOffset..<(frame.sampleOffset + Int64(index))
        expectedNext = consumed.upperBound
        if !consumed.isEmpty {
            if let last = transcribed.last, last.upperBound == consumed.lowerBound {
                transcribed[transcribed.count - 1] = last.lowerBound..<consumed.upperBound
            } else {
                transcribed.append(consumed)
            }
        }
        return output
    }

    /// `ParakeetEouRecognizer.finish(keepingTokensThrough:)`: pads the
    /// buffer with silence one chunk at a time until the buffered audio the
    /// transcript needs (all of it, or up to `cutoff`) is decoded, then keeps
    /// the words that end by the cutoff. Each padded chunk decodes only its
    /// output span (`shiftSamples`), as in FluidAudio.
    func finish(keepingTokensThrough cutoff: Int64?) -> RecognizerOutput {
        if unloads > 0 { callsAfterUnload += 1 }
        finishes += 1
        var output = RecognizerOutput()
        let before = transcript
        if let streamStart {
            let undecoded = Int64(buffered)
            let needed = cutoff.map { min(max($0 + origin.samples - decoded, 0), undecoded) } ?? undecoded
            let shift = Int64(chunkSize.shiftSamples)
            let chunks = Int((needed + shift - 1) / shift)
            // Only real audio holds words; the padding is silence.
            let fedEnd = streamStart + decoded + undecoded
            for _ in 0..<chunks {
                _ = decodeWords(upTo: min(streamStart + decoded + shift, fedEnd))
                decoded += shift
                chunksRun += 1
            }
            decoded = min(decoded, fedEnd - streamStart)
            output.chunks = chunks
            output.modelTime = chunkTime * chunks
        }
        if let cutoff, let streamStart {
            history.removeAll { $0.end - streamStart - origin.samples > cutoff }
        }
        output.hasNewText = transcript != before
        output.transcript = transcript
        output.decodedSamples = decoded - origin.samples
        output.lastTokenEnd = lastTokenEnd
        buffered = 0
        history.removeAll()
        origin.words = 0
        return output
    }

    func reset() {
        if unloads > 0 { callsAfterUnload += 1 }
        resets += 1
        streamStart = nil
        buffered = 0
        decoded = 0
        history.removeAll()
        origin = (0, 0)
        eouAnchor = nil
        eouConfirmed = false
        expectedNext = nil
    }

    /// `ParakeetEouRecognizer.startNextUtterance()`: the chunk timing, the
    /// buffered audio, the EOU state and the word history carry on; the
    /// outputs describe only what is decoded from here.
    func startNextUtterance() -> Bool {
        guard continuesUtterances else { return false }
        if unloads > 0 { callsAfterUnload += 1 }
        utterancesContinued += 1
        origin = (history.count, decoded)
        return true
    }

    func unload() {
        unloads += 1
    }

    /// The current utterance's words.
    private var transcript: String {
        history.dropFirst(origin.words).map(\.text).joined(separator: " ")
    }

    /// Where the current utterance's last word ends, from its start.
    private var lastTokenEnd: Int64? {
        guard history.count > origin.words, let last = history.last else { return nil }
        return last.end - (streamStart ?? 0) - origin.samples
    }

    /// Moves every word ending at or before `end` (and after what was
    /// already decoded) into the history.
    private func decodeWords(upTo end: Int64) -> [ScriptedWord] {
        guard let streamStart else { return [] }
        let lastEnd = history.last?.end ?? (streamStart - 1)
        let found = words(in: max(lastEnd + 1, streamStart)..<(end + 1))
        history.append(contentsOf: found)
        maximumHistory = max(maximumHistory, history.count)
        return found
    }

    /// Words whose end falls in `range` (absolute), unrolling the period.
    private func words(in range: Range<Int64>) -> [ScriptedWord] {
        guard !range.isEmpty else { return [] }
        guard let period else {
            return words.filter { range.contains($0.end) }
        }
        var found: [ScriptedWord] = []
        var base = (range.lowerBound / period) * period
        while base < range.upperBound {
            for word in words {
                let end = base + word.end
                if range.contains(end) {
                    found.append(ScriptedWord(text: word.text, end: end, endsUtterance: word.endsUtterance))
                }
            }
            base += period
        }
        return found.sorted { $0.end < $1.end }
    }

    /// FluidAudio 0.17.5's `evaluateEouDebounce`, in samples.
    private func evaluateDebounce(hasNewTokens: Bool, signal: Bool) -> Bool {
        if hasNewTokens {
            eouAnchor = nil
            return false
        }
        if eouAnchor == nil, signal {
            eouAnchor = decoded
        }
        guard let anchor = eouAnchor, !eouConfirmed else { return false }
        if decoded - anchor >= debounceSamples {
            eouConfirmed = true
            return true
        }
        return false
    }

    enum SimulatedFailure: Error {
        case chunkFailed
    }
}

// MARK: - Audio and VAD sources

/// A capture stream made of `block` repeated `repeats` times, with a 30 s
/// history up to the replay position. Nothing is stored beyond the block,
/// so an hour costs no more memory than a minute.
final class FixtureAudioSource: CaptureFrameSource {
    let block: [Float]
    let totalSamples: Int64
    private let historyLength: Int64
    private let state = Mutex(State())

    private struct State {
        var position: Int64 = 0
        var subscribers: [AsyncStream<AudioFrame>.Continuation] = []
    }

    init(block: [Float], repeats: Int = 1, historyDuration: Duration = .seconds(30)) {
        self.block = block
        self.totalSamples = Int64(block.count) * Int64(repeats)
        self.historyLength = historyDuration.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    var position: Int64 {
        get { state.withLock { $0.position } }
        set { state.withLock { $0.position = newValue } }
    }

    /// The audio in `range`, generated from the block.
    func samples(in range: Range<Int64>) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(range.count)
        var offset = range.lowerBound
        let count = Int64(block.count)
        while offset < range.upperBound {
            let index = Int(offset % count)
            let run = min(Int64(block.count - index), range.upperBound - offset)
            samples.append(contentsOf: block[index..<(index + Int(run))])
            offset += run
        }
        return samples
    }

    func frame(at offset: Int64, length: Int) -> AudioFrame {
        let end = min(offset + Int64(length), totalSamples)
        return AudioFrame(samples: samples(in: offset..<end), sampleOffset: offset)
    }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioFrame.self)
        state.withLock { $0.subscribers.append(continuation) }
        return stream
    }

    /// Sends `frame` to `frames()` subscribers and moves the position.
    func publish(_ frame: AudioFrame) {
        let subscribers = state.withLock { state in
            state.position = frame.nextSampleOffset
            return state.subscribers
        }
        for subscriber in subscribers {
            subscriber.yield(frame)
        }
    }

    func finishFrames() {
        let subscribers = state.withLock { state in
            defer { state.subscribers.removeAll() }
            return state.subscribers
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    func history(in range: Range<Int64>) -> AudioFrame? {
        let position = position
        let lower = max(range.lowerBound, position - historyLength, 0)
        let upper = min(range.upperBound, position)
        guard lower < upper else { return nil }
        return AudioFrame(samples: samples(in: lower..<upper), sampleOffset: lower)
    }
}

/// VAD events from a list, for `start()` tests.
final class ScriptedVoiceActivity: VoiceActivitySource {
    private struct State {
        var subscribers: [AsyncStream<VoiceActivityEvent>.Continuation] = []
        var delivered = 0
    }

    /// Lets the `@Sendable` unfolding closure own a stream iterator.
    private final class Iterator: @unchecked Sendable {
        var base: AsyncStream<VoiceActivityEvent>.Iterator
        init(_ base: AsyncStream<VoiceActivityEvent>.Iterator) { self.base = base }
    }

    private let state = Mutex(State())

    func events() -> AsyncStream<VoiceActivityEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceActivityEvent.self)
        state.withLock { $0.subscribers.append(continuation) }
        let iterator = Iterator(stream.makeAsyncIterator())
        return AsyncStream { [self] in
            let event = await iterator.base.next()
            if event != nil { state.withLock { $0.delivered += 1 } }
            return event
        }
    }

    /// How many events subscribers have taken off their streams: a test
    /// waits for it instead of hoping a pause was long enough (#180).
    var deliveredCount: Int { state.withLock { $0.delivered } }

    func speechAudio() -> AsyncStream<SpeechAudioEvent> {
        AsyncStream { $0.finish() }
    }

    var isSpeechActive: Bool { false }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    func send(_ event: VoiceActivityEvent) {
        for continuation in state.withLock({ $0.subscribers }) {
            continuation.yield(event)
        }
    }
}

// MARK: - VAD events

extension VoiceActivityEvent {
    /// The stream position when VAD decided it.
    var detectedAt: Int64 {
        switch self {
        case .speechStarted(let onset): onset.detectedAt
        case .speechEnded(let segment): segment.detectedAt
        }
    }

    /// The same event `offset` samples later (for looped fixtures).
    func shifted(by offset: Int64) -> VoiceActivityEvent {
        switch self {
        case .speechStarted(let onset):
            .speechStarted(
                SpeechOnset(
                    segmentID: onset.segmentID, startOffset: onset.startOffset + offset,
                    sampleRate: onset.sampleRate, isContinuation: onset.isContinuation,
                    detectedAt: onset.detectedAt + offset))
        case .speechEnded(let segment):
            .speechEnded(
                SpeechSegment(
                    id: segment.id,
                    sampleRange: (segment.sampleRange.lowerBound + offset)..<(segment.sampleRange.upperBound + offset),
                    sampleRate: segment.sampleRate, isContinuation: segment.isContinuation,
                    endReason: segment.endReason, detectedAt: segment.detectedAt + offset,
                    peakProbability: segment.peakProbability, meanProbability: segment.meanProbability))
        }
    }
}

/// VAD's events for a fixture, from Silero's recorded probabilities through
/// the real segmenter (the same events the live model gives).
func recordedVADEvents(for fixture: VADFixture) async throws -> [VoiceActivityEvent] {
    let model = ReplayedSpeechProbabilityModel(try fixture.recordedProbabilities())
    return await SegmenterRun.run(fixture.frames(), model: model).events
}

// MARK: - Replay

/// Feeds a transcriber audio and VAD events in stream order, as fast as
/// possible, and records where in the stream each transcript event came
/// out.
struct TranscriptionReplay {
    struct Emitted: Sendable {
        let event: TranscriptEvent
        /// The stream position (end of the audio received) when it was
        /// emitted.
        let position: Int64
        /// Wall time of the `ingest` call that emitted it: the compute that
        /// comes on top of the audio-time latency.
        let ingestTime: Duration
    }

    var emitted: [Emitted] = []
    var statistics = StreamingTranscriberStatistics()

    var finals: [Utterance] {
        emitted.compactMap { if case .final(let utterance) = $0.event { utterance } else { nil } }
    }

    var finalEmissions: [(utterance: Utterance, position: Int64)] {
        emitted.compactMap { if case .final(let utterance) = $0.event { (utterance, $0.position) } else { nil } }
    }

    var partials: [(text: String, range: TimeRange, position: Int64)] {
        emitted.compactMap {
            if case .partial(let text, let range) = $0.event { (text, range, $0.position) } else { nil }
        }
    }

    /// - Parameters:
    ///   - vadLag: How long after VAD's decision its event reaches the
    ///     transcriber, in samples (VAD's own compute time).
    ///   - progress: Called after every frame with the position.
    static func run(
        _ transcriber: ParakeetStreamingTranscriber,
        source: FixtureAudioSource,
        vadEvents: [VoiceActivityEvent],
        frameLength: Int = 320,
        vadLag: Int64 = 0,
        endOfStream: Bool = true,
        progress: ((Int64) async -> Void)? = nil
    ) async -> TranscriptionReplay {
        let events = transcriber.events
        let collector = Task {
            var collected: [TranscriptEvent] = []
            for await event in events { collected.append(event) }
            return collected
        }

        var pending = vadEvents.sorted { $0.detectedAt < $1.detectedAt }[...]
        var positions: [(Int64, Duration)] = []
        let clock = ContinuousClock()
        func count(_ statistics: StreamingTranscriberStatistics) -> Int {
            Int(statistics.partialsEmitted + statistics.utterancesCommitted)
        }

        var offset: Int64 = 0
        while offset < source.totalSamples {
            let frame = source.frame(at: offset, length: frameLength)
            var due: [VoiceActivityEvent] = []
            while let next = pending.first, next.detectedAt + vadLag <= frame.sampleOffset {
                due.append(next)
                pending.removeFirst()
            }
            source.position = frame.nextSampleOffset
            let started = clock.now
            await transcriber.ingest(due, frame: frame)
            let elapsed = clock.now - started
            let emittedCount = count(transcriber.statistics)
            while positions.count < emittedCount { positions.append((frame.nextSampleOffset, elapsed)) }
            await progress?(frame.nextSampleOffset)
            offset = frame.nextSampleOffset
        }
        if endOfStream {
            await transcriber.audioDidEnd(pending: Array(pending))
        }
        await transcriber.finish()
        let emittedCount = count(transcriber.statistics)
        while positions.count < emittedCount { positions.append((source.totalSamples, .zero)) }

        let collected = await collector.value
        var replay = TranscriptionReplay()
        replay.emitted = zip(collected, positions).map { Emitted(event: $0, position: $1.0, ingestTime: $1.1) }
        replay.statistics = transcriber.statistics
        return replay
    }
}

// MARK: - Text

/// Word error rate of `hypothesis` against `reference`, case and
/// punctuation insensitive.
func wordErrorRate(_ hypothesis: String, reference: String) -> Double {
    func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
    let h = words(hypothesis)
    let r = words(reference)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var previous = Array(0...h.count)
    for i in 1...r.count {
        var current = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where j <= h.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return Double(previous[h.count]) / Double(r.count)
}

extension Duration {
    var milliseconds: Double { timeInterval * 1_000 }
}

func samplesToMilliseconds(_ samples: Int64) -> Double {
    Double(samples) / 16
}
