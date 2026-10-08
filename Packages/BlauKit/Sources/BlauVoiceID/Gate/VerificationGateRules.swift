import BlauCore

/// The gate's decision rules, as pure functions so they can be tested (and
/// replayed by the evaluation harness) without audio or a model.
public enum VerificationGateRules {
    /// A segment's decision from its scores: the score that covered the most
    /// audio wins (the latest of equals). Longer embeddings are more
    /// reliable (EER 4.5% at 1.5 s, 3.0% at 3 s), so a re-score overrides
    /// the first one in either direction.
    public static func decision(from scores: [SpeakerScore]) -> SpeakerScore? {
        var best: SpeakerScore?
        for score in scores where best.map({ score.audioDuration >= $0.audioDuration }) ?? true {
            best = score
        }
        return best
    }

    /// The decision of an utterance spanning `segments`.
    ///
    /// - Only uncertain parts (or none): `uncertain`.
    /// - Accepted parts and no rejected ones: `accept`; rejected and no
    ///   accepted ones: `reject`. Uncertain parts don't count against either.
    /// - Both: the larger share of speech decides, unless the smaller share
    ///   is at least `minorityShare` of the decided speech, which makes it
    ///   `uncertain`: the transcript can't be split by speaker, so a real
    ///   mix is neither sent as the owner's nor thrown away.
    public static func combine(_ segments: [SegmentVerdict], minorityShare: Double) -> SpeakerDecision {
        var accepted: Duration = .zero
        var rejected: Duration = .zero
        var acceptedCount = 0
        var rejectedCount = 0
        for segment in segments {
            // A sliver of overlap still counts for something.
            let weight = max(segment.speechDuration, .milliseconds(1))
            switch segment.decision {
            case .accept:
                accepted += weight
                acceptedCount += 1
            case .reject:
                rejected += weight
                rejectedCount += 1
            case .uncertain:
                break
            }
        }
        switch (acceptedCount > 0, rejectedCount > 0) {
        case (false, false): return .uncertain
        case (true, false): return .accept
        case (false, true): return .reject
        case (true, true):
            let total = (accepted + rejected).timeInterval
            let minority = min(accepted, rejected).timeInterval
            if minority / total >= minorityShare { return .uncertain }
            return accepted > rejected ? .accept : .reject
        }
    }

    /// What becomes of an utterance with `decision`.
    public static func disposition(
        for decision: SpeakerDecision, duration: Duration, isTurnActive: Bool, policy: UncertainSpeechPolicy
    ) -> GatedUtterance.Disposition {
        switch decision {
        case .accept:
            .accepted
        case .reject:
            .rejected
        case .uncertain:
            policy.commits(duration: duration, isTurnActive: isTurnActive) ? .uncertainCommitted : .uncertainDiscarded
        }
    }

    /// The decision a segment too short to score inherits.
    ///
    /// - Parameters:
    ///   - previous: The previous segment's decision and where the speech
    ///     behind it (the last speech actually scored) ended, in samples.
    ///   - start: Where the short segment starts, in samples.
    ///   - sampleRate: Of both offsets.
    ///   - window: The inheritance window.
    /// - Returns: The decision, and whether it was inherited (`false`:
    ///   `uncertain` for lack of a recent decision).
    public static func inherited(
        previous: (decision: SpeakerDecision, evidenceEnd: Int64)?, start: Int64, sampleRate: Int, window: Duration
    ) -> (decision: SpeakerDecision, isInherited: Bool) {
        guard let previous else { return (.uncertain, false) }
        let gap = Duration.samples(max(0, start - previous.evidenceEnd), sampleRate: sampleRate)
        guard gap < window else { return (.uncertain, false) }
        return (previous.decision, true)
    }

    /// The gate's decision on one speech segment, from its scores at the
    /// gate's checkpoints, simulated: what the gate decides for speech of
    /// `speechDuration` whose embeddings at increasing lengths scored
    /// `scores` (the evaluation harness uses it on its windowed scores).
    ///
    /// - Returns: `nil` when the segment is too short to score.
    public static func simulatedDecision(
        scores: [(audioDuration: Duration, score: Float)], speechDuration: Duration,
        config: VoiceIDConfig, gate: VerificationGateConfiguration
    ) -> SpeakerDecision? {
        guard speechDuration >= gate.minimumScoredSpeech else { return nil }
        let speakerScores = scores.filter { $0.audioDuration <= speechDuration }.map { entry in
            let thresholds = config.thresholds(forAudioDuration: entry.audioDuration)
            return SpeakerScore(
                score: entry.score, decision: thresholds.decision(for: entry.score), audioDuration: entry.audioDuration,
                thresholds: thresholds)
        }
        return decision(from: speakerScores)?.decision ?? .uncertain
    }
}
