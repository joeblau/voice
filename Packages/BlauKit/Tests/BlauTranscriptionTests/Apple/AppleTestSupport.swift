import BlauAudio
import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// Seconds to 16 kHz stream offsets.
func streamOffset(_ seconds: Double) -> Int64 {
    Int64((seconds * 16_000).rounded())
}

extension SpeechAnalyzerResult {
    /// A volatile result over `from..<to` (seconds), finalized through
    /// `from`, with one range for its whole text as the system transcriber
    /// reports it.
    static func volatile(_ text: String, from: Double, to: Double) -> SpeechAnalyzerResult {
        SpeechAnalyzerResult(
            text: text, range: streamOffset(from)..<streamOffset(to), finalizedThrough: streamOffset(from),
            isFinal: false)
    }

    /// A final result with a time range per word (seconds), spaces between
    /// words as untimed text, covering `from..<to`.
    static func final(_ words: [(String, Double, Double)], from: Double, to: Double) -> SpeechAnalyzerResult {
        var segments: [Segment] = []
        for (index, word) in words.enumerated() {
            if index > 0 {
                segments.append(Segment(text: " ", range: nil))
            }
            segments.append(Segment(text: word.0, range: streamOffset(word.1)..<streamOffset(word.2)))
        }
        return SpeechAnalyzerResult(
            segments: segments, range: streamOffset(from)..<streamOffset(to), finalizedThrough: streamOffset(to),
            isFinal: true)
    }

    /// A final result whose words are spread evenly over `wordsFrom..<wordsTo`.
    static func final(_ text: String, wordsFrom: Double, wordsTo: Double, to: Double? = nil) -> SpeechAnalyzerResult {
        let words = text.split(separator: " ").map(String.init)
        let step = (wordsTo - wordsFrom) / Double(words.count)
        let timed = words.enumerated().map { index, word in
            (word, wordsFrom + step * Double(index), wordsFrom + step * Double(index + 1))
        }
        return .final(timed, from: wordsFrom, to: to ?? wordsTo)
    }
}

/// A `SpeechAnalyzerEngine` the test drives: it records what it is given,
/// and emits scripted results once the audio reaches them.
actor ScriptedSpeechAnalyzerEngine: SpeechAnalyzerEngine {
    struct Scripted: Sendable {
        /// Emitted once audio up to here has been appended.
        let at: Int64
        let result: SpeechAnalyzerResult
    }

    private var script: [Scripted]
    /// Emitted when a finalization is requested.
    private var onFinalization: [SpeechAnalyzerResult]
    /// Emitted by `finish()` before the stream ends.
    private var onFinish: [SpeechAnalyzerResult]
    private var startErrors: [any Error]
    private var results: AsyncThrowingStream<SpeechAnalyzerResult, any Error>.Continuation?

    private(set) var sessions = 0
    private(set) var sessionContextualStrings: [[String]] = []
    private(set) var updatedContextualStrings: [[String]] = []
    private(set) var finalizationRequests: [Int64] = []
    private(set) var finishes = 0
    private(set) var cancels = 0
    /// The audio appended, coalesced.
    private(set) var appended: [Range<Int64>] = []

    init(
        script: [Scripted] = [],
        onFinalization: [SpeechAnalyzerResult] = [],
        onFinish: [SpeechAnalyzerResult] = [],
        startErrors: [any Error] = []
    ) {
        self.script = script.sorted { $0.at < $1.at }
        self.onFinalization = onFinalization
        self.onFinish = onFinish
        self.startErrors = startErrors
    }

    var isSessionOpen: Bool { results != nil }

    var appendedEnd: Int64? { appended.last?.upperBound }

    func start(contextualStrings: [String]) async throws -> AsyncThrowingStream<SpeechAnalyzerResult, any Error> {
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        sessions += 1
        sessionContextualStrings.append(contextualStrings)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAnalyzerResult.self)
        results = continuation
        return stream
    }

    func append(_ frame: AudioFrame) async throws {
        let range = frame.sampleOffset..<frame.nextSampleOffset
        if let last = appended.last, last.upperBound == range.lowerBound {
            appended[appended.count - 1] = last.lowerBound..<range.upperBound
        } else {
            appended.append(range)
        }
        while let next = script.first, next.at <= range.upperBound {
            script.removeFirst()
            results?.yield(next.result)
        }
    }

    func requestFinalization(through position: Int64) async {
        finalizationRequests.append(position)
        for result in onFinalization {
            results?.yield(result)
        }
        onFinalization.removeAll()
    }

    func setContextualStrings(_ strings: [String]) async {
        updatedContextualStrings.append(strings)
    }

    func finish() async {
        finishes += 1
        for result in onFinish {
            results?.yield(result)
        }
        onFinish.removeAll()
        results?.finish()
        results = nil
    }

    func cancel() async {
        cancels += 1
        results?.finish()
        results = nil
    }

    /// Pushes a result now.
    func emit(_ result: SpeechAnalyzerResult) {
        results?.yield(result)
    }

    /// Fails the session's results stream.
    func fail(_ error: any Error) {
        results?.finish(throwing: error)
        results = nil
    }
}

/// A capture stream of silence with a history, whose `frames(replaying:)`
/// honours the lookback. Frames are published by the test.
final class SilentCaptureSource: CaptureFrameSource {
    private struct State {
        var position: Int64 = 0
        var subscribers: [AsyncStream<AudioFrame>.Continuation] = []
        var lookbacks: [Duration] = []
    }

    private let state = Mutex(State())

    var position: Int64 { state.withLock { $0.position } }
    var lookbacks: [Duration] { state.withLock { $0.lookbacks } }
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioFrame.self)
        let position = state.withLock { state in
            state.subscribers.append(continuation)
            state.lookbacks.append(lookback)
            return state.position
        }
        let replay = lookback.sampleCount(sampleRate: AudioFrame.captureSampleRate)
        var offset = max(0, position - replay)
        while offset < position {
            let length = Int(min(320, position - offset))
            continuation.yield(AudioFrame(samples: Array(repeating: 0, count: length), sampleOffset: offset))
            offset += Int64(length)
        }
        return stream
    }

    func history(in range: Range<Int64>) -> AudioFrame? {
        let upper = min(range.upperBound, position)
        guard range.lowerBound < upper else { return nil }
        return AudioFrame(
            samples: Array(repeating: 0, count: Int(upper - range.lowerBound)), sampleOffset: range.lowerBound)
    }

    /// Captures silence up to `seconds`, in 20 ms frames.
    func publish(to seconds: Double) {
        let end = streamOffset(seconds)
        while position < end {
            let offset = position
            let length = Int(min(320, end - offset))
            let frame = AudioFrame(samples: Array(repeating: 0, count: length), sampleOffset: offset)
            let subscribers = state.withLock { state in
                state.position = frame.nextSampleOffset
                return state.subscribers
            }
            for subscriber in subscribers {
                subscriber.yield(frame)
            }
        }
    }

    /// Keeps capturing silence from `seconds` on, 20 ms at a time and no
    /// further than `limit`, until `condition` holds, the way a live
    /// microphone keeps producing frames. VAD events reach the transcriber
    /// on their own task and are only looked at with the next frame, so a
    /// test that stops publishing at a fixed point can stall before one
    /// lands. Records an issue at the caller and throws `WaitTimedOut` after
    /// `timeout`.
    func keepCapturing(
        from seconds: Double,
        through limit: Double,
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var end = seconds
        publish(to: end)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out capturing through \(end) s", sourceLocation: sourceLocation)
                throw WaitTimedOut()
            }
            if end < limit {
                end = min(end + 0.02, limit)
                publish(to: end)
            }
            try await Task.sleep(for: .milliseconds(5))
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
}

/// VAD whose `isSpeechActive` the test sets.
final class SettableVoiceActivity: VoiceActivitySource {
    private struct State {
        var subscribers: [AsyncStream<VoiceActivityEvent>.Continuation] = []
        var isSpeechActive = false
    }

    private let state = Mutex(State())

    init(isSpeechActive: Bool = false) {
        state.withLock { $0.isSpeechActive = isSpeechActive }
    }

    var isSpeechActive: Bool {
        get { state.withLock { $0.isSpeechActive } }
        set { state.withLock { $0.isSpeechActive = newValue } }
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    func events() -> AsyncStream<VoiceActivityEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceActivityEvent.self)
        state.withLock { $0.subscribers.append(continuation) }
        return stream
    }

    func speechAudio() -> AsyncStream<SpeechAudioEvent> {
        AsyncStream { $0.finish() }
    }

    func send(_ event: VoiceActivityEvent) {
        for continuation in state.withLock({ $0.subscribers }) {
            continuation.yield(event)
        }
    }
}

extension VoiceActivityEvent {
    static func started(at seconds: Double, detectedAt: Double? = nil) -> VoiceActivityEvent {
        .speechStarted(
            SpeechOnset(
                segmentID: 1, startOffset: streamOffset(seconds), sampleRate: AudioFrame.captureSampleRate,
                isContinuation: false, detectedAt: streamOffset(detectedAt ?? seconds + 0.3)))
    }

    static func ended(from start: Double, to end: Double) -> VoiceActivityEvent {
        .speechEnded(
            SpeechSegment(
                id: 1, sampleRange: streamOffset(start)..<streamOffset(end), sampleRate: AudioFrame.captureSampleRate,
                isContinuation: false, endReason: .silence, detectedAt: streamOffset(end + 0.3), peakProbability: 0.9,
                meanProbability: 0.8))
    }
}

/// Drives an `AppleTranscriber` frame by frame with silent audio.
struct AppleFeeder {
    let transcriber: AppleTranscriber
    private(set) var position: Int64 = 0

    init(_ transcriber: AppleTranscriber, from seconds: Double = 0) {
        self.transcriber = transcriber
        self.position = streamOffset(seconds)
    }

    /// Feeds silence up to `seconds`, with `vad` events before the first
    /// frame.
    mutating func feed(to seconds: Double, vad: [VoiceActivityEvent] = []) async {
        var pending = vad
        let end = streamOffset(seconds)
        while position < end {
            let length = Int(min(320, end - position))
            let frame = AudioFrame(samples: Array(repeating: 0, count: length), sampleOffset: position)
            await transcriber.ingest(pending, frame: frame)
            pending = []
            position = frame.nextSampleOffset
        }
        if !pending.isEmpty {
            await transcriber.ingest(pending, frame: nil)
        }
    }
}

/// Collects a transcriber's events as they come.
final class TranscriptLog: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[TranscriptEvent]>([])
    }

    private let storage = Storage()

    init(_ stream: AsyncStream<TranscriptEvent>) {
        let storage = self.storage
        Task {
            for await event in stream {
                storage.events.withLock { $0.append(event) }
            }
        }
    }

    var all: [TranscriptEvent] { storage.events.withLock { $0 } }

    var finals: [Utterance] {
        all.compactMap { if case .final(let utterance) = $0 { utterance } else { nil } }
    }

    var partials: [String] {
        all.compactMap { if case .partial(let text, _) = $0 { text } else { nil } }
    }

    /// Waits until `count` finals have arrived; throws if they don't.
    func waitForFinals(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(sourceLocation: sourceLocation) { self.finals.count >= count }
    }

    func waitForEvents(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(sourceLocation: sourceLocation) { self.all.count >= count }
    }
}
