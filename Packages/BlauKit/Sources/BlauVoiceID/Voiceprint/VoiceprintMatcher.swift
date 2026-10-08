/// Scores probe embeddings against a whole ``Voiceprint``: the profile's
/// centroid and every device's enrollment set, keeping the best score.
///
/// Issue #46: "Scoring takes the max over the centroid and all sets." A
/// device's own set matches its microphones best, the centroid covers a new
/// device that hasn't topped up, and the maximum lets each probe use
/// whichever fits. Each reference is a ``VoiceprintScorer`` with the gate's
/// scoring method, so `.bestMatch` and AS-norm apply per reference.
///
/// ```swift
/// let matcher = try VoiceprintMatcher(voiceprint: voiceprint, scoring: config.scoring)
/// let decision = config.decision(score: matcher.score(probe), audioDuration: probe.audioDuration)
/// ```
public struct VoiceprintMatcher: Sendable {
    /// The scorers, the profile centroid's first, then one per set.
    public let scorers: [VoiceprintScorer]

    /// - Throws: `VoiceprintScorer.Error` when AS-norm has no cohort or the
    ///   cohort comes from another model.
    public init(voiceprint: Voiceprint, scoring: VoiceIDScoring, cohort: SpeakerCohort? = nil)
        throws(VoiceprintScorer.Error)
    {
        var scorers = [try VoiceprintScorer(enrollment: [voiceprint.centroid], scoring: scoring, cohort: cohort)]
        for set in voiceprint.sets where !set.embeddings.isEmpty {
            scorers.append(try VoiceprintScorer(enrollment: set.embeddings, scoring: scoring, cohort: cohort))
        }
        self.scorers = scorers
    }

    /// The highest score over the centroid and every set.
    ///
    /// - Precondition: `probe` comes from the voiceprint's model.
    public func score(_ probe: SpeakerEmbedding) -> Float {
        // The probe's cohort statistics don't depend on the reference:
        // compute them once.
        let statistics = scorers[0].probeStatistics(probe)
        return scorers.reduce(-Float.infinity) { max($0, $1.score(probe, probeStatistics: statistics)) }
    }
}
