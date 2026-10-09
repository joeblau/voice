import Accelerate

/// One accepted speech segment, offered to adaptive updates: its embedding
/// and how sure the gate was.
public struct VoiceprintAdaptationEvidence: Hashable, Sendable {
    /// The embedding the gate decided the segment with.
    public let embedding: SpeakerEmbedding
    /// The gate's score (the best of the adapted centroid and every set).
    public let score: Float
    /// The thresholds `score` was decided with (its window's, after the
    /// sensitivity shift).
    public let thresholds: VoiceIDThresholds
    /// How long the segment's speech is.
    public let speechDuration: Duration
    /// Speech over noise in dB, `nil` when it couldn't be measured.
    public let signalToNoise: Float?
    /// The fraction of clipped samples.
    public let clippedFraction: Double

    public init(
        embedding: SpeakerEmbedding, score: Float, thresholds: VoiceIDThresholds, speechDuration: Duration,
        signalToNoise: Float?, clippedFraction: Double = 0
    ) {
        self.embedding = embedding
        self.score = score
        self.thresholds = thresholds
        self.speechDuration = speechDuration
        self.signalToNoise = signalToNoise
        self.clippedFraction = clippedFraction
    }
}

/// Adaptive voiceprint updates (#49) for one conversation: an exponential
/// moving average of the owner's clearly accepted speech, capped near the
/// enrollment centroid, with the conversation's starting centroid kept as
/// the rollback snapshot.
///
/// A pure value: ``AdaptiveVoiceprint`` shares one with the live verifier,
/// ``VoiceprintAdapter`` feeds it the gate's segments and saves the result,
/// and ``VoiceprintAdaptationReplay`` replays recorded or simulated weeks
/// through it.
///
/// ```swift
/// var adaptation = try VoiceprintAdaptation(
///     enrollmentCentroid: voiceprint.enrollmentCentroid!, centroid: voiceprint.centroid, scoring: .cosineCentroid)
/// switch adaptation.consider(evidence) {
/// case .updated(let update): print(update.drift)
/// case .skipped(let reason): print(reason)
/// case .rolledBack(let health): print(health.meanGain)
/// }
/// ```
///
/// **The update.** `centroid ← normalize((1 − α) · centroid + α · segment)`
/// for each segment that passes every rule of the
/// ``VoiceprintAdaptationPolicy``.
///
/// **The drift cap.** The enrollment centroid (the mean of every enrollment
/// clip, which the synced store keeps) is the anchor. An update that would
/// take the centroid further than ``VoiceprintAdaptationPolicy/maximumDrift``
/// (cosine distance) from it is pulled back onto the cap, along the arc
/// towards the anchor: however many segments push one way, the centroid
/// never leaves that cone.
///
/// **The rollback snapshot.** ``snapshot`` is the centroid the conversation
/// started with: the last one saved. Updates stay in memory until the
/// conversation ends. Meanwhile every good-quality accepted segment checks
/// them: if the owner's later speech fits the adapted centroid worse than
/// the snapshot (``Health``), the conversation's updates are rolled back
/// and adaptation stops until the next conversation; nothing is saved.
public struct VoiceprintAdaptation: Sendable {
    /// Why a segment didn't move the centroid.
    public enum SkipReason: String, CaseIterable, Hashable, Sendable {
        /// The embedding comes from another model.
        case modelMismatch
        /// Adaptation was rolled back this conversation.
        case suspended
        /// Speech, or the embedding, too short.
        case tooShort
        /// Speech over noise below the minimum, or not measurable.
        case noisy
        /// Too many clipped samples.
        case clipped
        /// Accepted, but not by the margin.
        case lowScore
        /// The enrollment centroid alone doesn't accept it by its margin.
        case lowEnrollmentScore
        /// The conversation already made its maximum number of updates.
        case sessionLimit
        /// The average cancelled out (cannot happen with unit vectors that
        /// passed the score rules; kept for safety).
        case degenerate
    }

    /// One update to the centroid.
    public struct Update: Hashable, Sendable {
        /// The gate's score of the segment.
        public let score: Float
        /// The segment's score against the enrollment centroid alone.
        public let enrollmentScore: Float
        /// How far the update moved the centroid (cosine distance).
        public let step: Float
        /// The centroid's cosine distance from the enrollment centroid
        /// after the update.
        public let drift: Float
        /// Whether the drift cap pulled the update back.
        public let isCapped: Bool
        /// Updates this conversation, this one included.
        public let count: Int
    }

    /// How the adapted centroid fits the owner's speech compared with the
    /// snapshot: the rollback check.
    public struct Health: Hashable, Sendable {
        /// Segments compared this conversation.
        public var samples = 0
        /// `cos(segment, centroid) − cos(segment, snapshot)` for the most
        /// recent segments (``VoiceprintAdaptationPolicy/healthCheckSamples``
        /// of them), oldest first.
        public var recentGains: [Float] = []

        public init() {}

        /// The mean recent gain; negative when the adapted centroid fits
        /// the owner's latest speech worse than the snapshot.
        public var meanGain: Float {
            recentGains.isEmpty ? 0 : recentGains.reduce(0, +) / Float(recentGains.count)
        }

        mutating func record(_ gain: Float, window: Int) {
            samples += 1
            recentGains.append(gain)
            if recentGains.count > window { recentGains.removeFirst(recentGains.count - window) }
        }
    }

    /// What became of a segment.
    public enum Outcome: Hashable, Sendable {
        case updated(Update)
        case skipped(SkipReason)
        /// The conversation's updates were undone: back to the snapshot.
        case rolledBack(Health)
    }

    public let policy: VoiceprintAdaptationPolicy
    /// The anchor of the drift cap: the mean of every enrollment clip.
    public let enrollmentCentroid: SpeakerEmbedding
    /// The rollback snapshot: the centroid the conversation started with
    /// (pulled inside the drift cap if it wasn't).
    public let snapshot: SpeakerEmbedding
    /// The adapted centroid.
    public private(set) var centroid: SpeakerEmbedding
    /// Updates applied this conversation (0 again after a rollback).
    public private(set) var updateCount = 0
    /// Of those, updates the drift cap pulled back.
    public private(set) var cappedCount = 0
    /// Segments that didn't move the centroid, by reason.
    public private(set) var skips: [SkipReason: Int] = [:]
    /// The rollback check so far.
    public private(set) var health = Health()
    /// Whether this conversation's updates were rolled back.
    public private(set) var isRolledBack = false
    /// How many updates the rollback undid.
    public private(set) var discardedUpdates = 0

    private let enrollmentScorer: VoiceprintScorer

    /// - Parameters:
    ///   - enrollmentCentroid: The mean of every enrollment clip
    ///     (``Voiceprint/enrollmentCentroid``).
    ///   - centroid: The centroid as stored: the last saved adaptation, or
    ///     the enrollment centroid.
    ///   - scoring: The gate's scoring method, to score segments against the
    ///     enrollment centroid in the same units as the gate.
    ///   - cohort: The impostor cohort, for AS-norm.
    /// - Throws: `VoiceprintScorer.Error` when the scoring method can't run.
    public init(
        enrollmentCentroid: SpeakerEmbedding, centroid: SpeakerEmbedding, scoring: VoiceIDScoring,
        cohort: SpeakerCohort? = nil, policy: VoiceprintAdaptationPolicy = .standard
    ) throws(VoiceprintScorer.Error) {
        precondition(
            enrollmentCentroid.modelIdentifier == centroid.modelIdentifier
                && enrollmentCentroid.dimension == centroid.dimension,
            "The centroid and the enrollment centroid must come from one model")
        self.policy = policy
        self.enrollmentCentroid = enrollmentCentroid
        self.enrollmentScorer = try VoiceprintScorer(enrollment: [enrollmentCentroid], scoring: scoring, cohort: cohort)
        // A stored centroid past the cap (a smaller cap since, or another
        // device's sets changed the anchor) starts on the cap.
        let start = Self.capped(centroid, around: enrollmentCentroid, maximumDrift: policy.maximumDrift).embedding
        self.snapshot = start
        self.centroid = start
    }

    /// The adapted centroid's cosine distance from the enrollment centroid.
    public var drift: Float { Self.drift(of: centroid, from: enrollmentCentroid) }

    /// Whether the conversation changed the centroid: something to save.
    public var hasChanges: Bool { updateCount > 0 && !isRolledBack }

    /// Offers one accepted segment: updates the centroid, skips the segment,
    /// or rolls the conversation's updates back.
    public mutating func consider(_ evidence: VoiceprintAdaptationEvidence) -> Outcome {
        let embedding = evidence.embedding
        guard embedding.modelIdentifier == centroid.modelIdentifier, embedding.dimension == centroid.dimension else {
            return skip(.modelMismatch)
        }
        guard !isRolledBack else { return skip(.suspended) }

        let quality = qualityProblem(evidence)
        // The rollback check: does the owner's speech since the first update
        // still fit the adapted centroid at least as well as the snapshot?
        // Measured before this segment can move it.
        if quality == nil, updateCount > 0 {
            let gain = embedding.cosineSimilarity(to: centroid) - embedding.cosineSimilarity(to: snapshot)
            health.record(gain, window: policy.healthCheckSamples)
            if health.recentGains.count >= policy.healthCheckSamples, health.meanGain < -policy.rollbackTolerance {
                let failed = health
                rollback()
                return .rolledBack(failed)
            }
        }
        if let quality { return skip(quality) }

        guard evidence.score >= evidence.thresholds.accept + policy.acceptMargin else { return skip(.lowScore) }
        let enrollmentScore = enrollmentScorer.score(embedding)
        guard enrollmentScore >= evidence.thresholds.accept + policy.enrollmentMargin else {
            return skip(.lowEnrollmentScore)
        }
        guard updateCount < policy.maximumUpdatesPerSession else { return skip(.sessionLimit) }

        guard let moved = Self.movingAverage(centroid, toward: embedding, rate: policy.learningRate) else {
            return skip(.degenerate)
        }
        let (next, isCapped) = Self.capped(moved, around: enrollmentCentroid, maximumDrift: policy.maximumDrift)
        let step = Self.drift(of: next, from: centroid)
        centroid = next
        updateCount += 1
        if isCapped { cappedCount += 1 }
        return .updated(
            Update(
                score: evidence.score, enrollmentScore: enrollmentScore, step: step, drift: drift, isCapped: isCapped,
                count: updateCount))
    }

    /// Undoes this conversation's updates (back to ``snapshot``) and stops
    /// adapting until the next conversation.
    public mutating func rollback() {
        discardedUpdates += updateCount
        centroid = snapshot
        updateCount = 0
        cappedCount = 0
        isRolledBack = true
    }

    private mutating func skip(_ reason: SkipReason) -> Outcome {
        skips[reason, default: 0] += 1
        return .skipped(reason)
    }

    /// Why the segment's audio isn't good enough to learn from, if it isn't.
    private func qualityProblem(_ evidence: VoiceprintAdaptationEvidence) -> SkipReason? {
        guard evidence.speechDuration > policy.minimumSpeech, evidence.embedding.audioDuration >= policy.minimumSpeech
        else { return .tooShort }
        guard let snr = evidence.signalToNoise, snr >= policy.minimumSignalToNoise else { return .noisy }
        guard evidence.clippedFraction <= policy.maximumClippedFraction else { return .clipped }
        return nil
    }

    // MARK: Geometry

    /// The cosine distance `1 − cos(a, b)`, in `0...2`.
    public static func drift(of centroid: SpeakerEmbedding, from anchor: SpeakerEmbedding) -> Float {
        1 - centroid.cosineSimilarity(to: anchor)
    }

    /// The cosine distance of `centroid` from the normalized mean of
    /// `enrollmentClips`, for raw stored vectors (Settings reads them off
    /// the synced records). `nil` when the vectors are unusable.
    public static func drift(of centroid: [Float], enrollmentClips: [[Float]]) -> Float? {
        guard let first = enrollmentClips.first, centroid.count == first.count,
            enrollmentClips.allSatisfy({ $0.count == first.count })
        else { return nil }
        let units = enrollmentClips.compactMap { SpeakerEmbedding.normalized($0) }
        guard units.count == enrollmentClips.count, let unitCentroid = SpeakerEmbedding.normalized(centroid) else {
            return nil
        }
        var sum = [Float](repeating: 0, count: first.count)
        for unit in units { vDSP.add(sum, unit, result: &sum) }
        guard let anchor = SpeakerEmbedding.normalized(sum) else { return nil }
        return 1 - min(1, max(-1, vDSP.dot(unitCentroid, anchor)))
    }

    /// `normalize((1 − rate) · centroid + rate · sample)`, `nil` if they
    /// cancel out.
    static func movingAverage(_ centroid: SpeakerEmbedding, toward sample: SpeakerEmbedding, rate: Float)
        -> SpeakerEmbedding?
    {
        let mixed = vDSP.add(
            multiplication: (centroid.vector, 1 - rate), multiplication: (sample.vector, rate))
        return SpeakerEmbedding(
            normalizing: mixed, modelIdentifier: centroid.modelIdentifier, audioDuration: centroid.audioDuration)
    }

    /// `centroid` if it is within `maximumDrift` of `anchor`; otherwise the
    /// point on the cap along the arc from `anchor` towards `centroid`.
    public static func capped(_ centroid: SpeakerEmbedding, around anchor: SpeakerEmbedding, maximumDrift: Float)
        -> (embedding: SpeakerEmbedding, isCapped: Bool)
    {
        let minimumCosine = 1 - maximumDrift
        let cosine = centroid.cosineSimilarity(to: anchor)
        guard cosine < minimumCosine else { return (centroid, false) }
        // The component of `centroid` orthogonal to `anchor` gives the
        // direction of the arc; the cap's point is
        // `cos θ · anchor + sin θ · that direction`.
        let orthogonal = vDSP.add(multiplication: (anchor.vector, -cosine), multiplication: (centroid.vector, 1))
        guard let direction = SpeakerEmbedding.normalized(orthogonal) else {
            // Exactly opposite the anchor: no arc to follow, so the anchor.
            return (anchor, true)
        }
        let sine = (1 - minimumCosine * minimumCosine).squareRoot()
        let point = vDSP.add(multiplication: (anchor.vector, minimumCosine), multiplication: (direction, sine))
        guard
            let embedding = SpeakerEmbedding(
                normalizing: point, modelIdentifier: centroid.modelIdentifier, audioDuration: centroid.audioDuration)
        else { return (anchor, true) }
        return (embedding, true)
    }
}
