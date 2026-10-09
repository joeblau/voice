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
///
/// **Adapted centroids.** Adaptive updates (#49) move the centroid towards
/// the owner's recent voice, away from the enrollment centroid (the mean of
/// every set's clips). A centroid closer to the owner's voice also scores
/// voices that resemble the owner's higher, and the thresholds were
/// calibrated on enrollment centroids, so an adapted centroid would let more
/// look-alike impostors through. Its raw cosine is therefore handicapped by
/// ``adaptedCentroidOffset``, in proportion to how far it moved: a voice that
/// matches the adapted centroid only as well as a look-alike would gains
/// nothing, while the owner's changed voice, which moved it, still gains.
public struct VoiceprintMatcher: Sendable {
    /// The adapted centroid's handicap per unit of Euclidean distance from
    /// the enrollment centroid (see ``adaptedCentroidOffset``). Chosen with
    /// the simulated week in `VoiceprintAdaptationSimulationTests`
    /// (docs/voice-id.md, "Adaptive updates").
    public static let adaptedCentroidPenalty: Float = 0.12

    /// A centroid closer than this (cosine distance) to the enrollment
    /// centroid counts as not adapted.
    public static let unadaptedDrift: Float = 1e-5

    /// The scorers, the profile centroid's first, then one per set (and,
    /// for an adapted voiceprint with several sets, the enrollment
    /// centroid's last).
    public let scorers: [VoiceprintScorer]

    /// Subtracted from the centroid's raw cosine: `penalty × |centroid −
    /// enrollment centroid|`, 0 for a centroid adaptive updates haven't
    /// moved (or a voiceprint without sets).
    public let adaptedCentroidOffset: Float

    /// - Parameter adaptedCentroidPenalty: The handicap per unit of
    ///   distance an adapted centroid pays.
    /// - Throws: `VoiceprintScorer.Error` when AS-norm has no cohort or the
    ///   cohort comes from another model.
    public init(
        voiceprint: Voiceprint, scoring: VoiceIDScoring, cohort: SpeakerCohort? = nil,
        adaptedCentroidPenalty: Float = Self.adaptedCentroidPenalty
    ) throws(VoiceprintScorer.Error) {
        var scorers = [try VoiceprintScorer(enrollment: [voiceprint.centroid], scoring: scoring, cohort: cohort)]
        for set in voiceprint.sets where !set.embeddings.isEmpty {
            scorers.append(try VoiceprintScorer(enrollment: set.embeddings, scoring: scoring, cohort: cohort))
        }
        // |a − b| = sqrt(2 · (1 − cos)) for unit vectors.
        // Below `unadaptedDrift` is Float rounding (a stored centroid read
        // back), not adaptation.
        let drift = voiceprint.adaptationDrift ?? 0
        self.adaptedCentroidOffset =
            drift > Self.unadaptedDrift ? adaptedCentroidPenalty * (2 * drift).squareRoot() : 0
        // With one set, that set's own centroid is the enrollment centroid.
        // With several, keep the enrollment centroid as a reference too, so
        // an adapted voiceprint never scores lower than the enrolled one.
        if adaptedCentroidOffset > 0, voiceprint.sets.count > 1, let enrollment = voiceprint.enrollmentCentroid {
            scorers.append(try VoiceprintScorer(enrollment: [enrollment], scoring: scoring, cohort: cohort))
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
        var best = scorers[0].score(probe, probeStatistics: statistics, rawOffset: adaptedCentroidOffset)
        for scorer in scorers.dropFirst() {
            best = max(best, scorer.score(probe, probeStatistics: statistics))
        }
        return best
    }
}
