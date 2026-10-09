/// Scores probe embeddings against one enrolled voiceprint with a
/// ``VoiceIDScoring`` method.
///
/// Built once per voiceprint: it keeps the centroid and, for AS-norm, the
/// enrollment side's cohort statistics, so each score costs a few dot
/// products (plus one cohort pass for the probe under AS-norm).
///
/// ```swift
/// let scorer = try VoiceprintScorer(enrollment: clips, scoring: config.scoring)
/// let decision = config.decision(score: scorer.score(probe), audioDuration: probe.audioDuration)
/// ```
public struct VoiceprintScorer: Sendable {
    /// Why a scorer couldn't be built.
    public enum Error: Swift.Error, Hashable, Sendable {
        /// No enrollment embeddings, or they mix models, or they cancel out.
        case invalidEnrollment
        /// The scoring method uses AS-norm but no cohort was given.
        case missingCohort
        /// The cohort comes from another model than the enrollment.
        case cohortModelMismatch
    }

    public let scoring: VoiceIDScoring

    /// The normalized mean of the enrollment embeddings.
    public let centroid: SpeakerEmbedding

    /// The enrollment embeddings.
    public let enrollment: [SpeakerEmbedding]

    private let cohort: SpeakerCohort?
    private let enrollmentStatistics: SpeakerCohort.Statistics?

    /// - Parameters:
    ///   - enrollment: The voiceprint's embeddings (one per enrollment clip).
    ///   - scoring: The scoring method.
    ///   - cohort: The impostor cohort; required for AS-norm, ignored
    ///     otherwise.
    public init(enrollment: [SpeakerEmbedding], scoring: VoiceIDScoring, cohort: SpeakerCohort? = nil) throws(Error) {
        guard let centroid = SpeakerEmbedding.mean(of: enrollment) else { throw .invalidEnrollment }
        self.scoring = scoring
        self.centroid = centroid
        self.enrollment = enrollment
        switch scoring.normalization {
        case .none:
            self.cohort = nil
            self.enrollmentStatistics = nil
        case .asNorm(let topK):
            guard let cohort else { throw .missingCohort }
            guard cohort.modelIdentifier == centroid.modelIdentifier, cohort.dimension == centroid.dimension else {
                throw .cohortModelMismatch
            }
            self.cohort = cohort
            self.enrollmentStatistics = cohort.statistics(for: centroid, topK: topK)
        }
    }

    /// The raw cosine score before normalization.
    ///
    /// - Precondition: `probe` comes from the voiceprint's model.
    public func rawScore(_ probe: SpeakerEmbedding) -> Float {
        let centroidScore = probe.cosineSimilarity(to: centroid)
        switch scoring.comparison {
        case .centroid:
            return centroidScore
        case .bestMatch:
            return enrollment.reduce(centroidScore) { max($0, probe.cosineSimilarity(to: $1)) }
        }
    }

    /// The probe side's cohort statistics, for callers that score one probe
    /// against many voiceprints (the evaluation harness): compute once, pass
    /// to ``score(_:probeStatistics:)``. `nil` without AS-norm.
    public func probeStatistics(_ probe: SpeakerEmbedding) -> SpeakerCohort.Statistics? {
        guard let cohort, case .asNorm(let topK) = scoring.normalization else { return nil }
        return cohort.statistics(for: probe, topK: topK)
    }

    /// The score thresholds apply to.
    public func score(_ probe: SpeakerEmbedding) -> Float {
        score(probe, probeStatistics: probeStatistics(probe))
    }

    /// The score, with the probe's cohort statistics already computed.
    ///
    /// - Parameter rawOffset: Subtracted from the raw cosine before any
    ///   normalization: the adapted centroid's handicap
    ///   (``VoiceprintMatcher/adaptedCentroidOffset``).
    public func score(_ probe: SpeakerEmbedding, probeStatistics: SpeakerCohort.Statistics?, rawOffset: Float = 0)
        -> Float
    {
        let raw = rawScore(probe) - rawOffset
        guard let enrollmentStatistics else { return raw }
        guard let probeStatistics else {
            preconditionFailure("AS-norm scoring needs the probe's cohort statistics")
        }
        return SpeakerCohort.asNorm(raw, enrollment: enrollmentStatistics, probe: probeStatistics)
    }
}
