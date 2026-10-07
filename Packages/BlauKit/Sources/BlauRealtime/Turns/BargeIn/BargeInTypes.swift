import BlauAudio
import BlauCore
import Foundation

// MARK: - Trigger and record

/// Why the user is barging in: confirmed speech on the echo-cancelled
/// microphone while Grok speaks (#37).
public struct BargeInTrigger: Sendable, Hashable {
    /// The VAD onset of the user's speech.
    public var onset: SpeechOnset
    /// When the speech onset reached ``BargeInMonitor`` (its clock's
    /// uptime), or, for speech held back by the playback grace period, when
    /// the hold ended: the start of the "interrupt → silence" span, so the
    /// echo checks and the speaker gate count towards it.
    public var receivedAt: Duration
    /// The voice ID verdict on the speech, when a speaker gate gave one.
    public var speakerDecision: SpeakerDecision?

    public init(onset: SpeechOnset, receivedAt: Duration, speakerDecision: SpeakerDecision? = nil) {
        self.onset = onset
        self.receivedAt = receivedAt
        self.speakerDecision = speakerDecision
    }
}

/// What one barge-in cut, as ``TurnOrchestrator/bargeIn(_:)`` did it.
public struct BargeInRecord: Sendable, Hashable {
    /// One agent item that was playing or queued when the user barged in.
    public struct CutItem: Sendable, Hashable {
        /// The conversation item (`item_id`).
        public var itemID: String
        /// The stored agent utterance, or `nil` when none of the item was
        /// heard (it is removed from Grok's history and not stored).
        public var utteranceID: UUID?
        /// `audio_end_ms`: how much of it the user heard.
        public var heardMilliseconds: Int
        /// How much of it had arrived.
        public var receivedMilliseconds: Int

        public init(itemID: String, utteranceID: UUID?, heardMilliseconds: Int, receivedMilliseconds: Int) {
            self.itemID = itemID
            self.utteranceID = utteranceID
            self.heardMilliseconds = heardMilliseconds
            self.receivedMilliseconds = receivedMilliseconds
        }
    }

    /// The turn whose reply was cut.
    public var turn: Int
    public var trigger: BargeInTrigger
    /// The agent items cut, in order.
    public var cut: [CutItem]
    /// Whether the response was still being generated (`response.cancel`
    /// went out), rather than only still playing.
    public var cancelledResponse: Bool
    /// Speech onset received (``BargeInTrigger/receivedAt``) → playback
    /// flushed. The speaker is silent one render
    /// cycle (≤ 20 ms, with a 5 ms fade) after the flush.
    public var reactionTime: Duration

    public init(
        turn: Int, trigger: BargeInTrigger, cut: [CutItem], cancelledResponse: Bool, reactionTime: Duration
    ) {
        self.turn = turn
        self.trigger = trigger
        self.cut = cut
        self.cancelledResponse = cancelledResponse
        self.reactionTime = reactionTime
    }

    /// VAD's share of the user's onset → silence: the onset to the speech
    /// being confirmed (`SpeechOnset.detectionLatency`).
    public var detectionLatency: Duration { trigger.onset.detectionLatency }
}

// MARK: - Seams

/// What ``BargeInMonitor`` interrupts: the ``TurnOrchestrator``, or a fake in
/// tests.
public protocol BargeInTarget: Sendable {
    /// Whether Grok's reply is playing (the turn state is `agentSpeaking`).
    var isAgentSpeaking: Bool { get async }

    /// Stops the reply at once and cuts Grok's memory of it to what was
    /// heard. Returns `nil` when nothing was playing any more.
    func bargeIn(_ trigger: BargeInTrigger) async -> BargeInRecord?
}

/// How long the agent's audio has been coming out of the speaker, for the
/// echo guard's grace period.
public protocol AgentPlaybackObserving: Sendable {
    /// How long the item now playing has been audible, or `nil` when
    /// nothing is audible (idle, or still filling the jitter buffer).
    var audibleDuration: Duration? { get }
}

extension StreamingAudioPlayer: AgentPlaybackObserving {
    public var audibleDuration: Duration? {
        let snapshot = snapshot
        guard snapshot.state != .idle, let item = snapshot.currentItem, let played = playedItem(for: item),
            played.playedFrames > 0
        else { return nil }
        return played.playedDuration
    }
}

/// Voice ID's verdict on speech that would barge in (#47), so a TV or
/// someone else in the room doesn't interrupt Grok.
public protocol BargeInSpeakerGate: Sendable {
    /// The verdict on the speech starting at `onset`, or `nil` when there is
    /// none (no voiceprint enrolled, voice ID off). Only `reject` stops the
    /// barge-in: speech that is merely `uncertain` still interrupts.
    func bargeInDecision(for onset: SpeechOnset) async -> SpeakerDecision?
}

// MARK: - Outcomes

/// Why a speech onset did not barge in.
public enum BargeInSuppression: String, Sendable, Hashable, CaseIterable {
    /// The speech started in the first moments of playback, while the echo
    /// canceller converges, and didn't carry on past the grace period.
    case playbackGrace
    /// Quieter than ``BargeInConfiguration/minimumSpeechLevel``.
    case tooQuiet
    /// Not louder than what the microphone heard just before by
    /// ``BargeInConfiguration/echoMargin``: the agent's own voice leaking
    /// through the echo canceller.
    case echo
    /// Voice ID rejected the speaker.
    case otherSpeaker
}

/// What ``BargeInMonitor`` did with one speech onset.
public enum BargeInOutcome: Sendable, Hashable {
    /// Grok was cut off.
    case bargedIn(BargeInRecord)
    /// The speech didn't count as the user talking over Grok.
    case suppressed(BargeInSuppression)
    /// Grok wasn't speaking, or finished meanwhile: nothing to interrupt.
    case agentNotSpeaking
    /// Started in the grace period; decided once enough speech after it
    /// has been heard (or the segment ends).
    case deferred
    /// VAD's forced split of an over-long segment
    /// (`SpeechOnset.isContinuation`): the same speech carrying on, not new
    /// speech, so it is neither judged nor counted.
    case continuation
}

/// Counts for the HUD and the logs.
public struct BargeInStatistics: Sendable, Hashable {
    /// Speech onsets seen while Grok was speaking.
    public var onsetsWhileSpeaking = 0
    public var bargeIns = 0
    public var suppressed: [BargeInSuppression: Int] = [:]

    public init() {}

    public var suppressedTotal: Int { suppressed.values.reduce(0, +) }
}
