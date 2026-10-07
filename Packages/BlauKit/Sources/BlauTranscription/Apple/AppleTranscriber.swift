import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Streaming speech-to-text with Apple's on-device `SpeechAnalyzer` and
/// `SpeechTranscriber` (#31): the fallback for when Parakeet can't run
/// (models not downloaded, memory pressure, the Neural Engine unavailable in
/// the background) or the user chose the Apple engine in Settings.
///
/// ```swift
/// let transcriber = AppleTranscriber(
///     engine: SystemSpeechAnalyzerEngine(locale: locale),  // after AppleSpeechAssets.prepare
///     audio: capture.hub,
///     voiceActivity: vad,                // optional: Silero VAD when its model is installed
///     vocabulary: memoryVocabulary)      // optional: names to bias recognition toward
/// try await transcriber.start()
/// for await event in transcriber.events { ... }   // the same events as ParakeetStreamingTranscriber
/// ```
///
/// **How utterances end.** The system transcriber decodes progressively
/// (volatile results that are revised as more audio arrives) and finalizes
/// about once per sentence, with a time range for every word. An utterance
/// is the run of finalized sentences up to a pause, committed when:
///
/// 1. the last finalized word ended `silenceCommitDelay` ago and no newer
///    words are pending (the same 0.9 s rule as the Parakeet transcriber);
/// 2. words are pending but haven't changed for `finalizationRequestDelay`:
///    the engine is asked to finalize them, and the utterance commits when
///    they come back final (or, after `finalizationTimeout`, as they are);
/// 3. it reaches `maximumUtteranceDuration` (at the last finalized
///    sentence);
/// 4. the audio ends or `stop()` is called.
///
/// When a `VoiceActivitySource` is given, nothing commits while it reports
/// speech, and its end of speech counts as a pause like a word's end.
///
/// **Positions** are absolute 16 kHz sample offsets of the capture stream,
/// as everywhere in the pipeline, so its `TimeRange`s line up with the
/// Parakeet transcriber's and `TranscriberRouter` can switch between them.
public actor AppleTranscriber: RoutableTranscriber {
    public nonisolated let events: AsyncStream<TranscriptEvent>
    public nonisolated let configuration: AppleTranscriberConfiguration

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let engine: any SpeechAnalyzerEngine
    private let audio: any CaptureFrameSource
    private let voiceActivity: (any VoiceActivitySource)?
    private let vocabulary: (any RecognitionVocabularySource)?
    private let signposter: Signposter
    private let clock: any BlauClock
    private let logger = Log.asr
    private let shared = Mutex(AppleTranscriberStatistics())

    private var conversationID: ConversationID
    private var driver: Task<Void, Never>?
    private var vadFeed: Task<Void, Never>?
    private var resultsFeed: Task<Void, Never>?
    private var isFinished = false
    /// Whether the engine's results stream failed; the session is restarted
    /// on the next frame.
    private var needsRestart = false
    private var consecutiveRestarts = 0
    private var consecutiveAppendFailures = 0

    /// Audio before this offset is never transcribed (`start(resumingAt:)`).
    private var resumeBoundary: Int64 = 0
    /// End of the audio given to the engine.
    private var fedEnd: Int64?
    /// A recent stream position and the wall-clock time it was captured.
    private var wallAnchor: (offset: Int64, date: Date)?
    /// Audio before this offset belongs to committed utterances; results for
    /// it are dropped.
    private var committedEnd: Int64 = 0
    private var utterance: OpenUtterance?
    private var nextUtteranceNumber = 0
    /// The terms recognition is biased toward this session.
    private var vocabularyTerms: [String] = []

    /// From the `VoiceActivitySource`, when there is one.
    private var isSpeechActive = false
    /// The speech VAD reported since the last commit, oldest first.
    private var vadSpans: [VADSpan] = []
    /// The furthest the engine has finalized its results.
    private var finalizedThrough: Int64 = 0

    /// One stretch of speech from VAD.
    private struct VADSpan {
        var start: Int64
        /// `nil` while the speech goes on.
        var end: Int64?
    }

    /// A pause VAD confirmed: the speech ended at `end` and didn't resume
    /// for `silenceCommitDelay`. When it resumed later, `nextStart` is
    /// where.
    private struct Pause {
        let end: Int64
        let nextStart: Int64?
    }

    /// The utterance being transcribed.
    private struct OpenUtterance {
        let number: Int
        /// Where the speech starts.
        var start: Int64
        /// Whether `start` came from VAD (otherwise the first final's first
        /// word replaces it).
        var startIsFromVAD: Bool
        /// Finalized sentences, in order.
        var finals: [SpeechAnalyzerResult] = []
        /// The current guess for the audio after the last final.
        var volatile: SpeechAnalyzerResult?
        /// Where the audio fed had got to when the volatile text last
        /// changed.
        var volatileChangedAt: Int64 = 0
        /// When the engine was asked to finalize, as an audio position.
        var finalizationRequestedAt: Int64?
        var lastPartial = ""
        /// `asr.eou`: from when the speaker seems to have stopped to the
        /// commit.
        var endOfSpeechInterval: SignpostInterval?

        /// The end of the finalized audio.
        var finalizedEnd: Int64? { finals.map(\.range.upperBound).max() }

        /// Where the last finalized word ends.
        var lastWordEnd: Int64? { finals.reversed().lazy.compactMap(\.lastWordEnd).first ?? finalizedEnd }
    }

    /// - Parameters:
    ///   - engine: The recognizer, normally a `SystemSpeechAnalyzerEngine`.
    ///   - audio: The 16 kHz capture stream and its history (`CaptureHub`).
    ///   - voiceActivity: Speech boundaries over the same stream
    ///     (`VoiceActivitySegmenter`, run by the caller), when the VAD model
    ///     is installed. Without it, pauses come from the words' times.
    ///   - vocabulary: Names and terms to bias recognition toward, read at
    ///     every `start`.
    ///   - configuration: When utterances end.
    ///   - conversationID: The conversation new utterances belong to.
    ///   - signposter: Where `asr.eou` intervals go.
    ///   - clock: Wall-clock timestamps for `Utterance.startedAt`.
    public init(
        engine: any SpeechAnalyzerEngine,
        audio: any CaptureFrameSource,
        voiceActivity: (any VoiceActivitySource)? = nil,
        vocabulary: (any RecognitionVocabularySource)? = nil,
        configuration: AppleTranscriberConfiguration = .standard,
        conversationID: ConversationID = ConversationID(),
        signposter: Signposter = Signposts.asr,
        clock: any BlauClock = SystemClock()
    ) {
        self.engine = engine
        self.audio = audio
        self.voiceActivity = voiceActivity
        self.vocabulary = vocabulary
        self.configuration = configuration
        self.conversationID = conversationID
        self.signposter = signposter
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        driver?.cancel()
        vadFeed?.cancel()
        resultsFeed?.cancel()
        continuation.finish()
    }

    /// A snapshot of the counters.
    public nonisolated var statistics: AppleTranscriberStatistics {
        shared.withLock { $0 }
    }

    /// Whether `start()` is following the audio.
    public var isRunning: Bool { driver != nil }

    /// The end of the audio given to the engine, as a stream offset.
    public var transcribedPosition: Int64? { fedEnd }

    /// How many stretches of VAD speech are remembered. For tests.
    var rememberedSpeechSpans: Int { vadSpans.count }

    /// The terms the current session is biased toward.
    public var contextualStrings: [String] { vocabularyTerms }

    public func setConversationID(_ id: ConversationID) {
        conversationID = id
    }

    // MARK: Transcriber

    public func start() async throws {
        try await start(resumingAt: nil)
    }

    public func start(resumingAt position: Duration?) async throws {
        guard driver == nil, !isFinished else { return }
        vocabularyTerms = RecognitionVocabulary.normalized(await vocabulary?.recognitionVocabulary() ?? [])
        try await openSession()

        var lookback = Duration.zero
        if let position {
            let offset = position.sampleCount(sampleRate: AudioFrame.captureSampleRate)
            resumeBoundary = max(offset, committedEnd)
            committedEnd = resumeBoundary
            lookback = configuration.maximumResumeLookback
        } else {
            resumeBoundary = max(resumeBoundary, fedEnd ?? 0)
        }

        let inbox = EventInbox()
        if let voiceActivity {
            let vadEvents = voiceActivity.events()
            vadFeed = Task {
                for await event in vadEvents {
                    inbox.append(event)
                }
            }
            if voiceActivity.isSpeechActive {
                // Speech that began while another engine had the
                // conversation: its onset was reported before we listened.
                isSpeechActive = true
                vadSpans.append(VADSpan(start: resumeBoundary, end: nil))
            }
        }
        let frames = audio.frames(replaying: lookback)
        driver = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.ingest(inbox.drain(), frame: frame)
            }
            guard !Task.isCancelled else { return }
            await self?.audioDidEnd(pending: inbox.drain())
        }
        let resumeNote = position == nil ? "" : " at \(resumeBoundary)"
        logger.notice(
            "Apple ASR started\(resumeNote, privacy: .public) (\(self.vocabularyTerms.count, privacy: .public) contextual strings)"
        )
    }

    public func stop() async {
        if let driver {
            self.driver = nil
            driver.cancel()
            vadFeed?.cancel()
            vadFeed = nil
            await driver.value
            await closeSession()
            logger.notice("Apple ASR stopped")
        }
        isSpeechActive = false
        if utterance != nil {
            commit(.stopped, includingUnfinalized: true)
        }
    }

    /// Stops and ends `events` for good.
    public func finish() async {
        await stop()
        isFinished = true
        continuation.finish()
    }

    /// Re-reads the vocabulary and hands it to the running session, for
    /// example after memory learned new names.
    public func refreshVocabulary() async {
        let terms = RecognitionVocabulary.normalized(await vocabulary?.recognitionVocabulary() ?? [])
        guard terms != vocabularyTerms else { return }
        vocabularyTerms = terms
        if driver != nil {
            await engine.setContextualStrings(terms)
        }
    }

    // MARK: Session

    private func openSession() async throws {
        let results = try await engine.start(contextualStrings: vocabularyTerms)
        record { $0.sessionsStarted += 1 }
        needsRestart = false
        resultsFeed = Task { [weak self] in
            do {
                for try await result in results {
                    guard let self else { return }
                    await self.receive(result)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.engineFailed(error)
            }
        }
    }

    /// Finalizes what was fed and handles every result before returning.
    private func closeSession() async {
        await engine.finish()
        let feed = resultsFeed
        resultsFeed = nil
        await feed?.value
    }

    private func engineFailed(_ error: any Error) async {
        record { $0.engineFailures += 1 }
        logger.error("Apple ASR session failed: \(String(describing: error), privacy: .public)")
        if utterance != nil {
            commit(.recognizerFailure, includingUnfinalized: true)
        }
        needsRestart = true
    }

    /// Opens a new session after the last one failed, a few times in a row
    /// at most.
    private func restartSessionIfNeeded() async {
        guard needsRestart, driver != nil else { return }
        guard consecutiveRestarts < Self.maximumConsecutiveRestarts else { return }
        consecutiveRestarts += 1
        needsRestart = false
        resultsFeed?.cancel()
        resultsFeed = nil
        await engine.cancel()
        do {
            try await openSession()
            logger.notice("Apple ASR restarted its session (\(self.consecutiveRestarts, privacy: .public) in a row)")
        } catch {
            needsRestart = true
            record { $0.engineFailures += 1 }
            logger.error("Apple ASR couldn't restart: \(String(describing: error), privacy: .public)")
            if consecutiveRestarts == Self.maximumConsecutiveRestarts {
                logger.fault("Apple ASR gave up after \(Self.maximumConsecutiveRestarts, privacy: .public) restarts")
            }
        }
    }

    static let maximumConsecutiveRestarts = 3

    /// How far before VAD's end of speech the engine's finalization may stop
    /// and still count as covering it (400 ms): the engine places a sentence's
    /// end on its own estimate, up to a few hundred milliseconds before VAD's.
    /// Words it still holds in that gap start the next utterance.
    static let finalizationTolerance: Int64 = 6_400

    // MARK: Input

    /// Handles VAD events that arrived since the last frame, then the frame.
    /// `start()` calls it for every captured frame; tests call it directly
    /// to control the interleaving.
    func ingest(_ vadEvents: [VoiceActivityEvent], frame: AudioFrame?) async {
        for event in vadEvents {
            handle(event)
        }
        if let frame {
            await handle(frame)
        }
        await evaluate()
    }

    /// The audio stream ended: commits what is open.
    func audioDidEnd(pending vadEvents: [VoiceActivityEvent]) async {
        await ingest(vadEvents, frame: nil)
        driver = nil
        vadFeed?.cancel()
        vadFeed = nil
        await closeSession()
        isSpeechActive = false
        if utterance != nil {
            commit(.streamEnded, includingUnfinalized: true)
        }
    }

    private func handle(_ event: VoiceActivityEvent) {
        switch event {
        case .speechStarted(let onset):
            isSpeechActive = true
            guard vadSpans.last.map({ $0.end != nil }) ?? true else { return }
            let start = max(onset.startOffset, committedEnd)
            let previousEnd = vadSpans.last?.end
            vadSpans.append(VADSpan(start: start, end: nil))
            // Speech resuming within the pause carries on the utterance.
            if let previousEnd, start - previousEnd < configuration.silenceCommitSamples, var open = utterance,
                open.endOfSpeechInterval != nil
            {
                resumed(&open)
                utterance = open
            }
        case .speechEnded(let segment):
            // VAD splits long speech; the continuation starts at once.
            guard segment.endReason != .maximumDuration else { return }
            isSpeechActive = false
            let end = segment.sampleRange.upperBound
            if let last = vadSpans.indices.last, vadSpans[last].end == nil {
                vadSpans[last].end = max(end, vadSpans[last].start)
            } else {
                let start = max(segment.sampleRange.lowerBound, committedEnd)
                vadSpans.append(VADSpan(start: start, end: max(end, start)))
            }
            // Speech without words (noise VAD took for speech) is never
            // committed: forget it once it is older than any utterance.
            if utterance == nil {
                let horizon = (fedEnd ?? end) - configuration.maximumUtteranceSamples
                vadSpans.removeAll { span in span.end.map { $0 < horizon } ?? false }
            }
        }
    }

    private func handle(_ frame: AudioFrame) async {
        guard frame.sampleRate == AudioFrame.captureSampleRate, !frame.isEmpty else { return }
        await restartSessionIfNeeded()

        // Only what follows the resume position and the audio already fed.
        let lower = max(resumeBoundary, fedEnd ?? resumeBoundary)
        guard frame.nextSampleOffset > lower else {
            record { $0.samplesSkipped += Int64(frame.sampleCount) }
            return
        }
        var input = frame
        if frame.sampleOffset < lower {
            let skip = Int(lower - frame.sampleOffset)
            input = AudioFrame(samples: Array(frame.samples[skip...]), sampleOffset: lower)
            record { $0.samplesSkipped += Int64(skip) }
        }
        wallAnchor = (frame.nextSampleOffset, clock.now)

        do {
            try await engine.append(input)
            consecutiveAppendFailures = 0
            record { $0.samplesTranscribed += Int64(input.sampleCount) }
        } catch {
            consecutiveAppendFailures += 1
            record { $0.engineFailures += 1 }
            if consecutiveAppendFailures == 1 || consecutiveAppendFailures.isMultiple(of: 100) {
                logger.error(
                    """
                    Apple ASR couldn't take audio (\(self.consecutiveAppendFailures, privacy: .public) in a row): \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        }
        fedEnd = max(fedEnd ?? input.nextSampleOffset, input.nextSampleOffset)
    }

    // MARK: Results

    /// Handles one result from the engine. `start()` feeds them as they
    /// arrive; tests call it directly.
    func receive(_ raw: SpeechAnalyzerResult) async {
        consecutiveRestarts = 0
        record {
            if raw.isFinal {
                $0.finalResults += 1
            } else {
                $0.volatileResults += 1
            }
        }
        finalizedThrough = max(finalizedThrough, raw.finalizedThrough)
        guard raw.range.upperBound > committedEnd else {
            record { $0.staleResultsDropped += 1 }
            return
        }
        var result = raw
        if raw.range.lowerBound < committedEnd {
            result = raw.trimmed(before: committedEnd)
            record { $0.staleResultsDropped += 1 }
        }
        let hasWords = !Self.normalized(result.text).isEmpty

        if var open = utterance {
            if result.isFinal {
                if let volatile = open.volatile, volatile.range.lowerBound < result.range.upperBound {
                    open.volatile = nil
                }
                if hasWords {
                    if open.finals.isEmpty, !open.startIsFromVAD {
                        open.start = max(committedEnd, result.firstWordStart ?? result.range.lowerBound)
                    }
                    open.finals.append(result)
                }
            } else if hasWords {
                if Self.normalized(result.text) != Self.normalized(open.volatile?.text ?? "") {
                    open.volatileChangedAt = fedEnd ?? result.range.upperBound
                    resumed(&open)
                }
                open.volatile = result
            } else {
                open.volatile = nil
            }
            if let volatile = open.volatile, volatile.range.upperBound <= result.finalizedThrough, volatile != result {
                open.volatile = nil
            }
            if open.volatile == nil {
                open.finalizationRequestedAt = nil
            }
            utterance = open
        } else if hasWords {
            nextUtteranceNumber += 1
            // The VAD speech the first word belongs to: the earliest that
            // hadn't ended before it.
            let firstWord = result.firstWordStart ?? result.range.lowerBound
            let onset = vadSpans.first {
                $0.start >= committedEnd && $0.start <= result.range.upperBound && ($0.end ?? .max) > firstWord
            }?.start
            let start = onset ?? max(committedEnd, result.firstWordStart ?? result.range.lowerBound)
            var open = OpenUtterance(number: nextUtteranceNumber, start: start, startIsFromVAD: onset != nil)
            if result.isFinal {
                open.finals = [result]
            } else {
                open.volatile = result
                open.volatileChangedAt = fedEnd ?? result.range.upperBound
            }
            utterance = open
            logger.debug("Apple ASR utterance \(open.number, privacy: .public) opened at \(start, privacy: .public)")
        }

        emitPartialIfChanged()
        await evaluate()
    }

    /// The speaker resumed: the pause that was being timed is over.
    private func resumed(_ open: inout OpenUtterance) {
        if let interval = open.endOfSpeechInterval {
            _ = interval.end(message: "resumed")
            open.endOfSpeechInterval = nil
        }
        open.finalizationRequestedAt = nil
    }

    private func emitPartialIfChanged() {
        guard var open = utterance else { return }
        let parts = open.finals + (open.volatile.map { [$0] } ?? [])
        let text = Self.normalized(parts.map(\.text).joined(separator: " "))
        guard !text.isEmpty, text != open.lastPartial else { return }
        open.lastPartial = text
        utterance = open
        let end = max(parts.map(\.range.upperBound).max() ?? open.start, open.start)
        continuation.yield(.partial(text: text, range: Self.range(open.start, end)))
        record { $0.partialsEmitted += 1 }
    }

    // MARK: Deciding

    /// Commits the open utterance, or asks the engine to finalize it, when
    /// the rules say so.
    private func evaluate() async {
        guard var open = utterance, let fed = fedEnd else { return }

        if fed - open.start >= configuration.maximumUtteranceSamples {
            if !open.finals.isEmpty {
                commit(.maximumLength, includingUnfinalized: false)
            } else if let requested = open.finalizationRequestedAt {
                if fed - requested >= configuration.finalizationTimeoutSamples {
                    commit(.maximumLength, includingUnfinalized: true)
                }
            } else {
                await requestFinalization(through: fed)
            }
            return
        }

        if vadHeardSpeech(since: open.start) {
            // VAD decides where the speaker paused; the engine's finals
            // (which come 0.7-2 s after a sentence, often once the next
            // one has started) decide when the text up to there is ready.
            guard let pause = pause(after: open.start, at: fed) else { return }
            beginEndOfSpeech(&open)
            utterance = open
            let readyThrough = pause.end - Self.finalizationTolerance
            let pending = open.volatile.map { $0.range.lowerBound < readyThrough } ?? false
            if finalizedThrough >= readyThrough, !pending {
                commit(.silence, includingUnfinalized: false, at: pause)
            } else {
                await waitForFinalization(of: open, quietSince: max(pause.end, open.volatileChangedAt), at: fed)
            }
            return
        }

        if open.volatile != nil {
            await waitForFinalization(of: open, quietSince: open.volatileChangedAt, at: fed)
            return
        }
        beginEndOfSpeech(&open)
        utterance = open
        if fed - (open.lastWordEnd ?? open.start) >= configuration.silenceCommitSamples {
            commit(.silence, includingUnfinalized: false)
        }
    }

    /// Words the utterance needs are still unfinalized: asks for them once
    /// they have been unchanged for `finalizationRequestDelay`, and commits
    /// them as they are after `finalizationTimeout`.
    private func waitForFinalization(of open: OpenUtterance, quietSince: Int64, at fed: Int64) async {
        if let requested = open.finalizationRequestedAt {
            if fed - requested >= configuration.finalizationTimeoutSamples {
                commit(.silence, includingUnfinalized: true)
            }
            return
        }
        guard fed - quietSince >= configuration.finalizationRequestSamples else { return }
        var open = open
        beginEndOfSpeech(&open)
        utterance = open
        await requestFinalization(through: fed)
    }

    /// Whether VAD heard any of the speech from `start` on.
    private func vadHeardSpeech(since start: Int64) -> Bool {
        vadSpans.contains { ($0.end ?? .max) > start }
    }

    /// The first pause VAD confirmed after `start`: speech that ended and
    /// didn't resume within `silenceCommitDelay`.
    private func pause(after start: Int64, at fed: Int64) -> Pause? {
        for (index, span) in vadSpans.enumerated() {
            guard let end = span.end, end > start else { continue }
            if index + 1 < vadSpans.count {
                let next = vadSpans[index + 1].start
                if next - end >= configuration.silenceCommitSamples {
                    return Pause(end: end, nextStart: next)
                }
            } else if !isSpeechActive, fed - end >= configuration.silenceCommitSamples {
                return Pause(end: end, nextStart: nil)
            }
        }
        return nil
    }

    private func beginEndOfSpeech(_ open: inout OpenUtterance) {
        if open.endOfSpeechInterval == nil {
            open.endOfSpeechInterval = signposter.beginInterval(.asrEndOfUtterance)
        }
    }

    private func requestFinalization(through position: Int64) async {
        guard var open = utterance, open.finalizationRequestedAt == nil else { return }
        open.finalizationRequestedAt = fedEnd ?? position
        utterance = open
        record { $0.finalizationRequests += 1 }
        await engine.requestFinalization(through: position)
    }

    /// Ends the open utterance and emits its final (unless it is blank).
    ///
    /// - Parameters:
    ///   - includingUnfinalized: Whether the words the engine hasn't
    ///     finalized go into it. When they don't, they start the next
    ///     utterance.
    ///   - pause: The pause VAD confirmed, when it ends the utterance: words
    ///     from where the speech resumed start the next utterance.
    private func commit(_ reason: UtteranceCommitReason, includingUnfinalized: Bool, at pause: Pause? = nil) {
        guard let open = utterance else { return }
        utterance = nil

        var parts = open.finals
        var carried: [SpeechAnalyzerResult] = []
        if let pause, let next = pause.nextStart {
            // Halfway through the pause: the engine's word times start up
            // to a few hundred milliseconds before VAD's onset.
            let split = pause.end + (next - pause.end) / 2
            parts = open.finals.map { $0.prefix(before: split) }
            carried = open.finals.map { $0.trimmed(before: split) }.filter { !Self.normalized($0.text).isEmpty }
        }
        var leftover: SpeechAnalyzerResult?
        var end = parts.map(\.range.upperBound).max() ?? open.start
        var lastWord = parts.reversed().lazy.compactMap(\.lastWordEnd).first
        if let volatile = open.volatile {
            if includingUnfinalized {
                parts.append(volatile)
                end = max(end, volatile.range.upperBound)
                lastWord = max(lastWord ?? volatile.range.upperBound, volatile.lastWordEnd ?? volatile.range.upperBound)
                record { $0.unfinalizedCommits += 1 }
            } else {
                leftover = volatile
            }
        }
        let utteranceEnd: Int64
        if let pause {
            utteranceEnd = max(open.start, pause.end)
            // Not past what the engine finalized: its next guesses start
            // there, and they belong to the next utterance.
            committedEnd = max(committedEnd, min(pause.end, max(finalizedThrough, end)))
        } else {
            utteranceEnd = max(open.start, min(lastWord ?? end, end))
            committedEnd = max(committedEnd, end)
        }
        let spokenThrough = max(committedEnd, pause?.end ?? committedEnd)
        vadSpans.removeAll { span in span.end.map { $0 <= spokenThrough } ?? false }

        _ = open.endOfSpeechInterval?.end(message: reason.rawValue)
        record { $0.commits[reason, default: 0] += 1 }
        if reason == .silence, let fed = fedEnd {
            let delay = Duration.samples(max(0, fed - utteranceEnd), sampleRate: AudioFrame.captureSampleRate)
            record {
                $0.endOfSpeechCommits += 1
                $0.endOfSpeechCommitDelay += delay
                $0.slowestEndOfSpeechCommit = max($0.slowestEndOfSpeechCommit, delay)
            }
        }

        let text = Self.normalized(parts.map(\.text).joined(separator: " "))
        if text.isEmpty {
            record { $0.blankUtterancesDropped += 1 }
        } else {
            let utterance = Utterance(
                conversationID: conversationID,
                speaker: configuration.speaker,
                text: text,
                timeRange: Self.range(open.start, utteranceEnd),
                startedAt: wallDate(at: open.start),
                speakerDecision: nil
            )
            continuation.yield(.final(utterance))
            record { $0.utterancesCommitted += 1 }
            logger.info(
                """
                Apple ASR utterance \(open.number, privacy: .public) committed (\(reason.rawValue, privacy: .public)): \
                \(open.start, privacy: .public)..<\(utteranceEnd, privacy: .public), \
                \(text.count, privacy: .public) characters: \(text, privacy: .private)
                """
            )
        }

        if leftover != nil || !carried.isEmpty {
            // Speech carried on past what was committed (the next sentence
            // after a pause, or a long monologue): it starts the next
            // utterance.
            nextUtteranceNumber += 1
            let onset = pause?.nextStart
            let first = carried.first?.firstWordStart ?? leftover?.range.lowerBound ?? committedEnd
            var next = OpenUtterance(
                number: nextUtteranceNumber, start: max(committedEnd, onset ?? first), startIsFromVAD: onset != nil)
            next.finals = carried
            next.volatile = leftover
            next.volatileChangedAt = fedEnd ?? leftover?.range.upperBound ?? committedEnd
            utterance = next
            emitPartialIfChanged()
        }
    }

    // MARK: Helpers

    /// The wall-clock time `offset` was captured, from the latest frame.
    private func wallDate(at offset: Int64) -> Date {
        guard let anchor = wallAnchor else { return clock.now }
        let samples = anchor.offset - offset
        return anchor.date.addingTimeInterval(-Double(samples) / Double(AudioFrame.captureSampleRate))
    }

    private func record(_ body: (inout AppleTranscriberStatistics) -> Void) {
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

/// VAD events received between two frames, drained by the frame loop so
/// all decisions happen on one task, in order.
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
