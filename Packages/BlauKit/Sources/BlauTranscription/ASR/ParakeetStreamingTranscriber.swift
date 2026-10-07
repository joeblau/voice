import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Streaming speech-to-text for the user's side of the conversation (#29):
/// partial transcripts while they speak, and one final `Utterance` per
/// end of utterance.
///
/// ```swift
/// let transcriber = try await ParakeetStreamingTranscriber.load(
///     modelDirectory: modelManager.directory(for: .parakeetRealtimeEOU)!,
///     audio: capture.hub,            // the 16 kHz capture stream and its history
///     voiceActivity: vad)            // VoiceActivitySegmenter, running on the same hub
/// try await transcriber.start()
/// for await event in transcriber.events {
///     switch event {
///     case .partial(let text, let range): ...   // replaces the previous partial
///     case .final(let utterance): ...           // commit it
///     case .refined: break                      // only from SecondPassTranscriber
///     }
/// }
/// ```
///
/// **Only while someone speaks.** The recognizer runs from VAD's speech
/// onset (read back from the capture history, so the first word isn't
/// clipped while VAD confirms it) until the utterance is committed. In
/// between utterances nothing is decoded.
///
/// **When an utterance ends.** It keeps transcribing the real audio after
/// VAD reports the end of speech, so the model's end-of-utterance detector
/// (which needs to hear the silence) can decide. Whichever comes first
/// commits the utterance:
///
/// 1. the model confirms the end of utterance (`ParakeetEouRecognizer`);
/// 2. `silenceCommitDelay` of audio has passed since the end of speech VAD
///    reported, with no new speech (the VAD fallback);
/// 3. the utterance reaches `maximumUtteranceDuration`;
/// 4. the stream ends or `stop()` is called.
///
/// Speech that resumes before then (VAD reports a new onset) carries on in
/// the same utterance, so a pause to think doesn't split a sentence. After a
/// commit the recognizer is reset, so its token history, and the cost of
/// every partial, never grows past one utterance.
///
/// **Positions** are absolute 16 kHz sample offsets of the capture stream,
/// as everywhere in the pipeline; `TimeRange`s are on the same timeline.
///
/// Feed it with `start()`, which follows `audio.frames()` and
/// `voiceActivity.events()` until `stop()`.
public actor ParakeetStreamingTranscriber: Transcriber {
    public nonisolated let events: AsyncStream<TranscriptEvent>
    public nonisolated let configuration: StreamingTranscriberConfiguration

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private var recognizer: any StreamingSpeechRecognizer
    private let audio: any CaptureFrameSource
    private let voiceActivity: any VoiceActivitySource
    private let chunkSizePolicy: (any ASRChunkSizePolicy)?
    private let recognizerProvider: RecognizerProvider?
    private let signposter: Signposter
    private let clock: any BlauClock
    private let logger = Log.asr
    private let shared = Mutex(StreamingTranscriberStatistics())

    private var conversationID: ConversationID
    private var driver: Task<Void, Never>?
    private var vadFeed: Task<Void, Never>?
    private var isFinished = false

    /// End of the audio received so far.
    private var receivedEnd: Int64?
    /// The latest live frame, read from before going to the history.
    private var currentFrame: AudioFrame?
    /// A recent stream position and the wall-clock time it was captured.
    private var wallAnchor: (offset: Int64, date: Date)?
    /// Whether VAD has a speech segment open, from its events.
    private var isSpeechActive = false
    /// Audio before this offset belongs to committed utterances: where the
    /// model's end of utterance was, or the end of the speech VAD reported
    /// in an utterance committed on silence. A new onset never starts
    /// earlier.
    private var committedEnd: Int64 = 0
    private var utterance: OpenUtterance?
    private var nextUtteranceNumber = 0
    private var consecutiveFailures = 0
    /// Chunk sizes the provider couldn't supply, so they aren't retried for
    /// every utterance.
    private var unavailableChunkSizes: Set<ASRChunkSize> = []

    /// The utterance being transcribed.
    private struct OpenUtterance {
        let number: Int
        /// Where the recognizer's audio starts.
        var audioStart: Int64
        /// Where the speech starts (the VAD onset), for the time range.
        var speechStart: Int64
        /// End of the audio given to the recognizer.
        var fedEnd: Int64
        var transcript = ""
        var lastPartial = ""
        var decodedSamples: Int64 = 0
        var lastTokenEnd: Int64?
        /// The end of speech VAD reported, while waiting to see whether it
        /// resumes; `nil` while speech is active.
        var speechEnd: Int64?
        /// `asr.eou`: from VAD's end of speech to the decision.
        var endOfSpeechInterval: SignpostInterval?
    }

    /// - Parameters:
    ///   - recognizer: The speech recognizer, normally a
    ///     `ParakeetEouRecognizer`.
    ///   - audio: The 16 kHz capture stream and its history (`CaptureHub`).
    ///   - voiceActivity: Speech boundaries over the same stream
    ///     (`VoiceActivitySegmenter`, run by the caller).
    ///   - configuration: When utterances end.
    ///   - conversationID: The conversation new utterances belong to.
    ///   - chunkSizePolicy: Picks the chunk size between utterances (the
    ///     thermal hook); `nil` keeps the recognizer's.
    ///   - recognizerProvider: Supplies recognizers for other chunk sizes.
    ///   - signposter: Where `asr.eou` intervals go (the recognizer emits
    ///     `asr.chunk`).
    ///   - clock: Wall-clock timestamps for `Utterance.startedAt`.
    public init(
        recognizer: any StreamingSpeechRecognizer,
        audio: any CaptureFrameSource,
        voiceActivity: any VoiceActivitySource,
        configuration: StreamingTranscriberConfiguration = .standard,
        conversationID: ConversationID = ConversationID(),
        chunkSizePolicy: (any ASRChunkSizePolicy)? = nil,
        recognizerProvider: RecognizerProvider? = nil,
        signposter: Signposter = Signposts.asr,
        clock: any BlauClock = SystemClock()
    ) {
        self.recognizer = recognizer
        self.audio = audio
        self.voiceActivity = voiceActivity
        self.configuration = configuration
        self.conversationID = conversationID
        self.chunkSizePolicy = chunkSizePolicy
        self.recognizerProvider = recognizerProvider
        self.signposter = signposter
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        driver?.cancel()
        vadFeed?.cancel()
        continuation.finish()
    }

    /// A snapshot of the counters.
    public nonisolated var statistics: StreamingTranscriberStatistics {
        shared.withLock { $0 }
    }

    /// The chunk size the current recognizer runs at.
    public var chunkSize: ASRChunkSize { recognizer.chunkSize }

    /// Whether `start()` is following the audio.
    public var isRunning: Bool { driver != nil }

    /// The end of the audio received so far, as a stream offset.
    public var receivedPosition: Int64? { receivedEnd }

    /// Utterances committed from now on belong to `id`.
    public func setConversationID(_ id: ConversationID) {
        conversationID = id
    }

    // MARK: Transcriber

    public func start() async throws {
        guard driver == nil, !isFinished else { return }
        await applyChunkSizePolicy()

        let inbox = EventInbox()
        let vadEvents = voiceActivity.events()
        let frames = audio.frames()
        vadFeed = Task {
            for await event in vadEvents {
                inbox.append(event)
            }
        }
        driver = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.ingest(inbox.drain(), frame: frame)
            }
            guard !Task.isCancelled else { return }
            await self?.audioDidEnd(pending: inbox.drain())
        }
        logger.notice("Streaming ASR started (\(self.recognizer.chunkSize.rawValue, privacy: .public) chunks)")
    }

    public func stop() async {
        if let driver {
            self.driver = nil
            driver.cancel()
            vadFeed?.cancel()
            vadFeed = nil
            await driver.value
            logger.notice("Streaming ASR stopped")
        }
        isSpeechActive = false
        if utterance != nil {
            await commit(.stopped)
        }
    }

    /// Stops and ends `events` for good.
    public func finish() async {
        await stop()
        isFinished = true
        continuation.finish()
    }

    // MARK: Input

    /// Handles VAD events that arrived since the last frame, then the frame.
    /// `start()` calls it for every captured frame; tests call it directly
    /// to control the interleaving.
    func ingest(_ vadEvents: [VoiceActivityEvent], frame: AudioFrame?) async {
        for event in vadEvents {
            await handle(event)
        }
        if let frame {
            await handle(frame)
        }
    }

    /// The audio stream ended: handles the last VAD events and commits what
    /// is open.
    func audioDidEnd(pending vadEvents: [VoiceActivityEvent]) async {
        await ingest(vadEvents, frame: nil)
        isSpeechActive = false
        if utterance != nil {
            await commit(.streamEnded)
        }
        driver = nil
        vadFeed?.cancel()
        vadFeed = nil
    }

    private func handle(_ event: VoiceActivityEvent) async {
        switch event {
        case .speechStarted(let onset):
            isSpeechActive = true
            if var open = utterance {
                if open.speechEnd != nil {
                    // Speech resumed before the utterance ended: same utterance.
                    _ = open.endOfSpeechInterval?.end(message: "resumed")
                    open.endOfSpeechInterval = nil
                    open.speechEnd = nil
                    utterance = open
                }
            } else {
                // The onset can be before the last commit: VAD confirms
                // speech 250–550 ms after it starts, so speech that resumed
                // just before the silence fallback fired is reported after
                // it. Start at the onset anyway (the fallback's flush only
                // ever saw the start of it), but never inside the speech of
                // the previous utterance.
                openUtterance(at: max(onset.startOffset, committedEnd))
                await pump()
            }

        case .speechEnded(let segment):
            switch segment.endReason {
            case .maximumDuration:
                // VAD split a long segment; the continuation starts at once.
                break
            case .silence:
                isSpeechActive = false
                guard var open = utterance else { return }
                let end = max(segment.sampleRange.upperBound, open.speechStart)
                open.speechEnd = end
                if open.endOfSpeechInterval == nil {
                    open.endOfSpeechInterval = signposter.beginInterval(.asrEndOfUtterance)
                }
                utterance = open
                await commitIfDue()
            case .streamEnded:
                isSpeechActive = false
                guard var open = utterance else { return }
                open.speechEnd = max(segment.sampleRange.upperBound, open.speechStart)
                utterance = open
                await commit(.streamEnded)
            }
        }
    }

    private func handle(_ frame: AudioFrame) async {
        guard frame.sampleRate == AudioFrame.captureSampleRate, !frame.isEmpty else { return }
        wallAnchor = (frame.nextSampleOffset, clock.now)
        currentFrame = frame
        receivedEnd = max(receivedEnd ?? frame.nextSampleOffset, frame.nextSampleOffset)
        await pump()
        currentFrame = nil
    }

    // MARK: Transcribing

    private func openUtterance(at start: Int64) {
        nextUtteranceNumber += 1
        utterance = OpenUtterance(number: nextUtteranceNumber, audioStart: start, speechStart: start, fedEnd: start)
        logger.debug(
            "Utterance \(self.nextUtteranceNumber, privacy: .public) opened at \(start, privacy: .public)")
    }

    /// Feeds the open utterance everything received that it hasn't had,
    /// committing (and reopening) as the decisions come.
    private func pump() async {
        while let open = utterance, let end = receivedEnd, open.fedEnd < end {
            guard let audio = self.audio(from: open.fedEnd, to: end) else {
                // Nothing retained for that span (it scrolled out of the
                // history): skip to what arrives next.
                record { $0.samplesMissed += end - open.fedEnd }
                skip(to: end)
                break
            }
            if audio.sampleOffset > open.fedEnd {
                record { $0.samplesMissed += audio.sampleOffset - open.fedEnd }
                skip(to: audio.sampleOffset)
            }

            let output: RecognizerOutput
            do {
                output = try await recognizer.append(audio)
                consecutiveFailures = 0
            } catch {
                await recognizerFailed(error)
                continue
            }
            apply(output, fedFrom: audio.sampleOffset)

            if output.isEndOfUtterance {
                await commit(.endOfUtterance)
            } else {
                await commitIfDue()
            }
        }
    }

    /// The audio for `[start, end)`: from the current frame when it covers
    /// the span, otherwise from the capture history (clipped to what is
    /// retained, so it may start later than `start`).
    private func audio(from start: Int64, to end: Int64) -> AudioFrame? {
        if let frame = currentFrame, start >= frame.sampleOffset, end <= frame.nextSampleOffset {
            let lower = Int(start - frame.sampleOffset)
            let upper = Int(end - frame.sampleOffset)
            if lower == 0, upper == frame.sampleCount { return frame }
            return AudioFrame(samples: Array(frame.samples[lower..<upper]), sampleOffset: start)
        }
        if let history = self.audio.history(in: start..<end), !history.isEmpty {
            return history
        }
        // No history (a source without one): use the part of the current
        // frame that is in the span.
        guard let frame = currentFrame, frame.nextSampleOffset > start, frame.sampleOffset < end else { return nil }
        let lower = Int(max(start, frame.sampleOffset) - frame.sampleOffset)
        let upper = Int(min(end, frame.nextSampleOffset) - frame.sampleOffset)
        return AudioFrame(samples: Array(frame.samples[lower..<upper]), sampleOffset: frame.sampleOffset + Int64(lower))
    }

    /// Moves the open utterance past audio it can't have.
    private func skip(to offset: Int64) {
        guard var open = utterance, offset > open.fedEnd else { return }
        if open.fedEnd == open.audioStart, open.decodedSamples == 0 {
            // Nothing fed yet: the utterance simply starts later.
            open.audioStart = offset
            open.speechStart = offset
        }
        open.fedEnd = offset
        utterance = open
        logger.notice("Streaming ASR skipped to \(offset, privacy: .public): audio no longer in the history")
    }

    private func apply(_ output: RecognizerOutput, fedFrom start: Int64) {
        guard var open = utterance else { return }
        open.fedEnd = start + Int64(output.consumedSamples)
        open.transcript = output.transcript
        open.decodedSamples = output.decodedSamples
        open.lastTokenEnd = output.lastTokenEnd
        record {
            $0.chunksProcessed += Int64(output.chunks)
            $0.modelTime += output.modelTime
            $0.samplesTranscribed += Int64(output.consumedSamples)
            if output.chunks == 1 {
                $0.slowestChunk = max($0.slowestChunk, output.modelTime)
            }
        }

        let text = Self.normalized(output.transcript)
        if output.hasNewText, !text.isEmpty, text != open.lastPartial, !output.isEndOfUtterance {
            open.lastPartial = text
            let end = min(open.fedEnd, open.audioStart + max(output.decodedSamples, output.lastTokenEnd ?? 0))
            let range = Self.range(open.speechStart, max(end, open.speechStart))
            continuation.yield(.partial(text: text, range: range))
            record { $0.partialsEmitted += 1 }
        }
        utterance = open
    }

    /// Commits on the VAD fallback or the length limit when they are due.
    private func commitIfDue() async {
        guard let open = utterance else { return }
        if let speechEnd = open.speechEnd, open.fedEnd >= speechEnd + configuration.silenceCommitSamples {
            await commit(.silence)
        } else if open.fedEnd - open.audioStart >= configuration.maximumUtteranceSamples {
            await commit(.maximumLength)
        }
    }

    /// Ends the open utterance: emits its final (unless it is blank), resets
    /// the recognizer, and opens the next one at once if speech is still
    /// going on.
    private func commit(_ reason: UtteranceCommitReason) async {
        guard var open = utterance else { return }
        utterance = nil

        var position = open.fedEnd
        if reason == .endOfUtterance {
            // What the model decoded up to its decision; audio after it is
            // the next utterance's.
            position = min(open.fedEnd, open.audioStart + open.decodedSamples)
        } else if reason != .recognizerFailure {
            // On silence the recognizer has been fed `silenceCommitDelay`
            // past the end of speech. If speech resumed in that time and VAD
            // confirms it only after this commit, the next utterance decodes
            // it from its onset, so this one keeps only the words up to the
            // end of speech (and one encoder frame, for a word the model
            // emits on the frame after VAD's end).
            let frame = Int64(recognizer.chunkSize.frameSamples)
            let cutoff = reason == .silence ? open.speechEnd.map { $0 - open.audioStart + frame } : nil
            do {
                let output = try await recognizer.finish(keepingTokensThrough: cutoff)
                open.transcript = output.transcript
                open.lastTokenEnd = cutoff == nil ? output.lastTokenEnd ?? open.lastTokenEnd : output.lastTokenEnd
                record {
                    $0.chunksProcessed += Int64(output.chunks)
                    $0.modelTime += output.modelTime
                }
            } catch {
                record { $0.recognizerFailures += 1 }
                logger.error(
                    "Streaming ASR couldn't flush the utterance: \(String(describing: error), privacy: .public)")
            }
        }
        await recognizer.reset()
        let speechEnd = open.speechEnd.flatMap { $0 > open.audioStart && $0 < position ? $0 : nil }
        committedEnd = max(committedEnd, reason == .endOfUtterance ? position : speechEnd ?? position)

        _ = open.endOfSpeechInterval?.end(message: reason.rawValue)
        let text = Self.normalized(open.transcript)
        record { $0.commits[reason, default: 0] += 1 }

        if let speechEnd = open.speechEnd, reason == .endOfUtterance || reason == .silence {
            let delay = Duration.samples(max(0, position - speechEnd), sampleRate: AudioFrame.captureSampleRate)
            record {
                $0.endOfSpeechCommits += 1
                $0.endOfSpeechCommitDelay += delay
                $0.slowestEndOfSpeechCommit = max($0.slowestEndOfSpeechCommit, delay)
            }
        }

        if text.isEmpty {
            record { $0.blankUtterancesDropped += 1 }
            logger.debug(
                "Utterance \(open.number, privacy: .public) had no words (\(reason.rawValue, privacy: .public))")
        } else {
            let utterance = makeUtterance(open, text: text, position: position)
            continuation.yield(.final(utterance))
            record { $0.utterancesCommitted += 1 }
            logger.info(
                """
                Utterance \(open.number, privacy: .public) committed (\(reason.rawValue, privacy: .public)): \
                \(open.speechStart, privacy: .public)..<\(position, privacy: .public), \
                \(text.count, privacy: .public) characters: \(text, privacy: .private)
                """
            )
        }

        if isSpeechActive, reason != .stopped, reason != .streamEnded {
            // Still speaking (a long monologue, or the model ended the
            // utterance mid-segment): the next one starts where this ended.
            openUtterance(at: position)
        } else {
            await applyChunkSizePolicy()
        }
    }

    private func recognizerFailed(_ error: any Error) async {
        record { $0.recognizerFailures += 1 }
        consecutiveFailures += 1
        if consecutiveFailures == 1 || consecutiveFailures.isMultiple(of: 100) {
            logger.error(
                """
                Streaming ASR failed (\(self.consecutiveFailures, privacy: .public) in a row): \
                \(String(describing: error), privacy: .public)
                """
            )
        }
        guard let open = utterance else { return }
        // Commit what was decoded, and don't feed the failing audio again.
        await commit(.recognizerFailure)
        if var reopened = utterance {
            let end = max(receivedEnd ?? open.fedEnd, open.fedEnd)
            reopened.audioStart = end
            reopened.speechStart = end
            reopened.fedEnd = end
            utterance = reopened
        }
        committedEnd = max(committedEnd, receivedEnd ?? open.fedEnd)
    }

    private func makeUtterance(_ open: OpenUtterance, text: String, position: Int64) -> Utterance {
        let start = open.speechStart
        // VAD's end of speech when the utterance ended in silence, else the
        // end of the last word.
        let end =
            open.speechEnd.flatMap { $0 > start ? $0 : nil }
            ?? open.lastTokenEnd.map { min(open.audioStart + $0, position) }
            ?? position
        return Utterance(
            conversationID: conversationID,
            speaker: configuration.speaker,
            text: text,
            timeRange: Self.range(start, max(start, end)),
            startedAt: wallDate(at: start),
            speakerDecision: nil
        )
    }

    // MARK: Chunk size

    private func applyChunkSizePolicy() async {
        guard let chunkSizePolicy, let recognizerProvider else { return }
        let current = recognizer.chunkSize
        let preferred = chunkSizePolicy.preferredChunkSize(current: current)
        guard preferred != current else {
            unavailableChunkSizes.removeAll()
            return
        }
        guard !unavailableChunkSizes.contains(preferred) else { return }
        do {
            guard let replacement = try await recognizerProvider(preferred) else {
                unavailableChunkSizes.insert(preferred)
                logger.notice(
                    "Streaming ASR stays at \(current.rawValue, privacy: .public): no \(preferred.rawValue, privacy: .public) model"
                )
                return
            }
            await recognizer.reset()
            recognizer = replacement
            record { $0.chunkSizeChanges += 1 }
            logger.notice(
                "Streaming ASR switched from \(current.rawValue, privacy: .public) to \(preferred.rawValue, privacy: .public) chunks"
            )
        } catch {
            unavailableChunkSizes.insert(preferred)
            logger.error(
                "Streaming ASR couldn't load \(preferred.rawValue, privacy: .public) chunks: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Helpers

    /// The wall-clock time `offset` was captured, from the latest live frame.
    private func wallDate(at offset: Int64) -> Date {
        guard let anchor = wallAnchor else { return clock.now }
        let samples = anchor.offset - offset
        return anchor.date.addingTimeInterval(-Double(samples) / Double(AudioFrame.captureSampleRate))
    }

    private func record(_ body: (inout StreamingTranscriberStatistics) -> Void) {
        shared.withLock { body(&$0) }
    }

    private static func range(_ start: Int64, _ end: Int64) -> TimeRange {
        let rate = AudioFrame.captureSampleRate
        return TimeRange(start: .samples(max(0, start), sampleRate: rate), end: .samples(max(0, end), sampleRate: rate))
    }

    /// Trimmed, with runs of whitespace collapsed.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension ParakeetStreamingTranscriber {
    /// A transcriber over the Parakeet realtime EOU model installed in
    /// `modelDirectory` (`ModelManager.directory(for: .parakeetRealtimeEOU)`).
    public static func load(
        modelDirectory: URL,
        audio: any CaptureFrameSource,
        voiceActivity: any VoiceActivitySource,
        configuration: StreamingTranscriberConfiguration = .standard,
        endOfUtteranceDebounce: Duration = ParakeetEouRecognizer.defaultEndOfUtteranceDebounce,
        conversationID: ConversationID = ConversationID(),
        chunkSizePolicy: (any ASRChunkSizePolicy)? = nil,
        recognizerProvider: RecognizerProvider? = nil
    ) async throws -> ParakeetStreamingTranscriber {
        let recognizer = try await ParakeetEouRecognizer.load(
            modelDirectory: modelDirectory, endOfUtteranceDebounce: endOfUtteranceDebounce)
        return ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: audio, voiceActivity: voiceActivity, configuration: configuration,
            conversationID: conversationID, chunkSizePolicy: chunkSizePolicy, recognizerProvider: recognizerProvider)
    }
}

/// VAD events received between two frames. The VAD's stream is drained by
/// its own task; the frame loop takes what has arrived before each frame, so
/// all transcription happens on one task, in order.
private final class EventInbox: Sendable {
    private let events = Mutex<[VoiceActivityEvent]>([])

    func append(_ event: VoiceActivityEvent) {
        events.withLock { $0.append(event) }
    }

    func drain() -> [VoiceActivityEvent] {
        events.withLock { events in
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }
    }
}
