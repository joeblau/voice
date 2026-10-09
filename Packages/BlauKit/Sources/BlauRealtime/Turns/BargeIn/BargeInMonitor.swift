import Accelerate
import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation

/// Barge-in (#37): when the user starts talking over Grok, stop the reply
/// at once and cut Grok's memory of it to what was actually heard.
///
/// ```swift
/// let monitor = BargeInMonitor(
///     target: orchestrator,          // TurnOrchestrator
///     playback: audio.player,        // StreamingAudioPlayer: the grace period
///     microphone: audio.capture.hub) // CaptureHub: the level checks
/// let events = vad.events()          // subscribe before VAD runs
/// Task { await monitor.run(events) }
/// ```
///
/// **Trigger.** A confirmed VAD onset (`VoiceActivityEvent.speechStarted`,
/// #28) on the echo-cancelled microphone while the orchestrator is
/// `agentSpeaking`. Speech that is already under way when Grok starts
/// speaking (it began after Grok last stopped speaking, while Grok was
/// listening or thinking, and its segment is still open) is judged when
/// Grok starts (``BargeInTarget/agentSpeakingChanges()``), as speech that
/// began in the grace period; speech that ends before then is left to the
/// final utterance, which interrupts the same way (#36). Speech that began
/// while Grok was still speaking, and that VAD confirmed only after Grok
/// stopped (a tool round's filler), is never carried over: it may be
/// Grok's own leak, and Grok would barge in on itself. A continuation onset
/// (VAD splitting a segment over its maximum duration) is the same speech
/// carrying on, not a new onset, and never barges in by itself.
///
/// **Echo guard.** Voice processing removes most of the agent's voice from
/// the microphone, but not all of it, and least while its echo canceller
/// converges at the start of playback. An onset barges in only if:
///
/// 1. *Grace period.* It didn't start in the first
///    ``BargeInConfiguration/playbackGracePeriod`` of the agent's audio, or,
///    if it did, ``BargeInConfiguration/speechAfterGrace`` more speech is
///    heard after the grace period while the segment is still open. Speech
///    that started before the agent's audio can't be its echo. The grace
///    period runs from when the agent's audio last started after silence,
///    not from each item.
/// 2. *Level.* The speech (from the onset, or from the end of the grace
///    period) is at least ``BargeInConfiguration/minimumSpeechLevel``, and
///    at least ``BargeInConfiguration/echoMargin`` louder than the peaks
///    (90th percentile of 20 ms pieces) of the
///    ``BargeInConfiguration/referenceWindow`` before the onset, where the
///    microphone hears whatever echo leaks while Grok talks. The window
///    doesn't reach back before the agent's audio started: there is no leak
///    before it, only the user's own earlier speech. Speech already under
///    way when Grok started must instead stay within the margin of the
///    user's own level before Grok spoke, so a leak holding the segment
///    open after the user stopped doesn't barge in.
/// 3. *Speaker.* The ``BargeInSpeakerGate`` (voice ID, #47), when there is
///    one, didn't `reject` the speaker. `uncertain` still interrupts.
///
/// **Action.** ``TurnOrchestrator/bargeIn(_:)``: flush playback first (the
/// speaker is silent one render cycle later), then `response.cancel` if the
/// reply is still being generated and `conversation.item.truncate` at the
/// played milliseconds (or `conversation.item.delete` if none of it was
/// heard).
public actor BargeInMonitor {
    public nonisolated let configuration: BargeInConfiguration

    private let target: any BargeInTarget
    private let playback: (any AgentPlaybackObserving)?
    private let microphone: (any CaptureFrameSource)?
    private let speakerGate: (any BargeInSpeakerGate)?
    private let clock: any BlauClock
    private let signposter: Signposter

    /// Segments VAD has opened and not yet ended.
    private var openSegments: Set<Int> = []
    /// Speech held back by the grace period.
    private var pending: Pending?
    private var nextHoldID: UInt64 = 0
    /// The latest onset that came while Grok wasn't speaking and whose
    /// speech began after Grok last stopped, until its segment ends: judged
    /// if Grok starts speaking over it. `began` is when its speech began
    /// (the clock's uptime); for a continuation, when the speech it carries
    /// on began.
    private var unjudged: (onset: SpeechOnset, receivedAt: Duration, began: Duration)?
    /// When the latest stretch of speech began (the clock's uptime): the
    /// start of the last onset that wasn't a continuation.
    private var speechBegan: Duration?
    /// The last ``agentSpeakingChanged(_:)`` value.
    private var agentSpeaking = false
    /// When Grok last stopped speaking (the clock's uptime), as
    /// ``agentSpeakingChanged(_:)`` was told.
    private var stoppedSpeakingAt: Duration?
    public private(set) var statistics = BargeInStatistics()

    private struct Pending {
        let id: UInt64
        let segmentID: Int
        let task: Task<Void, Never>
    }

    /// One onset being judged.
    private struct Candidate {
        let onset: SpeechOnset
        /// When the onset reached the monitor (with `onset.detectedAt`, it
        /// places the clock on the capture timeline).
        let receivedAt: Duration
        /// Where the speech that counts starts (capture samples): the onset,
        /// or the end of the grace period for speech that began inside it.
        var countsFrom: Int64
        /// The speech began inside the grace period.
        let isSuspect: Bool
        /// Where the agent's audio started (capture samples), when known.
        var playbackStart: Int64?
        /// For speech already under way when Grok started speaking: where
        /// (capture samples) Grok started.
        var carriedOverAt: Int64?
    }

    /// Whether speech is held back by the grace period. For tests.
    var hasPendingHold: Bool { pending != nil }
    /// The segment of speech waiting for Grok to start speaking. For tests.
    var unjudgedSegment: Int? { unjudged?.onset.segmentID }

    /// - Parameters:
    ///   - target: What to interrupt: the turn orchestrator.
    ///   - playback: The player, for the grace period. Without it there is
    ///     no grace period.
    ///   - microphone: The capture history, for the level checks. Without it
    ///     they are skipped.
    ///   - speakerGate: Voice ID's verdict (#47). Without it any speaker
    ///     barges in.
    ///   - configuration: The echo guard's tuning.
    ///   - clock: Times the grace period and the reaction time.
    ///   - signposter: Where `realtime.bargeInSuppressed` goes.
    public init(
        target: any BargeInTarget,
        playback: (any AgentPlaybackObserving)? = nil,
        microphone: (any CaptureFrameSource)? = nil,
        speakerGate: (any BargeInSpeakerGate)? = nil,
        configuration: BargeInConfiguration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.realtime
    ) {
        self.target = target
        self.playback = playback
        self.microphone = microphone
        self.speakerGate = speakerGate
        self.configuration = configuration
        self.clock = clock
        self.signposter = signposter
    }

    deinit {
        pending?.task.cancel()
    }

    /// Handles VAD's events, and the target's
    /// ``BargeInTarget/agentSpeakingChanges()``, until the VAD stream
    /// finishes or the task is cancelled. Subscribe (`vad.events()`) before
    /// VAD sees audio.
    public func run(_ events: AsyncStream<VoiceActivityEvent>) async {
        let changes = target.agentSpeakingChanges()
        let watcher = Task { [weak self] in
            for await isSpeaking in changes {
                await self?.agentSpeakingChanged(isSpeaking)
            }
        }
        for await event in events {
            await handle(event)
        }
        watcher.cancel()
        pending?.task.cancel()
        pending = nil
        unjudged = nil
        speechBegan = nil
        openSegments.removeAll()
    }

    /// Handles one VAD event. Returns what became of a speech onset (`nil`
    /// for a segment's end).
    @discardableResult
    public func handle(_ event: VoiceActivityEvent) async -> BargeInOutcome? {
        switch event {
        case .speechStarted(let onset):
            openSegments.insert(onset.segmentID)
            return await speechStarted(onset)
        case .speechEnded(let segment):
            openSegments.remove(segment.id)
            if unjudged?.onset.segmentID == segment.id {
                unjudged = nil
            }
            if let pending, pending.segmentID == segment.id {
                // Over before enough of it was heard after the grace period.
                pending.task.cancel()
                self.pending = nil
                suppress(.playbackGrace, segment: segment.id, detail: "ended during the grace period")
            }
            return nil
        }
    }

    // MARK: Deciding

    private func speechStarted(_ onset: SpeechOnset) async -> BargeInOutcome {
        // VAD's forced split of a segment over its maximum duration: the
        // same speech carrying on, whose real onset was already judged (or
        // came before Grok spoke). Judging it again would give the agent's
        // own leak, holding a segment open through a long reply, a fresh
        // chance to barge in at every split, with a measured span that can
        // be empty. Its ID is still tracked as open (`handle`). While Grok
        // isn't speaking it stands for the speech carrying on, in case Grok
        // starts over it.
        let receivedAt = clock.uptime
        if onset.isContinuation {
            // The speech it carries on began when its real onset did.
            let began = speechBegan ?? Self.began(onset, receivedAt: receivedAt)
            if !(await target.isAgentSpeaking) {
                carryOver(onset, receivedAt: receivedAt, began: began)
            }
            return .continuation
        }
        let began = Self.began(onset, receivedAt: receivedAt)
        speechBegan = began
        pending?.task.cancel()
        pending = nil
        unjudged = nil
        guard await target.isAgentSpeaking else {
            carryOver(onset, receivedAt: receivedAt, began: began)
            return .agentNotSpeaking
        }
        statistics.onsetsWhileSpeaking += 1

        var countsFrom = onset.startOffset
        var isSuspect = false
        var playbackStart: Int64?
        if let audible = playback?.audibleDuration {
            // VAD decided at `detectedAt`, which is (near enough) now on the
            // capture timeline, so playback began `audible` before it.
            let start = onset.detectedAt - audible.sampleCount(sampleRate: onset.sampleRate)
            let graceEnd = start + configuration.playbackGracePeriod.sampleCount(sampleRate: onset.sampleRate)
            playbackStart = start
            if onset.startOffset >= start, onset.startOffset < graceEnd {
                countsFrom = graceEnd
                isSuspect = true
            }
        }
        return await evaluate(
            Candidate(
                onset: onset, receivedAt: receivedAt, countsFrom: countsFrom, isSuspect: isSuspect,
                playbackStart: playbackStart),
            startedAt: receivedAt)
    }

    /// When the speech of `onset`, received at `receivedAt`, began: VAD
    /// decided at `detectedAt`, which is (near enough) when the onset
    /// reached the monitor.
    private static func began(_ onset: SpeechOnset, receivedAt: Duration) -> Duration {
        receivedAt - onset.detectionLatency
    }

    /// Notes `onset`, which came while Grok wasn't speaking, to be judged if
    /// Grok starts speaking over it, unless its speech began before Grok
    /// last stopped. Such speech may be Grok's own leak (a filler, or the
    /// end of a reply, that VAD confirmed only once the player went idle);
    /// carried over, the leak would stand for "the user's own level before
    /// Grok spoke", and the next audio's leak, never `echoMargin` under it,
    /// would barge in on Grok.
    private func carryOver(_ onset: SpeechOnset, receivedAt: Duration, began: Duration) {
        if let stoppedSpeakingAt, began < stoppedSpeakingAt {
            unjudged = nil
            Log.realtime.info(
                "Segment \(onset.segmentID, privacy: .public) began while Grok was speaking; not carrying it over")
            return
        }
        unjudged = (onset, receivedAt, began)
    }

    /// Tells the monitor whether Grok is speaking; ``run(_:)`` calls it for
    /// each of the target's ``BargeInTarget/agentSpeakingChanges()``.
    ///
    /// When Grok starts speaking while the segment of an onset that came
    /// before is still open (the user carried on talking through Grok's
    /// thinking), and that speech began after Grok last stopped speaking,
    /// it is judged as if it began in the grace period:
    /// it barges in once ``BargeInConfiguration/speechAfterGrace`` of it has
    /// been heard after the grace period with the segment still open, it is
    /// loud enough, and it is within ``BargeInConfiguration/echoMargin`` of
    /// the user's own level before Grok spoke.
    ///
    /// - Returns: What became of that speech, or `nil` when there was none.
    @discardableResult
    public func agentSpeakingChanged(_ isSpeaking: Bool) async -> BargeInOutcome? {
        let started = isSpeaking && !agentSpeaking
        if !isSpeaking, agentSpeaking {
            // Speech that began before now may be Grok's own leak. This
            // change can reach the monitor after VAD's onset did, so an
            // onset already noted is dropped here too.
            let now = clock.uptime
            stoppedSpeakingAt = now
            if let carried = unjudged, carried.began < now {
                unjudged = nil
            }
        }
        agentSpeaking = isSpeaking
        guard started, let carried = unjudged, openSegments.contains(carried.onset.segmentID) else { return nil }
        unjudged = nil
        let now = clock.uptime
        let onset = carried.onset
        guard await target.isAgentSpeaking else { return .agentNotSpeaking }
        statistics.onsetsWhileSpeaking += 1
        // Where the capture is now: Grok's audio starts here at the
        // earliest (it is still filling the jitter buffer).
        let startedAt =
            onset.detectedAt + max(.zero, now - carried.receivedAt).sampleCount(sampleRate: onset.sampleRate)
        let grace = configuration.playbackGracePeriod.sampleCount(sampleRate: onset.sampleRate)
        Log.realtime.info(
            "Grok started speaking over segment \(onset.segmentID, privacy: .public), already under way; judging it")
        return await evaluate(
            Candidate(
                onset: onset, receivedAt: carried.receivedAt, countsFrom: startedAt + grace, isSuspect: true,
                playbackStart: startedAt, carriedOverAt: startedAt),
            startedAt: now)
    }

    /// Runs the checks on `candidate`, deferring speech from the grace
    /// period until enough of it after the grace period has been heard.
    private func evaluate(_ candidate: Candidate, startedAt: Duration) async -> BargeInOutcome {
        var candidate = candidate
        let onset = candidate.onset
        var speechEnd = onset.detectedAt
        if candidate.isSuspect {
            let position = capturePosition(of: candidate)
            if candidate.carriedOverAt != nil, let audible = playback?.audibleDuration {
                // Grok's audio has started by now: the grace period runs
                // from where it actually did.
                let start = max(
                    candidate.playbackStart ?? 0, position - audible.sampleCount(sampleRate: onset.sampleRate))
                candidate.playbackStart = start
                candidate.countsFrom = max(
                    candidate.countsFrom,
                    start + configuration.playbackGracePeriod.sampleCount(sampleRate: onset.sampleRate))
            }
            let needed =
                candidate.countsFrom + configuration.speechAfterGrace.sampleCount(sampleRate: onset.sampleRate)
            if position < needed {
                hold(candidate, for: .samples(needed - position, sampleRate: onset.sampleRate))
                return .deferred
            }
            guard openSegments.contains(onset.segmentID) else {
                return suppress(.playbackGrace, segment: onset.segmentID, detail: "ended during the grace period")
            }
            speechEnd = position
        }

        if let microphone, let suppression = echoCheck(candidate, through: speechEnd, microphone: microphone) {
            return suppression
        }

        var decision: SpeakerDecision?
        if let speakerGate {
            decision = await speakerGate.bargeInDecision(for: onset)
            if decision == .reject {
                return suppress(.otherSpeaker, segment: onset.segmentID, detail: "voice ID rejected the speaker")
            }
        }

        let trigger = BargeInTrigger(onset: onset, receivedAt: startedAt, speakerDecision: decision)
        guard let record = await target.bargeIn(trigger) else { return .agentNotSpeaking }
        statistics.bargeIns += 1
        Log.realtime.notice(
            """
            Barge-in on segment \(onset.segmentID, privacy: .public): playback flushed \
            \(record.reactionTime.milliseconds, format: .fixed(precision: 1), privacy: .public) ms after the onset \
            reached the monitor (VAD confirmed it \(onset.detectionLatency.milliseconds, format: .fixed(precision: 0), privacy: .public) ms after it began)
            """
        )
        return .bargedIn(record)
    }

    private func hold(_ candidate: Candidate, for delay: Duration) {
        pending?.task.cancel()
        let clock = clock
        let id = nextHoldID
        nextHoldID += 1
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.graceEnded(candidate, hold: id)
        }
        pending = Pending(id: id, segmentID: candidate.onset.segmentID, task: task)
        Log.realtime.info(
            "Speech on segment \(candidate.onset.segmentID, privacy: .public) began in the playback grace period; holding it"
        )
    }

    private func graceEnded(_ candidate: Candidate, hold id: UInt64) async {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        guard await target.isAgentSpeaking else { return }
        _ = await evaluate(candidate, startedAt: clock.uptime)
    }

    /// The capture position now, estimated from where VAD was when it
    /// reported the onset.
    private func capturePosition(of candidate: Candidate) -> Int64 {
        let elapsed = max(.zero, clock.uptime - candidate.receivedAt)
        return candidate.onset.detectedAt + elapsed.sampleCount(sampleRate: candidate.onset.sampleRate)
    }

    // MARK: Level checks

    /// The shortest speech the level checks judge. Speech the history no
    /// longer holds is let through; a shorter span the history does hold is
    /// suppressed, since it can't be told from the leak (fail closed).
    static let minimumMeasuredSamples = 160

    private func echoCheck(
        _ candidate: Candidate, through end: Int64, microphone: any CaptureFrameSource
    ) -> BargeInOutcome? {
        let onset = candidate.onset
        // An empty span is probed one sample long, so the history still says
        // whether it holds this stretch of audio at all.
        let span = candidate.countsFrom..<max(end, candidate.countsFrom + 1)
        guard let speech = microphone.history(in: span) else { return nil }
        guard end > candidate.countsFrom, speech.sampleCount >= Self.minimumMeasuredSamples else {
            return suppress(
                .echo, segment: onset.segmentID,
                detail: "only \(max(0, end - candidate.countsFrom)) samples of speech to judge")
        }
        let level = Self.decibels(speech.rms)
        if let minimum = configuration.minimumSpeechLevel, level < minimum {
            return suppress(
                .tooQuiet, segment: onset.segmentID,
                detail: "speech at \(Self.format(level)) dBFS, below \(Self.format(minimum))")
        }
        guard let margin = configuration.echoMargin else { return nil }
        let window = configuration.referenceWindow.sampleCount(sampleRate: onset.sampleRate)
        if let carriedOverAt = candidate.carriedOverAt {
            // The speech began after Grok last stopped speaking
            // (`carryOver`) and was under way before Grok spoke again, so
            // it isn't Grok's echo; the question is whether the user is still
            // talking, or only the leak holds the segment open. The user's
            // own level before Grok spoke tells: the leak sits well under it.
            let start = max(onset.startOffset, carriedOverAt - window)
            guard start < carriedOverAt, let user = microphone.history(in: start..<carriedOverAt),
                user.sampleCount >= Self.minimumMeasuredSamples
            else {
                return suppress(
                    .echo, segment: onset.segmentID, detail: "none of the speech before Grok spoke to compare with")
            }
            let userLevel = Self.referenceLevel(of: user)
            if level < userLevel - margin {
                return suppress(
                    .echo, segment: onset.segmentID,
                    detail:
                        "speech at \(Self.format(level)) dBFS, more than \(Self.format(margin)) dB under the user's \(Self.format(userLevel)) dBFS before Grok spoke"
                )
            }
            return nil
        }
        // No leak before the agent's audio started: earlier sound is the
        // user's own (their last utterance, an "uh"), not a reference.
        let start = max(0, onset.startOffset - window, candidate.playbackStart ?? 0)
        if start < onset.startOffset, let reference = microphone.history(in: start..<onset.startOffset),
            reference.sampleCount >= Self.minimumMeasuredSamples
        {
            let referenceLevel = Self.referenceLevel(of: reference)
            if level - referenceLevel < margin {
                return suppress(
                    .echo, segment: onset.segmentID,
                    detail:
                        "speech at \(Self.format(level)) dBFS, only \(Self.format(level - referenceLevel)) dB over the \(Self.format(referenceLevel)) dBFS before it"
                )
            }
        }
        return nil
    }

    /// RMS in dBFS, floored at -160.
    static func decibels(_ rms: Float) -> Float {
        rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }

    /// The peak level of `frame`'s 20 ms pieces, in dBFS: their 90th
    /// percentile.
    ///
    /// The echo leak is the agent's speech, which spends half its time or
    /// more in pauses and weak segments, while VAD trips on its loud
    /// syllables. So the speech is compared with the leak's syllables, not
    /// its typical level: a median would sit at the pauses (near the noise
    /// floor) and let a leaked syllable through as "louder than before".
    /// The 90th percentile rather than the maximum, so one click doesn't
    /// set it.
    static func referenceLevel(of frame: AudioFrame) -> Float {
        let piece = max(1, frame.sampleRate / 50)
        var levels: [Float] = []
        levels.reserveCapacity(frame.sampleCount / piece + 1)
        var start = 0
        while start < frame.sampleCount {
            let end = min(frame.sampleCount, start + piece)
            levels.append(decibels(vDSP.rootMeanSquare(frame.samples[start..<end])))
            start = end
        }
        levels.sort()
        return levels.isEmpty ? -160 : levels[min(levels.count - 1, levels.count * 9 / 10)]
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.1f", value)
    }

    @discardableResult
    private func suppress(_ reason: BargeInSuppression, segment: Int, detail: String) -> BargeInOutcome {
        statistics.suppressed[reason, default: 0] += 1
        signposter.event("realtime.bargeInSuppressed")
        Log.realtime.info(
            "No barge-in on segment \(segment, privacy: .public) (\(reason.rawValue, privacy: .public)): \(detail, privacy: .public)"
        )
        return .suppressed(reason)
    }
}
