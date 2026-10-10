import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// The voice ID verification gate (#47): only the enrolled speaker's
/// utterances reach Grok, without holding them up.
///
/// ```swift
/// let gate = VerificationGate(verifier: speakerVerifier, history: capture.hub)
/// let speech = vad.speechAudio()                        // subscribe before VAD runs
/// Task { await gate.run(speech: speech) }
/// let gated = gate.filter(transcriber.events)          // what the orchestrator reads
/// Task { await orchestrator.run(transcript: gated) }
/// // The app adapts it to BlauRealtime's `BargeInSpeakerGate` (`VoiceIDBargeInGate`).
/// let monitor = BargeInMonitor(target: orchestrator, speakerGate: VoiceIDBargeInGate(gate: gate), ...)
/// ```
///
/// **Speculative ASR.** The transcriber starts on VAD's speech onset, as it
/// always does (#29), whatever voice ID will say. The gate scores the speech
/// alongside it, so by the time the final utterance arrives its decision is
/// (nearly always) already made: the final is then committed (passed on) or
/// discarded at once.
///
/// **Scoring.** Each VAD segment is embedded and scored against the
/// voiceprint (``SpeechVerifying``) once 1.5 s of it has been heard, again at
/// 3 s (``VerificationGateConfiguration/scoreWindows``), and at its end when
/// it is noticeably longer than the last score covered. The score that
/// covered the most audio decides: `accept` at or above `T_hi`, `reject`
/// below `T_lo`, `uncertain` in between (``VoiceIDConfig``). A segment
/// shorter than 1 s isn't scored: it inherits the previous segment's
/// decision when the last scored speech ended less than 5 s before it, and
/// is `uncertain` otherwise.
///
/// **Utterances.** A final spans one or more segments (the transcriber keeps
/// an utterance open across short pauses). Each segment it covers gives a
/// decision: its final one if the segment has ended, otherwise a score of
/// the speech up to the utterance's end (reusing the last score when it
/// covers nearly all of it). The decisions combine by speech share
/// (``VerificationGateRules/combine(_:minorityShare:unattributedAllowance:)``),
/// and the result's ``GatedUtterance/Disposition`` decides:
///
/// | Decision | What happens |
/// | --- | --- |
/// | `accept` | Passed on with `speakerDecision: .accept` |
/// | `uncertain` | Passed on with `speakerDecision: .uncertain` if the ``UncertainSpeechPolicy`` allows (by default: in an active turn and at least 2 s long); dropped otherwise |
/// | `reject` | Dropped. Never sent; listed in ``verdicts`` for the DEBUG "ignored speech" lane |
///
/// A dropped final still reaches the orchestrator, marked
/// `speakerDecision: .reject`, which it ignores (never sent, never stored):
/// that ends the utterance in progress, so the partial text and the
/// `userSpeaking` state the speech's first partials started don't linger.
/// Partials of speech already rejected are held back, so a TV's words don't
/// show as the user's live text. A refined transcript (#30) is passed on
/// only for a final that was sent.
///
/// **Long speech.** VAD splits a segment at 8 s and the next one
/// (`SpeechOnset.isContinuation`) starts at the split point, which can be up
/// to a second before where VAD's audio carries on. The gate starts the
/// continuation with the audio the split segment had already received past
/// that point, so the continuation is scored on its own speech. Any other
/// gap in VAD's audio is filled from the capture history, and only with
/// silence when the history no longer holds it (a capture drop).
///
/// **Barge-in.** ``bargeInDecision(for:)`` (the `BargeInSpeakerGate` of
/// BlauRealtime's `BargeInMonitor`) waits for the speech's first decision,
/// so only accepted or uncertain speech interrupts Grok.
///
/// **Language filter (#50).** With a ``LanguageFilter``, the first 2 s of
/// every segment voice ID hasn't rejected are also identified (once that
/// much has been heard, or at the segment's end when it is shorter but at
/// least 1 s long), alongside the speaker scores. A final voice ID would
/// send is dropped as ``GatedUtterance/Disposition/otherLanguage`` when most
/// of its identified speech is in a language the user hasn't allowed, and
/// partials of such speech are held back like rejected ones.
///
/// **Latency.** The gate holds a final only while a decision is still being
/// computed: normally the end-of-speech re-score, one embedding (target:
/// < 100 ms beyond end of utterance, the gate's share of the latency
/// budget, #74). ``statistics`` keeps the hold time and every hold is a
/// `voiceid.gate` interval (its end message is the disposition); every
/// score is a `voiceid.embed` and a `voiceid.verify` interval.
public actor VerificationGate {
    public nonisolated let configuration: VerificationGateConfiguration

    /// Every final utterance the gate decided, in order: what was sent and
    /// what was ignored (the DEBUG "ignored speech" lane). A single
    /// consumer; the newest 64 are kept when nobody reads.
    public nonisolated let verdicts: AsyncStream<GatedUtterance>

    /// Whether the conversation is in an active turn, for the uncertain
    /// policy. The composition root reports Grok's side to it.
    public nonisolated let turnActivity: ConversationTurnActivity

    private nonisolated let verdictContinuation: AsyncStream<GatedUtterance>.Continuation
    private let verifier: any SpeechVerifying
    private let languageFilter: LanguageFilter?
    private let history: (any CaptureFrameSource)?
    private let onScoredSpeech: (@Sendable (ScoredSpeechSegment) -> Void)?
    private let clock: any BlauClock
    private let signposter: Signposter
    private nonisolated let shared = Mutex(VerificationGateStatistics())

    /// Segments by VAD id, and their ids in the order they started.
    private var segments: [Int: Segment] = [:]
    private var order: [Int] = []
    /// The segment VAD's speech audio is currently filling.
    private var openSegmentID: Int?
    /// The audio past the split point of a segment VAD split at its maximum
    /// duration: the start of the continuation that follows, which VAD
    /// doesn't send again.
    private var splitTail: AudioFrame?
    /// Tasks waiting for the gate's state to change.
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID: UInt64 = 0
    /// Finals passed on, so their refined text can follow (newest last).
    private var committedFinals: [UUID] = []

    /// One VAD segment as the gate tracks it.
    private struct Segment {
        let id: Int
        /// First sample of the speech.
        let start: Int64
        let sampleRate: Int
        /// The segment's audio from `start`, while it may still be scored.
        var samples: [Float] = []
        /// End of the speech, once VAD ended the segment.
        var speechEnd: Int64?
        /// The next checkpoint in `scoreWindows`.
        var nextCheckpoint = 0
        /// Scores of this segment, in completion order.
        var scores: [SpeakerScore] = []
        /// Embeddings in flight.
        var scoring = 0
        /// The decision once the segment has ended and been decided.
        var final: SegmentVerdict?
        /// Where the speech behind the latest decision ends: the end of
        /// what was scored, or, for an inherited decision, that of the
        /// segment it came from. Inheritance is measured from it.
        var evidenceEnd: Int64?
        /// The language filter's progress on this segment: it runs once.
        var languageCheck = LanguageCheckState.notStarted
        /// The language filter's verdict, once it ran (and succeeded).
        var language: LanguageVerdict?
        /// Accepted speech for adaptive updates, held until a language
        /// check still running when the segment was decided finishes.
        var awaitingLanguage: ScoredSpeechSegment?

        var hasEnded: Bool { speechEnd != nil }
        var bufferedEnd: Int64 { start + Int64(samples.count) }
        /// The best score: the one that covered the most audio. Once the
        /// segment has ended, only scores within its speech count: a
        /// checkpoint reached on VAD's hangover (the audio after the
        /// speech) scored silence too, with a longer window's thresholds.
        var best: SpeakerScore? {
            guard let speechEnd else { return VerificationGateRules.decision(from: scores) }
            let speech = speechEnd - start
            return VerificationGateRules.decision(
                from: scores.filter { $0.audioDuration.sampleCount(sampleRate: sampleRate) <= speech })
        }
        /// The latest decision: the final one, or the best score so far.
        var decision: SpeakerDecision? { final?.decision ?? best?.decision }

        func contains(_ range: Range<Int64>) -> Bool {
            start < range.upperBound && (speechEnd ?? .max) > range.lowerBound
        }
    }

    private enum LanguageCheckState {
        case notStarted
        case running
        case finished
    }

    /// - Parameters:
    ///   - verifier: Embeds and scores speech against the voiceprint
    ///     (``SpeakerVerifier``).
    ///   - history: The capture history (`CaptureHub`), to read speech VAD's
    ///     audio stream hasn't delivered yet when a final needs it. Optional.
    ///   - configuration: Windows, inheritance, the uncertain policy and the
    ///     waits.
    ///   - languageFilter: Drops speech in languages the user hasn't
    ///     allowed (#50). Optional.
    ///   - turnActivity: Whether the conversation is in an active turn.
    ///   - clock: Times the waits and the hold on finals.
    ///   - signposter: Where the `voiceid.gate` hold on each final goes.
    ///   - onScoredSpeech: Called with every segment accepted on its own
    ///     score (not inherited), once it has ended: adaptive voiceprint
    ///     updates (#49, ``VoiceprintAdapter/observe(_:)``). Called on the
    ///     gate's actor, so it must return at once.
    public init(
        verifier: any SpeechVerifying,
        history: (any CaptureFrameSource)? = nil,
        configuration: VerificationGateConfiguration = .standard,
        languageFilter: LanguageFilter? = nil,
        turnActivity: ConversationTurnActivity? = nil,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.voiceID,
        onScoredSpeech: (@Sendable (ScoredSpeechSegment) -> Void)? = nil
    ) {
        self.verifier = verifier
        self.languageFilter = languageFilter
        self.history = history
        self.onScoredSpeech = onScoredSpeech
        self.configuration = configuration
        self.clock = clock
        self.signposter = signposter
        self.turnActivity = turnActivity ?? ConversationTurnActivity(clock: clock)
        (verdicts, verdictContinuation) = AsyncStream.makeStream(
            of: GatedUtterance.self, bufferingPolicy: .bufferingNewest(64))
    }

    deinit {
        verdictContinuation.finish()
    }

    /// A snapshot of the counters.
    public nonisolated var statistics: VerificationGateStatistics {
        shared.withLock { $0 }
    }

    // MARK: Speech from VAD

    /// Follows VAD's speech audio (`VoiceActivitySource.speechAudio()`)
    /// until the stream ends or the task is cancelled, scoring each segment
    /// at its checkpoints and at its end. Subscribe before VAD sees audio.
    public func run(speech events: AsyncStream<SpeechAudioEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    /// Handles one event of VAD's speech audio.
    public func handle(_ event: SpeechAudioEvent) async {
        switch event {
        case .started(let onset):
            open(id: onset.segmentID, start: onset.startOffset, sampleRate: onset.sampleRate)
            if onset.isContinuation { seedContinuation(onset.segmentID) }
            splitTail = nil
        case .audio(let frame):
            guard let id = openSegmentID else { return }
            append(frame, to: id)
            await scoreDueCheckpoints(of: id)
            await checkLanguageIfDue(id)
        case .ended(let segment):
            if segments[segment.id] == nil {
                // Missed the start (subscribed mid-segment): track it anyway.
                open(id: segment.id, start: segment.sampleRange.lowerBound, sampleRate: segment.sampleRate)
            }
            if openSegmentID == segment.id { openSegmentID = nil }
            await finish(segment)
        }
    }

    private func open(id: Int, start: Int64, sampleRate: Int) {
        guard segments[id] == nil else { return }
        segments[id] = Segment(id: id, start: start, sampleRate: sampleRate)
        order.append(id)
        openSegmentID = id
        shared.withLock { $0.segments += 1 }
        forgetOldSegments()
        notifyWaiters()
    }

    /// Starts a continuation (VAD split the speech at its maximum duration)
    /// with the audio the split segment already received past the split
    /// point. VAD's audio simply carries on after a split, so without it the
    /// continuation's audio would begin up to a second after its start.
    private func seedContinuation(_ id: Int) {
        guard let tail = splitTail, var segment = segments[id], segment.samples.isEmpty,
            tail.sampleRate == segment.sampleRate, tail.sampleOffset <= segment.start,
            segment.start < tail.nextSampleOffset
        else { return }
        let limit = Int(configuration.maximumBufferedSpeech.sampleCount(sampleRate: segment.sampleRate))
        let skip = Int(segment.start - tail.sampleOffset)
        segment.samples.append(contentsOf: tail.samples[skip...].prefix(limit))
        segments[id] = segment
        shared.withLock { $0.seededContinuations += 1 }
    }

    private func append(_ frame: AudioFrame, to id: Int) {
        guard var segment = segments[id], !segment.hasEnded, frame.sampleRate == segment.sampleRate else { return }
        let limit = Int(configuration.maximumBufferedSpeech.sampleCount(sampleRate: segment.sampleRate))
        guard segment.samples.count < limit else { return }
        let end = segment.bufferedEnd
        if frame.sampleOffset > end {
            fillGap(end..<frame.sampleOffset, in: &segment, limit: limit)
        }
        let skip = Int(max(0, segment.bufferedEnd - frame.sampleOffset))
        if skip < frame.sampleCount {
            segment.samples.append(contentsOf: frame.samples[skip...].prefix(limit - segment.samples.count))
        }
        segments[id] = segment
        notifyWaiters()
    }

    /// Fills `gap`, audio of the segment VAD's stream didn't carry, from the
    /// capture history where it still holds it, and with silence (to keep
    /// positions aligned) where it doesn't: a capture drop.
    private func fillGap(_ gap: Range<Int64>, in segment: inout Segment, limit: Int) {
        var position = gap.lowerBound
        if let history, let frame = history.history(in: gap), frame.sampleRate == segment.sampleRate,
            frame.sampleOffset >= gap.lowerBound, frame.nextSampleOffset <= gap.upperBound
        {
            let silence = Int(frame.sampleOffset - position)
            segment.samples.append(
                contentsOf: repeatElement(0, count: max(0, min(silence, limit - segment.samples.count))))
            segment.samples.append(contentsOf: frame.samples.prefix(max(0, limit - segment.samples.count)))
            position = frame.nextSampleOffset
            shared.withLock { $0.gapSamplesFromHistory += frame.sampleCount }
        }
        let silence = Int(gap.upperBound - position)
        guard silence > 0 else { return }
        segment.samples.append(contentsOf: repeatElement(0, count: max(0, min(silence, limit - segment.samples.count))))
        shared.withLock { $0.gapSamplesSilenced += silence }
    }

    /// Scores the segment at every checkpoint its audio has reached.
    private func scoreDueCheckpoints(of id: Int) async {
        let windows = configuration.scoreWindows
        while let segment = segments[id], !segment.hasEnded, segment.nextCheckpoint < windows.count {
            let window = windows[segment.nextCheckpoint]
            let count = window.sampleCount(sampleRate: segment.sampleRate)
            guard segment.samples.count >= count else { return }
            segments[id]?.nextCheckpoint += 1
            let audio = AudioFrame(
                samples: Array(segment.samples.prefix(count)), sampleRate: segment.sampleRate,
                sampleOffset: segment.start)
            await score(id, audio)
        }
    }

    /// VAD ended `ended`: decide the segment for good.
    private func finish(_ ended: SpeechSegment) async {
        guard var segment = segments[ended.id] else { return }
        let speechEnd = max(segment.start, ended.sampleRange.upperBound)
        if ended.endReason == .maximumDuration, segment.bufferedEnd > speechEnd {
            // The continuation VAD starts next begins at the split point.
            let from = Int(speechEnd - segment.start)
            splitTail = AudioFrame(
                samples: Array(segment.samples[from...]), sampleRate: segment.sampleRate, sampleOffset: speechEnd)
        }
        segment.speechEnd = speechEnd
        segments[ended.id] = segment
        notifyWaiters()

        let speech = speechEnd - segment.start
        // The language check of speech shorter than the window, alongside
        // the end-of-segment score (unless voice ID already rejected it).
        // Only start a task when there is something to check: an idle child
        // task on every segment end (no filter, or speech past the window)
        // still has to hop onto the actor, which lengthens the hold.
        let early = segment.decision == .reject ? nil : startLanguageCheck(ended.id, speech: speech)
        let earlyLanguage: Task<Void, Never>? = early.map { audio in
            Task { await self.runLanguageCheck(ended.id, audio) }
        }
        let minimum = configuration.minimumScoredSpeech.sampleCount(sampleRate: segment.sampleRate)
        var verdict: SegmentVerdict
        if speech < minimum {
            verdict = inheritedVerdict(for: ended.id)
            shared.withLock { $0.shortSegments += 1 }
        } else {
            if needsScore(segment, through: speech) {
                if let audio = audio(of: segment, count: speech) {
                    await score(ended.id, audio)
                }
            }
            // Wait for a score an utterance started meanwhile.
            _ = await waitUntil(configuration.decisionTimeout) { (self.segments[ended.id]?.scoring ?? 0) == 0 }
            verdict = scoredVerdict(of: ended.id) ?? unscoredVerdict(ended.id, basis: .unscored)
        }
        let duration = Duration.samples(speech, sampleRate: segment.sampleRate)
        verdict = verdict.covering(duration)
        // Voice ID only now let the segment through (a later score, or the
        // decision it inherited): check its language before the audio goes.
        let late = verdict.decision == .reject ? nil : startLanguageCheck(ended.id, speech: speech)
        guard var settled = segments[ended.id] else {
            await earlyLanguage?.value
            return
        }
        settled.final = verdict
        if case .scored = verdict.basis { settled.evidenceEnd = speechEnd }
        let accepted = acceptedSpeech(settled, verdict: verdict, speech: speech)
        // The audio is no longer needed: utterances use the final decision.
        settled.samples = []
        segments[ended.id] = settled
        Log.voiceID.debug(
            """
            Segment \(ended.id, privacy: .public) (\(duration.milliseconds, format: .fixed(precision: 0), privacy: .public) ms): \
            \(verdict.decision.rawValue, privacy: .public)\(Self.describe(verdict), privacy: .public)
            """
        )
        notifyWaiters()
        await earlyLanguage?.value
        await runLanguageCheck(ended.id, late)
        guard let accepted, let checked = segments[ended.id] else { return }
        if checked.languageCheck == .running {
            // A final's check of this segment (``languageVerdict(of:through:)``)
            // is still in flight: observe once it's done.
            segments[ended.id]?.awaitingLanguage = accepted
        } else {
            observe(accepted, of: checked)
        }
    }

    /// Hands accepted speech to adaptive updates, once its language is
    /// known: they only learn speech the language filter lets through, so
    /// a foreign voice voice ID accepted (a TV) is never learned.
    private func observe(_ accepted: ScoredSpeechSegment, of segment: Segment) {
        guard !isOtherLanguage(segment) else {
            shared.withLock { $0.otherLanguageAdaptationsSkipped += 1 }
            return
        }
        onScoredSpeech?(accepted)
    }

    /// The segment as adaptive updates see it, when it was accepted on its
    /// own score and an observer wants it.
    private func acceptedSpeech(_ segment: Segment, verdict: SegmentVerdict, speech: Int64) -> ScoredSpeechSegment? {
        guard onScoredSpeech != nil, case .scored = verdict.basis, verdict.decision == .accept,
            let best = segment.best, best.decision == .accept, best.embedding != nil
        else { return nil }
        let count = Int(min(Int64(segment.samples.count), max(0, speech)))
        return ScoredSpeechSegment(
            segmentID: segment.id, score: best,
            speechDuration: .samples(speech, sampleRate: segment.sampleRate),
            audio: AudioFrame(
                samples: Array(segment.samples.prefix(count)), sampleRate: segment.sampleRate,
                sampleOffset: segment.start))
    }

    /// Whether `count` samples of speech from the segment's start need a
    /// new score: nothing scored yet, or the best score covers less than
    /// all of it by at least the re-score gain. (Once the segment has ended,
    /// ``Segment/best`` ignores scores that ran past its speech, so speech
    /// a hangover-tainted checkpoint covered is scored again on its own.)
    private func needsScore(_ segment: Segment, through count: Int64) -> Bool {
        guard let best = segment.best else { return true }
        let covered = best.audioDuration.sampleCount(sampleRate: segment.sampleRate)
        let gain = configuration.rescoreMinimumGain.sampleCount(sampleRate: segment.sampleRate)
        return count - covered >= max(gain, 1)
    }

    /// The first `count` samples of the segment's speech: from its buffer,
    /// or from the capture history when the buffer is behind.
    private func audio(of segment: Segment, count: Int64) -> AudioFrame? {
        let wanted = min(count, Int64(configuration.maximumBufferedSpeech.sampleCount(sampleRate: segment.sampleRate)))
        if Int64(segment.samples.count) < wanted, let history,
            let frame = history.history(in: segment.start..<(segment.start + wanted)),
            frame.sampleRate == segment.sampleRate, frame.sampleOffset == segment.start,
            frame.sampleCount > segment.samples.count
        {
            return frame
        }
        guard !segment.samples.isEmpty else { return nil }
        return AudioFrame(
            samples: Array(segment.samples.prefix(Int(wanted))), sampleRate: segment.sampleRate,
            sampleOffset: segment.start)
    }

    /// Whether the capture history still holds all of `range`.
    private func historyHolds(_ range: Range<Int64>) -> Bool {
        guard let history, let frame = history.history(in: range) else { return false }
        return frame.sampleOffset == range.lowerBound && frame.nextSampleOffset >= range.upperBound
    }

    /// Embeds and scores `audio` as speech of segment `id`.
    private func score(_ id: Int, _ audio: AudioFrame) async {
        segments[id]?.scoring += 1
        defer {
            segments[id]?.scoring -= 1
            notifyWaiters()
        }
        do {
            let result = try await verifier.verify(audio)
            shared.withLock { $0.scores += 1 }
            guard segments[id] != nil else { return }
            segments[id]?.scores.append(result)
            if segments[id]?.final == nil {
                segments[id]?.evidenceEnd = audio.nextSampleOffset
            }
        } catch {
            shared.withLock { $0.scoreFailures += 1 }
            Log.voiceID.error(
                "Scoring segment \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Language

    /// Identifies segment `id`'s language once its first window has been
    /// heard, unless voice ID has already rejected it.
    private func checkLanguageIfDue(_ id: Int) async {
        guard let filter = languageFilter, let segment = segments[id], !segment.hasEnded,
            segment.languageCheck == .notStarted, segment.decision != .reject
        else { return }
        let window = filter.configuration.window.sampleCount(sampleRate: segment.sampleRate)
        guard Int64(segment.samples.count) >= window else { return }
        await runLanguageCheck(id, startLanguageCheck(id, speech: window))
    }

    /// Claims segment `id`'s language check and returns the audio to check:
    /// the first `speech` samples, at most the window. `nil` when there is
    /// no filter, the check has started already, the filter is off or the
    /// speech is too short.
    private func startLanguageCheck(_ id: Int, speech: Int64) -> AudioFrame? {
        guard let filter = languageFilter, let segment = segments[id], segment.languageCheck == .notStarted else {
            return nil
        }
        let rate = segment.sampleRate
        let window = filter.configuration.window.sampleCount(sampleRate: rate)
        let count = min(speech, window)
        guard count >= filter.configuration.minimumSpeech.sampleCount(sampleRate: rate),
            filter.currentAllowedLanguages() != nil, let audio = audio(of: segment, count: count)
        else { return nil }
        segments[id]?.languageCheck = .running
        return audio
    }

    /// Runs the language check ``startLanguageCheck(_:speech:)`` claimed.
    private func runLanguageCheck(_ id: Int, _ audio: AudioFrame?) async {
        guard let audio, let filter = languageFilter else { return }
        defer {
            segments[id]?.languageCheck = .finished
            if let accepted = segments[id]?.awaitingLanguage, let segment = segments[id] {
                segments[id]?.awaitingLanguage = nil
                observe(accepted, of: segment)
            }
            notifyWaiters()
        }
        guard let allowed = filter.currentAllowedLanguages() else { return }
        do {
            let verdict = try await filter.check(audio, allowed: allowed)
            shared.withLock { $0.languageChecks += 1 }
            segments[id]?.language = verdict
            Log.voiceID.debug(
                """
                Segment \(id, privacy: .public) language: \(verdict.language.code, privacy: .public) \
                \(verdict.probability, format: .fixed(precision: 2), privacy: .public), \
                allowed \(verdict.allowedProbability, format: .fixed(precision: 3), privacy: .public)
                """
            )
        } catch {
            shared.withLock { $0.languageFailures += 1 }
            Log.voiceID.error(
                "Identifying the language of segment \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The language filter's verdict on segment `id` for an utterance that
    /// ends at `end`: waits for a check in flight, and checks a segment
    /// still being spoken that hasn't reached its window yet.
    private func languageVerdict(of id: Int, through end: Int64) async -> LanguageVerdict? {
        guard let filter = languageFilter, let segment = segments[id] else { return nil }
        switch segment.languageCheck {
        case .finished:
            return segment.language
        case .running:
            _ = await waitUntil(filter.configuration.decisionTimeout) {
                self.segments[id]?.languageCheck != .running
            }
            return segments[id]?.language
        case .notStarted:
            // An ended segment was checked when it ended, unless it was too
            // short, rejected, or the filter is off.
            guard !segment.hasEnded, segment.decision != .reject else { return nil }
            let audio = startLanguageCheck(id, speech: max(0, end - segment.start))
            await runLanguageCheck(id, audio)
            return segments[id]?.language
        }
    }

    /// The language filter's decision on an utterance voice ID would send,
    /// with the threshold for voice ID's decision on it (`speaker`).
    private func checkLanguage(
        of verdicts: [SegmentVerdict], range: Range<Int64>, speaker: SpeakerDecision
    ) async -> UtteranceLanguageCheck? {
        guard let filter = languageFilter, filter.currentAllowedLanguages() != nil else { return nil }
        let started = clock.uptime
        let threshold = filter.configuration.threshold(for: speaker)
        var parts: [UtteranceLanguageCheck.Part] = []
        for verdict in verdicts {
            let language = await languageVerdict(of: verdict.segmentID, through: range.upperBound)
            parts.append(
                .init(
                    segmentID: verdict.segmentID, verdict: language, speech: verdict.speechDuration,
                    threshold: threshold))
        }
        let decision = LanguageFilterRules.combine(
            parts.map { ($0.decision, $0.speech) }, minimumShare: filter.configuration.minimumOtherLanguageShare)
        return UtteranceLanguageCheck(
            decision: decision, parts: parts, threshold: threshold, delay: max(.zero, clock.uptime - started))
    }

    /// Whether `segment` is, so far, speech in another language.
    private func isOtherLanguage(_ segment: Segment) -> Bool {
        guard let filter = languageFilter, let language = segment.language else { return false }
        let threshold = filter.configuration.threshold(for: segment.decision ?? .uncertain)
        return language.decision(threshold: threshold) == .otherLanguage
    }

    // MARK: Verdicts

    private func scoredVerdict(of id: Int) -> SegmentVerdict? {
        guard let segment = segments[id], let best = segment.best else { return nil }
        return SegmentVerdict(
            segmentID: id, decision: best.decision, score: best.score, scoredDuration: best.audioDuration,
            speechDuration: best.audioDuration, basis: .scored)
    }

    private func unscoredVerdict(_ id: Int, basis: SegmentVerdict.Basis) -> SegmentVerdict {
        SegmentVerdict(
            segmentID: id, decision: .uncertain, score: nil, scoredDuration: .zero, speechDuration: .zero, basis: basis)
    }

    /// The decision a segment too short to score inherits from the one
    /// before it.
    private func inheritedVerdict(for id: Int) -> SegmentVerdict {
        guard let segment = segments[id] else { return unscoredVerdict(id, basis: .noRecentDecision) }
        var previous: (decision: SpeakerDecision, evidenceEnd: Int64)?
        var previousID: Int?
        if let index = order.firstIndex(of: id), index > 0, let before = segments[order[index - 1]],
            let decision = before.decision, let evidenceEnd = before.evidenceEnd
        {
            previous = (decision, evidenceEnd)
            previousID = before.id
        }
        let inherited = VerificationGateRules.inherited(
            previous: previous, start: segment.start, sampleRate: segment.sampleRate,
            window: configuration.inheritanceWindow)
        guard inherited.isInherited, let previousID, let previous else {
            return unscoredVerdict(id, basis: .noRecentDecision)
        }
        // The inherited decision rests on the same evidence as the previous
        // segment's, so a chain of short segments can't outlast it.
        segments[id]?.evidenceEnd = previous.evidenceEnd
        return SegmentVerdict(
            segmentID: id, decision: inherited.decision, score: nil, scoredDuration: .zero, speechDuration: .zero,
            basis: .inherited(from: previousID))
    }

    /// Segment `id`'s decision for the part of it that ends at `end`.
    private func verdict(of id: Int, for range: Range<Int64>) async -> SegmentVerdict? {
        guard var segment = segments[id] else { return nil }
        let rate = segment.sampleRate
        let cap = Int64(configuration.maximumBufferedSpeech.sampleCount(sampleRate: rate))
        let needed = min(range.upperBound, segment.start + cap)
        if !segment.hasEnded, segment.bufferedEnd < needed, !historyHolds(segment.start..<needed) {
            // VAD's audio stream is behind the transcriber: wait for it to
            // catch up, or for the segment to end.
            _ = await waitUntil(configuration.decisionTimeout) {
                guard let current = self.segments[id] else { return true }
                return current.hasEnded || current.bufferedEnd >= needed
            }
            guard let refreshed = segments[id] else { return nil }
            segment = refreshed
        }
        let covered =
            max(segment.start, range.lowerBound)..<min(segment.speechEnd ?? range.upperBound, range.upperBound)
        let speech = Duration.samples(Int64(max(0, covered.count)), sampleRate: rate)

        if segment.hasEnded {
            if segment.final == nil {
                // Its end-of-segment score is in flight.
                _ = await waitUntil(configuration.decisionTimeout) { self.segments[id]?.final != nil }
            }
            if let final = segments[id]?.final { return final.covering(speech) }
            return
                (scoredVerdict(of: id).map { verdict in
                    SegmentVerdict(
                        segmentID: id, decision: verdict.decision, score: verdict.score,
                        scoredDuration: verdict.scoredDuration, speechDuration: speech, basis: .timedOut)
                } ?? unscoredVerdict(id, basis: .timedOut)).covering(speech)
        }

        // Still open: the speech from the segment's start to the
        // utterance's end.
        let through = max(0, range.upperBound - segment.start)
        let minimum = configuration.minimumScoredSpeech.sampleCount(sampleRate: rate)
        if through < minimum {
            shared.withLock { $0.shortSegments += 1 }
            return inheritedVerdict(for: id).covering(speech)
        }
        if segment.scoring > 0 {
            _ = await waitUntil(configuration.decisionTimeout) { (self.segments[id]?.scoring ?? 0) == 0 }
        }
        if let current = segments[id], needsScore(current, through: through),
            let audio = audio(of: current, count: through)
        {
            await score(id, audio)
        }
        return (scoredVerdict(of: id) ?? unscoredVerdict(id, basis: .unscored)).covering(speech)
    }

    // MARK: Transcript

    /// Passes the transcriber's events through the gate: what the turn
    /// orchestrator should read instead of the transcriber's stream.
    ///
    /// Events keep their order; a final is held only until its decision is
    /// made. The returned stream finishes after the input does.
    public nonisolated func filter(_ events: AsyncStream<TranscriptEvent>) -> AsyncStream<TranscriptEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
        let task = Task {
            for await event in events {
                if let passed = await self.gate(event) {
                    continuation.yield(passed)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// One transcriber event through the gate: the event to pass on, or
    /// `nil` to drop it.
    ///
    /// Every final is passed on: with its decision when it is sent, and
    /// with `.reject` when it isn't (rejected, or uncertain and dropped by
    /// the policy), which the orchestrator ignores.
    public func gate(_ event: TranscriptEvent) async -> TranscriptEvent? {
        switch event {
        case .partial(_, let range):
            let samples = Self.sampleRange(of: range)
            let latest = order.reversed().lazy.compactMap { self.segments[$0] }.first { $0.contains(samples) }
            if let latest, latest.decision == .reject || isOtherLanguage(latest) {
                shared.withLock { $0.suppressedPartials += 1 }
                return nil
            }
            return event
        case .final(let utterance):
            let gated = await decide(utterance)
            // A final that isn't sent still goes on, marked `reject`: the
            // orchestrator ignores it (never sent, never stored) but it ends
            // the utterance in progress, clearing the partial text and the
            // `userSpeaking` state the speech's partials started.
            return .final(utterance.withSpeakerDecision(gated.disposition.isCommitted ? gated.decision : .reject))
        case .refined(let utterance):
            guard committedFinals.contains(utterance.id) else { return nil }
            return .refined(utterance)
        }
    }

    /// Decides a final utterance: which segments it covers, their decisions,
    /// and whether it is sent.
    public func decide(_ utterance: Utterance) async -> GatedUtterance {
        let receivedAt = clock.uptime
        let hold = signposter.beginInterval(.voiceIDGate)
        let range = Self.sampleRange(of: utterance.timeRange)
        // The transcriber's VAD stream can be ahead of the gate's.
        _ = await waitUntil(configuration.segmentArrivalTimeout) { !self.segmentIDs(overlapping: range).isEmpty }

        var verdicts: [SegmentVerdict] = []
        for id in segmentIDs(overlapping: range) {
            if let verdict = await verdict(of: id, for: range) {
                verdicts.append(verdict)
            }
        }
        let decision = VerificationGateRules.combine(
            verdicts, minorityShare: configuration.mixedSpeechMinorityShare,
            unattributedAllowance: configuration.minimumScoredSpeech)
        var disposition = VerificationGateRules.disposition(
            for: decision, duration: utterance.duration, isTurnActive: turnActivity.isActive,
            policy: configuration.uncertainPolicy)
        // Only speech voice ID would send is worth identifying.
        let language =
            disposition.isCommitted ? await checkLanguage(of: verdicts, range: range, speaker: decision) : nil
        if language?.decision == .otherLanguage { disposition = .otherLanguage }
        let delay = max(.zero, clock.uptime - receivedAt)
        hold.end(message: disposition.rawValue)
        let gated = GatedUtterance(
            utterance: utterance, decision: decision, disposition: disposition, segments: verdicts, delay: delay,
            language: language)

        if disposition == .accepted {
            // Only the owner's speech (or Grok's reply) keeps a turn active:
            // uncertain speech sent in an active turn doesn't extend it, so
            // a podcast can't keep itself flowing to Grok.
            turnActivity.userUtteranceCommitted()
        }
        if disposition.isCommitted {
            committedFinals.append(utterance.id)
            if committedFinals.count > 256 { committedFinals.removeFirst(committedFinals.count - 256) }
        }
        shared.withLock { statistics in
            statistics.utterances[decision, default: 0] += 1
            if disposition.isCommitted { statistics.committed += 1 } else { statistics.discarded += 1 }
            statistics.lastDelay = delay
            statistics.longestDelay = max(statistics.longestDelay, delay)
            statistics.totalDelay += delay
            if let language {
                if disposition == .otherLanguage { statistics.otherLanguageUtterances += 1 }
                statistics.lastLanguageDelay = language.delay
                statistics.longestLanguageDelay = max(statistics.longestLanguageDelay, language.delay)
            }
        }
        let score = gated.representativeScore.map { String(format: "%.3f", $0) } ?? "–"
        let spoken = language?.language.map { " \($0.language.code) \(String(format: "%.2f", $0.probability))" } ?? ""
        Log.voiceID.notice(
            """
            Utterance \(disposition.rawValue, privacy: .public) (\(decision.rawValue, privacy: .public), \
            score \(score, privacy: .public)\(spoken, privacy: .public), \(verdicts.count, privacy: .public) segment(s), \
            held \(delay.milliseconds, format: .fixed(precision: 1), privacy: .public) ms): \
            \(utterance.text, privacy: .private)
            """
        )
        verdictContinuation.yield(gated)
        return gated
    }

    // MARK: Barge-in

    /// Voice ID's verdict on the speech starting at `onset`, for barge-in:
    /// the segment's decision as soon as it has one (its 1.5 s score, or
    /// its end for shorter speech), waiting at most
    /// ``VerificationGateConfiguration/bargeInDecisionTimeout``, after which
    /// it is `uncertain`. Only `reject` stops a barge-in.
    public func bargeInDecision(for onset: SpeechOnset) async -> SpeakerDecision? {
        shared.withLock { $0.bargeInQueries += 1 }
        let id = onset.segmentID
        let decided = await waitUntil(configuration.bargeInDecisionTimeout) { self.segments[id]?.decision != nil }
        guard decided, let decision = segments[id]?.decision else {
            shared.withLock { $0.bargeInTimeouts += 1 }
            return .uncertain
        }
        return decision
    }

    /// The decision so far on VAD segment `id`, if it has one.
    public func decision(ofSegment id: Int) -> SpeakerDecision? {
        segments[id]?.decision
    }

    /// The language filter's verdict on VAD segment `id`, once it has one.
    public func languageVerdict(ofSegment id: Int) -> LanguageVerdict? {
        segments[id]?.language
    }

    /// Forgets every segment, for a new conversation.
    public func reset() {
        segments.removeAll()
        order.removeAll()
        openSegmentID = nil
        splitTail = nil
        committedFinals.removeAll()
        turnActivity.reset()
        notifyWaiters()
    }

    // MARK: Helpers

    private func segmentIDs(overlapping range: Range<Int64>) -> [Int] {
        order.filter { segments[$0]?.contains(range) ?? false }
    }

    private func forgetOldSegments() {
        while order.count > configuration.retainedSegments {
            let oldest = order.removeFirst()
            segments[oldest] = nil
        }
    }

    /// Absolute 16 kHz sample offsets of `range`, at least one sample long.
    static func sampleRange(of range: TimeRange) -> Range<Int64> {
        let rate = AudioFrame.captureSampleRate
        let start = max(0, range.start.sampleCount(sampleRate: rate))
        let end = max(start + 1, range.end.sampleCount(sampleRate: rate))
        return start..<end
    }

    private static func describe(_ verdict: SegmentVerdict) -> String {
        switch verdict.basis {
        case .scored:
            let score = verdict.score.map { String(format: "%.3f", $0) } ?? "–"
            return ", score \(score) over \(Int(verdict.scoredDuration.milliseconds)) ms"
        case .inherited(let from): return ", inherited from segment \(from)"
        case .noRecentDecision: return ", too short and nothing recent to inherit"
        case .unscored: return ", no score"
        case .timedOut: return ", timed out"
        }
    }

    /// Waits until `condition` holds (rechecked whenever the gate's state
    /// changes), for at most `limit`. Returns whether it holds.
    private func waitUntil(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = clock.uptime + limit
        while !condition() {
            let remaining = deadline - clock.uptime
            guard remaining > .zero, !Task.isCancelled else { return false }
            nextWaiterID &+= 1
            let id = nextWaiterID
            let clock = clock
            let timer = Task { [weak self] in
                try? await clock.sleep(until: deadline)
                await self?.wake(id)
            }
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
            timer.cancel()
        }
        return true
    }

    private func wake(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func notifyWaiters() {
        guard !waiters.isEmpty else { return }
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }
}

extension Utterance {
    /// This utterance with voice ID's verdict.
    func withSpeakerDecision(_ decision: SpeakerDecision) -> Utterance {
        Utterance(
            id: id, conversationID: conversationID, speaker: speaker, text: text, timeRange: timeRange,
            startedAt: startedAt, speakerDecision: decision)
    }
}
