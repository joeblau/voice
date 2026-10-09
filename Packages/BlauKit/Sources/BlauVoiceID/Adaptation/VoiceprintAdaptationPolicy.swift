/// When and how far adaptive updates (#49) may move the voiceprint's
/// centroid.
///
/// A voice changes from day to day (a cold, a tired evening, a new case on
/// the phone), so the centroid follows the owner's recent, clearly accepted
/// speech with an exponential moving average. Only evidence that is
/// unambiguous moves it, and never far from where enrollment put it:
///
/// | Rule | Standard value |
/// | --- | --- |
/// | EMA step `α` | 0.05 per segment |
/// | Segment length | Speech longer than 3 s, embedded over at least 3 s |
/// | Score | At least `T_hi + 0.10` (after the sensitivity setting) |
/// | Against enrollment alone | At least `T_hi`, so adaptation can't vouch for itself |
/// | Signal to noise | At least 15 dB, clipping at most 0.5% |
/// | Drift cap | Cosine distance from the enrollment centroid at most 0.10 |
/// | Per conversation | At most 20 updates |
/// | Scoring handicap | The adapted centroid's cosine minus 0.12 × its distance from the enrollment centroid, so look-alike voices gain nothing |
/// | Rollback | The owner's last 5 segments fit the adapted centroid worse than the conversation's starting one (mean loss over 0.02) |
public struct VoiceprintAdaptationPolicy: Hashable, Codable, Sendable {
    /// `α`: the weight of one segment in the moving average. The centroid
    /// becomes `normalize((1 − α) · centroid + α · segment)`.
    public var learningRate: Float

    /// Only segments whose speech is longer than this, and whose embedding
    /// covers at least this much, move the centroid. Shorter embeddings are
    /// much noisier (EER 4.5% at 1.5 s, 3.0% at 3 s).
    public var minimumSpeech: Duration

    /// How far above the accept threshold (`T_hi` of the score's own
    /// window, after the sensitivity shift) the gate's score must be, in the
    /// scoring method's units. An accept near the threshold is the gate's
    /// best guess, not evidence worth learning from.
    public var acceptMargin: Float

    /// How far above `T_hi` the segment must score against the enrollment
    /// centroid alone. The gate's score already includes the adapted
    /// centroid; requiring the enrollment's own agreement too stops
    /// adaptation from accepting evidence only because it adapted towards
    /// it before.
    public var enrollmentMargin: Float

    /// The lowest speech-over-noise ratio, in dB, of a segment that may move
    /// the centroid. A TV or other voices behind the owner leak into the
    /// embedding.
    public var minimumSignalToNoise: Float

    /// The largest fraction of clipped samples a segment may have.
    public var maximumClippedFraction: Double

    /// The drift cap: the largest cosine distance (`1 − cosine`) the
    /// adapted centroid may have from the enrollment centroid. An update
    /// that would go further is pulled back onto the cap, along the arc
    /// towards the enrollment centroid.
    public var maximumDrift: Float

    /// The most updates one conversation may make.
    public var maximumUpdatesPerSession: Int

    /// The rollback check judges the owner's last this many good-quality
    /// accepted segments since the first update.
    public var healthCheckSamples: Int

    /// Roll back when those segments score, on average, more than this much
    /// lower (raw cosine) against the adapted centroid than against the one
    /// the conversation started with.
    public var rollbackTolerance: Float

    /// The adapted centroid's scoring handicap per unit of distance from
    /// the enrollment centroid (``VoiceprintMatcher/adaptedCentroidOffset``).
    public var adaptedCentroidPenalty: Float

    public init(
        learningRate: Float = 0.05,
        minimumSpeech: Duration = .seconds(3),
        acceptMargin: Float = 0.10,
        enrollmentMargin: Float = 0,
        minimumSignalToNoise: Float = 15,
        maximumClippedFraction: Double = 0.005,
        maximumDrift: Float = 0.10,
        maximumUpdatesPerSession: Int = 20,
        healthCheckSamples: Int = 5,
        rollbackTolerance: Float = 0.02,
        adaptedCentroidPenalty: Float = VoiceprintMatcher.adaptedCentroidPenalty
    ) {
        precondition(learningRate > 0 && learningRate < 1, "The learning rate must be in (0, 1)")
        precondition(maximumDrift >= 0 && maximumDrift < 1, "The drift cap must be in [0, 1)")
        precondition(maximumUpdatesPerSession >= 0, "The update limit can't be negative")
        precondition(healthCheckSamples > 0, "The rollback check needs at least one sample")
        self.learningRate = learningRate
        self.minimumSpeech = minimumSpeech
        self.acceptMargin = acceptMargin
        self.enrollmentMargin = enrollmentMargin
        self.minimumSignalToNoise = minimumSignalToNoise
        self.maximumClippedFraction = maximumClippedFraction
        self.maximumDrift = maximumDrift
        self.maximumUpdatesPerSession = maximumUpdatesPerSession
        self.healthCheckSamples = healthCheckSamples
        self.rollbackTolerance = rollbackTolerance
        self.adaptedCentroidPenalty = adaptedCentroidPenalty
    }

    /// Issue #49's values (the table above).
    public static let standard = VoiceprintAdaptationPolicy()
}
