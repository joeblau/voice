import BlauCore

/// The two thresholds that split a verification score into accept,
/// uncertain and reject.
///
/// - Scores at or above ``accept`` (`T_hi`) are accepted.
/// - Scores below ``reject`` (`T_lo`) are rejected.
/// - Scores in between are uncertain: the gate keeps transcribing
///   speculatively and re-scores once more speech has arrived.
///
/// A non-finite score is never accepted or rejected: it is uncertain.
public struct VoiceIDThresholds: Hashable, Codable, Sendable {
    /// `T_hi`: the lowest score that is accepted.
    public let accept: Float

    /// `T_lo`: scores below this are rejected.
    public let reject: Float

    /// - Precondition: Both are finite and `reject <= accept`.
    public init(accept: Float, reject: Float) {
        precondition(accept.isFinite && reject.isFinite, "Thresholds must be finite")
        precondition(reject <= accept, "T_lo (\(reject)) must not be above T_hi (\(accept))")
        self.accept = accept
        self.reject = reject
    }

    /// The decision for `score`.
    public func decision(for score: Float) -> SpeakerDecision {
        if score >= accept { return .accept }
        if score < reject { return .reject }
        return .uncertain
    }

    /// Width of the uncertain band, `accept - reject`.
    public var uncertainWidth: Float { accept - reject }
}

/// How a probe embedding is compared with the enrolled voiceprint.
public enum VoiceprintComparison: String, Hashable, Codable, Sendable, CaseIterable {
    /// Cosine similarity with the enrollment centroid (the normalized mean of
    /// the enrollment embeddings).
    case centroid
    /// The highest cosine similarity with the centroid or any single
    /// enrollment embedding (#47: "cosine vs centroid, max over enrollment
    /// embeddings").
    case bestMatch
}

/// How raw cosine scores are normalized before thresholds apply.
public enum VoiceIDScoreNormalization: Hashable, Codable, Sendable {
    /// Raw cosine similarity, in `-1...1`.
    case none
    /// Adaptive symmetric score normalization against an impostor cohort,
    /// using the `topK` most similar cohort embeddings on each side (see
    /// ``SpeakerCohort``). Scores are in standard deviations, not cosine
    /// units, so thresholds for `.none` don't carry over.
    case asNorm(topK: Int)
}

/// A scoring method: what a probe is compared with and how the score is
/// normalized. Thresholds are only meaningful for the method they were
/// calibrated with.
public struct VoiceIDScoring: Hashable, Codable, Sendable, CustomStringConvertible {
    public let comparison: VoiceprintComparison
    public let normalization: VoiceIDScoreNormalization

    public init(comparison: VoiceprintComparison, normalization: VoiceIDScoreNormalization = .none) {
        if case .asNorm(let topK) = normalization {
            precondition(topK > 0, "AS-norm needs at least one cohort score per side")
        }
        self.comparison = comparison
        self.normalization = normalization
    }

    /// Raw cosine against the centroid.
    public static let cosineCentroid = VoiceIDScoring(comparison: .centroid)
    /// Raw cosine, best of the centroid and each enrollment embedding.
    public static let cosineBestMatch = VoiceIDScoring(comparison: .bestMatch)
    /// AS-norm (top 100 cohort scores) over the centroid cosine.
    public static let asNormCentroid = VoiceIDScoring(comparison: .centroid, normalization: .asNorm(topK: 100))

    /// Whether the method needs an impostor cohort.
    public var needsCohort: Bool {
        if case .asNorm = normalization { return true }
        return false
    }

    /// A short label for reports, e.g. `cosine/centroid` or
    /// `as-norm(100)/centroid`.
    public var description: String {
        let normalization =
            switch normalization {
            case .none: "cosine"
            case .asNorm(let topK): "as-norm(\(topK))"
            }
        return "\(normalization)/\(comparison.rawValue)"
    }
}

/// Where a configuration's thresholds came from.
public struct VoiceIDCalibration: Hashable, Codable, Sendable {
    /// The evaluation set the thresholds were calibrated on.
    public let dataset: String
    /// When, as an ISO 8601 date (`2026-10-07`).
    public let date: String
    /// `T_hi` is the lowest threshold whose false accept rate on the
    /// evaluation set is at most this.
    public let maximumFalseAcceptRate: Double
    /// `T_lo` is the highest threshold whose false reject rate on the
    /// evaluation set is at most this.
    public let maximumFalseRejectRate: Double

    public init(dataset: String, date: String, maximumFalseAcceptRate: Double, maximumFalseRejectRate: Double) {
        self.dataset = dataset
        self.date = date
        self.maximumFalseAcceptRate = maximumFalseAcceptRate
        self.maximumFalseRejectRate = maximumFalseRejectRate
    }
}

/// The verification gate's tuning: the scoring method and the accept and
/// reject thresholds for each score window (#47, calibrated in #48).
///
/// The gate scores the first 1.5 s of a speech segment and re-scores at 3 s
/// and at the end of the segment. Embeddings of less than ``longWindow`` of
/// audio use ``short``; longer ones use ``long``.
///
/// ```swift
/// let config = VoiceIDConfig.calibrated
/// let decision = config.decision(score: score, audioDuration: embedding.audioDuration)
/// ```
///
/// Thresholds belong to one embedding model and one scoring method: a
/// voiceprint from another model can't be scored at all, and a different
/// normalization changes the score's scale.
public struct VoiceIDConfig: Hashable, Codable, Sendable {
    /// `SpeakerEmbeddingModelInfo.identifier` of the model the thresholds
    /// were calibrated for.
    public let modelIdentifier: String

    /// How scores are computed.
    public let scoring: VoiceIDScoring

    /// Thresholds for embeddings of less than ``longWindow`` of audio
    /// (calibrated at 1.5 s, the gate's first score).
    public let short: VoiceIDThresholds

    /// Thresholds for embeddings of ``longWindow`` or more (calibrated at
    /// 3 s, the gate's re-score).
    public let long: VoiceIDThresholds

    /// Where ``long`` starts.
    public let longWindow: Duration

    /// Provenance of the thresholds, `nil` for hand-set values.
    public let calibration: VoiceIDCalibration?

    public init(
        modelIdentifier: String,
        scoring: VoiceIDScoring,
        short: VoiceIDThresholds,
        long: VoiceIDThresholds,
        longWindow: Duration = SpeakerEmbeddingWindow.long.duration,
        calibration: VoiceIDCalibration? = nil
    ) {
        precondition(longWindow > .zero, "The long window must cover some audio")
        self.modelIdentifier = modelIdentifier
        self.scoring = scoring
        self.short = short
        self.long = long
        self.longWindow = longWindow
        self.calibration = calibration
    }

    /// The thresholds for an embedding of `audioDuration`.
    public func thresholds(forAudioDuration audioDuration: Duration) -> VoiceIDThresholds {
        audioDuration >= longWindow ? long : short
    }

    /// The decision for `score`, computed from an embedding of
    /// `audioDuration` of speech.
    public func decision(score: Float, audioDuration: Duration) -> SpeakerDecision {
        thresholds(forAudioDuration: audioDuration).decision(for: score)
    }

    /// Whether the thresholds apply to embeddings from `model`.
    public func applies(to model: SpeakerEmbeddingModelInfo) -> Bool {
        model.identifier == modelIdentifier
    }

    /// The thresholds Blau ships with: raw cosine against the enrollment
    /// centroid, WeSpeaker ResNet34-LM.
    ///
    /// Produced by the evaluation harness (`VoiceIDEvaluator`) on the public
    /// LibriSpeech calibration set (40 speakers, cross-session probes under
    /// six clean and simulated conditions; docs/voice-id-eval.md), with
    /// `T_hi` at a false accept rate of at most 0.5% and `T_lo` at a false
    /// reject rate of at most 2%, rounded outward to two decimals.
    ///
    /// Provisional until the owner's own recordings (Datasets/voice-id) are
    /// in: re-run the harness and update these values and the doc whenever
    /// the model, the scoring method or the evaluation set changes.
    public static let calibrated = VoiceIDConfig(
        modelIdentifier: SpeakerEmbeddingModelInfo.weSpeakerResNet34LM.identifier,
        scoring: .cosineCentroid,
        short: VoiceIDThresholds(accept: 0.38, reject: 0.20),
        long: VoiceIDThresholds(accept: 0.40, reject: 0.27),
        calibration: VoiceIDCalibration(
            dataset: "LibriSpeech dev-clean (40 speakers) with a test-clean cohort",
            date: "2026-10-07",
            maximumFalseAcceptRate: 0.005,
            maximumFalseRejectRate: 0.02
        )
    )
}
