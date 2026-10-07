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
/// `agentSpeaking`. Speech while Grok is still thinking is left to the
/// final utterance, which interrupts the same way (#36).
///
/// **Echo guard.** Voice processing removes most of the agent's voice from
/// the microphone, but not all of it, and least while its echo canceller
/// converges at the start of playback. An onset barges in only if:
///
/// 1. *Grace period.* It didn't start in the first
///    ``BargeInConfiguration/playbackGracePeriod`` of the agent's audio, or,
///    if it did, ``BargeInConfiguration/speechAfterGrace`` more speech is
///    heard after the grace period while the segment is still open. Speech
///    that started before the agent's audio can't be its echo.
/// 2. *Level.* The speech (from the onset, or from the end of the grace
///    period) is at least ``BargeInConfiguration/minimumSpeechLevel``, and
///    at least ``BargeInConfiguration/echoMargin`` louder than the peaks
///    (90th percentile of 20 ms pieces) of the
///    ``BargeInConfiguration/referenceWindow`` before the onset, where the
///    microphone hears whatever echo leaks while Grok talks.
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
    public private(set) var statistics = BargeInStatistics()

    private struct Pending {
        let segmentID: Int
        let task: Task<Void, Never>
    }

    /// One onset being judged.
    private struct Candidate {
        let onset: SpeechOnset
        /// When the onset reached the monitor.
        let receivedAt: Duration
        /// Where the speech that counts starts (capture samples): the onset,
        /// or the end of the grace period for speech that began inside it.
        let countsFrom: Int64
        /// The speech began inside the grace period.
        let isSuspect: Bool
    }

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

    /// Handles VAD's events until the stream finishes or the task is
    /// cancelled. Subscribe (`vad.events()`) before VAD sees audio.
    public func run(_ events: AsyncStream<VoiceActivityEvent>) async {
        for await event in events {
            await handle(event)
        }
        pending?.task.cancel()
        pending = nil
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
        let receivedAt = clock.uptime
        pending?.task.cancel()
        pending = nil
        guard await target.isAgentSpeaking else { return .agentNotSpeaking }
        statistics.onsetsWhileSpeaking += 1

        var countsFrom = onset.startOffset
        var isSuspect = false
        if let audible = playback?.audibleDuration, configuration.playbackGracePeriod > .zero {
            // VAD decided at `detectedAt`, which is (near enough) now on the
            // capture timeline, so playback began `audible` before it.
            let playbackStart = onset.detectedAt - audible.sampleCount(sampleRate: onset.sampleRate)
            let graceEnd = playbackStart + configuration.playbackGracePeriod.sampleCount(sampleRate: onset.sampleRate)
            if onset.startOffset >= playbackStart, onset.startOffset < graceEnd {
                countsFrom = graceEnd
                isSuspect = true
            }
        }
        return await evaluate(
            Candidate(onset: onset, receivedAt: receivedAt, countsFrom: countsFrom, isSuspect: isSuspect),
            startedAt: receivedAt)
    }

    /// Runs the checks on `candidate`, deferring speech from the grace
    /// period until enough of it after the grace period has been heard.
    private func evaluate(_ candidate: Candidate, startedAt: Duration) async -> BargeInOutcome {
        let onset = candidate.onset
        var speechEnd = onset.detectedAt
        if candidate.isSuspect {
            let position = capturePosition(of: candidate)
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
        let clock = clock
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.graceEnded(candidate)
        }
        pending = Pending(segmentID: candidate.onset.segmentID, task: task)
        Log.realtime.info(
            "Speech on segment \(candidate.onset.segmentID, privacy: .public) began in the playback grace period; holding it"
        )
    }

    private func graceEnded(_ candidate: Candidate) async {
        guard let pending, pending.segmentID == candidate.onset.segmentID else { return }
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

    /// The shortest speech the level checks judge; less (out of the
    /// history, say) is let through.
    static let minimumMeasuredSamples = 160

    private func echoCheck(
        _ candidate: Candidate, through end: Int64, microphone: any CaptureFrameSource
    ) -> BargeInOutcome? {
        let onset = candidate.onset
        guard end > candidate.countsFrom, let speech = microphone.history(in: candidate.countsFrom..<end),
            speech.sampleCount >= Self.minimumMeasuredSamples
        else { return nil }
        let level = Self.decibels(speech.rms)
        if let minimum = configuration.minimumSpeechLevel, level < minimum {
            return suppress(
                .tooQuiet, segment: onset.segmentID,
                detail: "speech at \(Self.format(level)) dBFS, below \(Self.format(minimum))")
        }
        if let margin = configuration.echoMargin {
            let window = configuration.referenceWindow.sampleCount(sampleRate: onset.sampleRate)
            let start = max(0, onset.startOffset - window)
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
