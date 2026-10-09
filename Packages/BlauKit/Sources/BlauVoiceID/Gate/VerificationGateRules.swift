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

    /// The decision of an utterance spanning `segments`, by share of
    /// speech (uncertain speech counts in the total).
    ///
    /// - Only uncertain parts (or none): `uncertain`.
    /// - Neither accepted nor rejected speech makes up at least
    ///   `1 - minorityShare` of all of it: `uncertain`, so speech voice ID
    ///   couldn't attribute goes through the uncertain policy rather than
    ///   riding along with a few accepted (or rejected) words. The owner's
    ///   2 s with a 0.5 s uncertain tail still accepts (80%); 1.4 s
    ///   accepted then 6 s of an unattributed voice doesn't (19%).
    ///   A part that is `uncertain` just because it was too short to score
    ///   and had nothing recent to inherit
    ///   (``SegmentVerdict/Basis/noRecentDecision``) says nothing about who
    ///   spoke, so up to `unattributedAllowance` of such speech is left out
    ///   of the shares. Otherwise the owner's "Okay, so… [pause] what about
    ///   tomorrow?" would lose to its own short opener. Past the allowance
    ///   it counts as uncertain when accepted speech outweighs rejected
    ///   speech: a run of a TV's short lines ("Yeah." "Right." "Sure.")
    ///   can't ride along on a few accepted words. When rejected speech
    ///   dominates it is still left out, so the excess can't turn a
    ///   rejection into `uncertain`, which an active turn would send.
    /// - Otherwise, accepted parts and no rejected ones: `accept`; rejected
    ///   and no accepted ones: `reject`.
    /// - Both: the larger share of speech decides, unless the smaller share
    ///   is at least `minorityShare` of the decided speech, which makes it
    ///   `uncertain`: the transcript can't be split by speaker, so a real
    ///   mix is neither sent as the owner's nor thrown away.
    ///
    /// - Parameters:
    ///   - segments: The verdicts of the segments the utterance covers.
    ///   - minorityShare: The share that makes a mix uncertain.
    ///   - unattributedAllowance: How much speech of short parts with
    ///     nothing recent to inherit is left out of the shares when
    ///     accepted speech outweighs rejected speech (all of it is left out
    ///     otherwise); the gate passes its minimum scored speech, one short
    ///     segment's worth.
    public static func combine(
        _ segments: [SegmentVerdict], minorityShare: Double, unattributedAllowance: Duration = .seconds(1)
    ) -> SpeakerDecision {
        var accepted: Duration = .zero
        var rejected: Duration = .zero
        var uncertain: Duration = .zero
        var unattributed: Duration = .zero
        for segment in segments {
            // A sliver of overlap still counts for something.
            let weight = max(segment.speechDuration, .milliseconds(1))
            switch segment.decision {
            case .accept: accepted += weight
            case .reject: rejected += weight
            case .uncertain:
                if case .noRecentDecision = segment.basis {
                    unattributed += weight
                } else {
                    uncertain += weight
                }
            }
        }
        guard accepted > .zero || rejected > .zero else { return .uncertain }
        // Unattributed speech past the allowance weighs only against an
        // acceptance: it can't turn a rejection into an uncertain
        // utterance that an active turn would send.
        if accepted > rejected { uncertain += max(.zero, unattributed - unattributedAllowance) }
        let total = (accepted + rejected + uncertain).timeInterval
        // The share outside the dominant decision, so exactly two thirds
        // still decides (`2 / 3 < 1 - 1 / 3` in floating point).
        if (total - max(accepted, rejected).timeInterval) / total > minorityShare { return .uncertain }
        switch (accepted > .zero, rejected > .zero) {
        case (true, false): return .accept
        case (false, true): return .reject
        default:
            let decided = (accepted + rejected).timeInterval
            let minority = min(accepted, rejected).timeInterval
            if minority / decided >= minorityShare { return .uncertain }
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
