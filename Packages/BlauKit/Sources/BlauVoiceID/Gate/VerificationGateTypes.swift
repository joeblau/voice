import BlauCore
import Foundation

/// One score of speech against the voiceprint, as the gate keeps it.
public struct SpeakerScore: Hashable, Sendable {
    /// The score the thresholds apply to.
    public let score: Float
    public let decision: SpeakerDecision
    /// How much audio the embedding covered.
    public let audioDuration: Duration
    /// The thresholds `decision` came from (the window's, after the
    /// sensitivity setting).
    public let thresholds: VoiceIDThresholds
    /// The embedding that was scored, when the verifier has one: what
    /// adaptive voiceprint updates (#49) learn from. Kept in memory only.
    public let embedding: SpeakerEmbedding?

    public init(
        score: Float, decision: SpeakerDecision, audioDuration: Duration, thresholds: VoiceIDThresholds,
        embedding: SpeakerEmbedding? = nil
    ) {
        self.score = score
        self.decision = decision
        self.audioDuration = audioDuration
        self.thresholds = thresholds
        self.embedding = embedding
    }
}

/// A speech segment the gate accepted on its own score, with what adaptive
/// voiceprint updates (#49) need to judge it: the deciding score and its
/// embedding, and the segment's speech for the level checks.
///
/// The gate hands one to its `onScoredSpeech` observer
/// (``VoiceprintAdapter/observe(_:)``) when the segment ends. The audio is
/// the user's voice: keep it in memory only, and only as long as it takes
/// to measure it.
public struct ScoredSpeechSegment: Sendable {
    /// The VAD segment (`SpeechSegment.id`).
    public let segmentID: Int
    /// The score that decided the segment (its ``SpeakerScore/embedding``
    /// is set).
    public let score: SpeakerScore
    /// How long the segment's speech is.
    public let speechDuration: Duration
    /// The segment's speech, from its start to its end (at most the gate's
    /// buffer, ``VerificationGateConfiguration/maximumBufferedSpeech``).
    public let audio: AudioFrame

    public init(segmentID: Int, score: SpeakerScore, speechDuration: Duration, audio: AudioFrame) {
        self.segmentID = segmentID
        self.score = score
        self.speechDuration = speechDuration
        self.audio = audio
    }
}

/// Voice ID's decision on one VAD speech segment, or on the part of it an
/// utterance covers.
public struct SegmentVerdict: Hashable, Sendable {
    /// Where the decision came from.
    public enum Basis: Hashable, Sendable {
        /// The segment's own speech was scored.
        case scored
        /// Too short to score: the decision of segment `segment`, whose
        /// scored speech ended less than the inheritance window before.
        case inherited(from: Int)
        /// Too short to score, and no recent decision to inherit.
        case noRecentDecision
        /// Long enough, but no score could be computed (the embedding
        /// failed).
        case unscored
        /// The decision was still being computed when the utterance had to
        /// go on.
        case timedOut
    }

    /// The VAD segment (`SpeechSegment.id`).
    public let segmentID: Int
    public let decision: SpeakerDecision
    /// The score behind `decision`, when the segment was scored.
    public let score: Float?
    /// How much of the segment's audio the score covered.
    public let scoredDuration: Duration
    /// How much of the segment's speech the utterance covers: its weight
    /// when an utterance spans segments with different decisions.
    public let speechDuration: Duration
    public let basis: Basis

    public init(
        segmentID: Int, decision: SpeakerDecision, score: Float?, scoredDuration: Duration, speechDuration: Duration,
        basis: Basis
    ) {
        self.segmentID = segmentID
        self.decision = decision
        self.score = score
        self.scoredDuration = scoredDuration
        self.speechDuration = speechDuration
        self.basis = basis
    }

    func covering(_ speech: Duration) -> SegmentVerdict {
        SegmentVerdict(
            segmentID: segmentID, decision: decision, score: score, scoredDuration: scoredDuration,
            speechDuration: speech, basis: basis)
    }
}

/// What the gate did with one final utterance, for the DEBUG "ignored
/// speech" lane, the logs and adaptive voiceprint updates (#49).
public struct GatedUtterance: Hashable, Sendable, Identifiable {
    /// What became of it.
    public enum Disposition: String, Hashable, Sendable {
        /// Accepted: sent to Grok.
        case accepted
        /// Uncertain, and sent: the uncertain policy allowed it.
        case uncertainCommitted
        /// Uncertain, and dropped by the uncertain policy.
        case uncertainDiscarded
        /// Rejected: someone or something else. Never sent.
        case rejected

        /// Whether the utterance reached Grok.
        public var isCommitted: Bool { self == .accepted || self == .uncertainCommitted }
    }

    /// The utterance as the transcriber reported it (its text included, so
    /// keep it in memory only).
    public let utterance: Utterance
    /// The utterance's decision, from its segments'.
    public let decision: SpeakerDecision
    public let disposition: Disposition
    /// The segments it spans, in order.
    public let segments: [SegmentVerdict]
    /// How long the gate held the final: from receiving it to passing it
    /// on (or dropping it). The gate's latency beyond end of utterance.
    public let delay: Duration

    public init(
        utterance: Utterance, decision: SpeakerDecision, disposition: Disposition, segments: [SegmentVerdict],
        delay: Duration
    ) {
        self.utterance = utterance
        self.decision = decision
        self.disposition = disposition
        self.segments = segments
        self.delay = delay
    }

    public var id: UUID { utterance.id }

    /// The score of the segment with the most speech, for display.
    public var representativeScore: Float? {
        segments.filter { $0.score != nil }.max { $0.speechDuration < $1.speechDuration }?.score
    }
}

/// Counters for the HUD, the logs and tests.
public struct VerificationGateStatistics: Hashable, Sendable {
    /// VAD segments seen.
    public var segments = 0
    /// Embeddings scored against the voiceprint.
    public var scores = 0
    /// Embeddings that failed.
    public var scoreFailures = 0
    /// Segments (or utterance parts) too short to score.
    public var shortSegments = 0
    /// Final utterances decided, by decision.
    public var utterances: [SpeakerDecision: Int] = [:]
    /// Utterances passed on to Grok.
    public var committed = 0
    /// Utterances dropped (rejected, or uncertain and discarded).
    public var discarded = 0
    /// Partial transcripts held back because their speech was rejected.
    public var suppressedPartials = 0
    /// Continuations of a split segment started with the audio the split
    /// segment had received past the split point.
    public var seededContinuations = 0
    /// Samples missing from VAD's audio stream, filled from the capture
    /// history, and those filled with silence (the history no longer held
    /// them).
    public var gapSamplesFromHistory = 0
    public var gapSamplesSilenced = 0
    /// Barge-ins that asked for a verdict, and those that gave up waiting.
    public var bargeInQueries = 0
    public var bargeInTimeouts = 0
    /// The gate's hold on finals: the last, the longest and the sum (for
    /// the mean over ``utterances``).
    public var lastDelay: Duration = .zero
    public var longestDelay: Duration = .zero
    public var totalDelay: Duration = .zero

    public init() {}

    /// Final utterances decided.
    public var decidedUtterances: Int { utterances.values.reduce(0, +) }

    /// The mean hold on a final.
    public var meanDelay: Duration {
        decidedUtterances == 0 ? .zero : totalDelay / decidedUtterances
    }
}
