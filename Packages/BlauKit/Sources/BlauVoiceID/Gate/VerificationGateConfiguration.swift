import BlauCore

/// What the verification gate does with an utterance whose speaker is
/// `uncertain`: neither accepted (`T_hi`) nor rejected (`T_lo`) by voice ID.
public enum UncertainSpeechPolicy: Hashable, Sendable {
    /// Never send it to Grok.
    case discard
    /// Always send it.
    case commit
    /// Send it only while the conversation is in an active turn (Grok is
    /// answering, or someone spoke to it recently: ``ConversationTurnActivity``)
    /// and the utterance is at least `minimumDuration` long.
    case commitDuringActiveTurn(minimumDuration: Duration)

    /// Issue #47's default: send uncertain speech only in an active turn and
    /// only when it is at least 2 s long.
    public static let standard = UncertainSpeechPolicy.commitDuringActiveTurn(minimumDuration: .seconds(2))

    /// Whether an uncertain utterance of `duration` is sent.
    public func commits(duration: Duration, isTurnActive: Bool) -> Bool {
        switch self {
        case .discard: false
        case .commit: true
        case .commitDuringActiveTurn(let minimum): isTurnActive && duration >= minimum
        }
    }
}

/// Tuning for ``VerificationGate`` (#47).
///
/// The defaults are the issue's: score the first 1.5 s of a speech segment,
/// re-score at 3 s and at the end of the segment; segments under 1 s inherit
/// the previous segment's decision when it was less than 5 s before;
/// uncertain speech is sent only in an active turn and when it lasts 2 s or
/// more.
public struct VerificationGateConfiguration: Hashable, Sendable {
    /// When a segment is scored while it is still being spoken, in order:
    /// once this much of it has been heard. The decision at the end of the
    /// segment (or of the utterance) comes on top.
    public var scoreWindows: [SpeakerEmbeddingWindow]

    /// Speech shorter than this is not scored: embeddings of under a second
    /// are unreliable (18% EER at 1 s). It inherits the previous segment's
    /// decision instead (see ``inheritanceWindow``).
    public var minimumScoredSpeech: Duration

    /// A short segment inherits the previous segment's decision only when
    /// the last speech that was actually scored ended less than this before
    /// it starts. Otherwise it is `uncertain`.
    ///
    /// Measured from the last *scored* speech, not from the previous
    /// segment, so a run of short segments can't carry a decision on
    /// indefinitely (a TV's "Yeah." "Okay." after the owner spoke).
    public var inheritanceWindow: Duration

    /// At the end of a segment (or of an utterance) the speech is scored
    /// again only when it is at least this much longer than what the last
    /// score covered. Saves an embedding (and its latency) when the 3 s
    /// score already covers nearly all of it.
    public var rescoreMinimumGain: Duration

    /// What happens to uncertain utterances.
    public var uncertainPolicy: UncertainSpeechPolicy

    /// How long an utterance waits for a segment's decision that is still
    /// being computed (an embedding in flight) before it is taken as
    /// `uncertain`.
    public var decisionTimeout: Duration

    /// How long an utterance waits for VAD to report the speech it covers.
    /// The transcriber and the gate read VAD through separate streams, so a
    /// final can arrive just before the gate has seen its segment start.
    public var segmentArrivalTimeout: Duration

    /// How long a barge-in waits for the speech's first decision (the 1.5 s
    /// score, or the end of a shorter segment) before letting it interrupt
    /// as `uncertain`.
    public var bargeInDecisionTimeout: Duration

    /// When an utterance spans segments that were accepted and segments that
    /// were rejected, the larger share of speech decides, unless the smaller
    /// one is at least this share of the decided speech: then the utterance
    /// is `uncertain`. It is also `uncertain` when neither accepted nor
    /// rejected speech makes up at least `1 - mixedSpeechMinorityShare` of
    /// all its speech, uncertain speech included.
    public var mixedSpeechMinorityShare: Double

    /// The most audio buffered for one segment. VAD splits segments at 8 s.
    public var maximumBufferedSpeech: Duration

    /// Finished segments remembered for inheritance and for utterances that
    /// arrive late.
    public var retainedSegments: Int

    public init(
        scoreWindows: [SpeakerEmbeddingWindow] = SpeakerEmbeddingWindow.standard,
        minimumScoredSpeech: Duration = .seconds(1),
        inheritanceWindow: Duration = .seconds(5),
        rescoreMinimumGain: Duration = .milliseconds(500),
        uncertainPolicy: UncertainSpeechPolicy = .standard,
        decisionTimeout: Duration = .seconds(1),
        segmentArrivalTimeout: Duration = .milliseconds(500),
        bargeInDecisionTimeout: Duration = .seconds(2),
        mixedSpeechMinorityShare: Double = 1.0 / 3.0,
        maximumBufferedSpeech: Duration = .seconds(20),
        retainedSegments: Int = 32
    ) {
        precondition(scoreWindows.allSatisfy { $0.duration > .zero }, "Score windows must cover some audio")
        precondition(minimumScoredSpeech > .zero, "minimumScoredSpeech must be positive")
        precondition(inheritanceWindow >= .zero, "inheritanceWindow must not be negative")
        precondition(rescoreMinimumGain >= .zero, "rescoreMinimumGain must not be negative")
        precondition(decisionTimeout >= .zero, "decisionTimeout must not be negative")
        precondition(segmentArrivalTimeout >= .zero, "segmentArrivalTimeout must not be negative")
        precondition(bargeInDecisionTimeout >= .zero, "bargeInDecisionTimeout must not be negative")
        precondition((0...0.5).contains(mixedSpeechMinorityShare), "mixedSpeechMinorityShare must be in 0...0.5")
        precondition(maximumBufferedSpeech > .zero, "maximumBufferedSpeech must be positive")
        precondition(retainedSegments > 0, "retainedSegments must be positive")
        self.scoreWindows = scoreWindows.sorted()
        self.minimumScoredSpeech = minimumScoredSpeech
        self.inheritanceWindow = inheritanceWindow
        self.rescoreMinimumGain = rescoreMinimumGain
        self.uncertainPolicy = uncertainPolicy
        self.decisionTimeout = decisionTimeout
        self.segmentArrivalTimeout = segmentArrivalTimeout
        self.bargeInDecisionTimeout = bargeInDecisionTimeout
        self.mixedSpeechMinorityShare = mixedSpeechMinorityShare
        self.maximumBufferedSpeech = maximumBufferedSpeech
        self.retainedSegments = retainedSegments
    }

    public static let standard = VerificationGateConfiguration()
}
