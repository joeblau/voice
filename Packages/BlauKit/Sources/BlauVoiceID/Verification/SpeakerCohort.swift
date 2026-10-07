import Accelerate

/// An impostor cohort for adaptive symmetric score normalization (AS-norm).
///
/// A cohort is a set of embeddings from speakers who are neither the
/// enrolled user nor anyone likely to be scored (#47 bundles about 1,000 of
/// them). AS-norm compares a raw score with how similar each side of the
/// trial is to its closest cohort embeddings:
///
///     s' = ½ · ((s − μₑ) / σₑ + (s − μₜ) / σₜ)
///
/// where μₑ, σₑ are the mean and standard deviation of the `topK` highest
/// cosine scores between the enrollment side and the cohort, and μₜ, σₜ the
/// same for the probe (Matějka et al., Interspeech 2017). It cancels some of
/// the score shift that channel, duration and noise cause, so one threshold
/// fits more conditions.
public struct SpeakerCohort: Sendable {
    /// The model every cohort embedding comes from.
    public let modelIdentifier: String

    /// Width of each embedding.
    public let dimension: Int

    /// Number of embeddings.
    public let count: Int

    /// Row-major `count × dimension` matrix of unit vectors.
    private let matrix: [Float]

    /// - Returns: `nil` if `embeddings` is empty or mixes models or widths.
    public init?(embeddings: [SpeakerEmbedding]) {
        guard let first = embeddings.first,
            embeddings.allSatisfy({ $0.modelIdentifier == first.modelIdentifier && $0.dimension == first.dimension })
        else { return nil }
        self.modelIdentifier = first.modelIdentifier
        self.dimension = first.dimension
        self.count = embeddings.count
        self.matrix = embeddings.flatMap(\.vector)
    }

    /// Mean and standard deviation of one side's closest cohort scores.
    public struct Statistics: Hashable, Sendable {
        public let mean: Float
        public let standardDeviation: Float

        public init(mean: Float, standardDeviation: Float) {
            self.mean = mean
            self.standardDeviation = standardDeviation
        }

        /// `(score - mean) / standardDeviation`, with the deviation floored
        /// so a degenerate cohort can't blow the score up.
        public func normalize(_ score: Float) -> Float {
            (score - mean) / max(standardDeviation, SpeakerCohort.minimumStandardDeviation)
        }
    }

    /// Floor for σ in ``Statistics/normalize(_:)``.
    public static let minimumStandardDeviation: Float = 1e-3

    /// Cosine similarity of `embedding` with every cohort embedding, in
    /// cohort order.
    ///
    /// - Precondition: `embedding` comes from the cohort's model.
    public func scores(_ embedding: SpeakerEmbedding) -> [Float] {
        precondition(
            embedding.modelIdentifier == modelIdentifier && embedding.dimension == dimension,
            "The embedding and the cohort come from different models")
        var result = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { matrix in
            embedding.vector.withUnsafeBufferPointer { vector in
                result.withUnsafeMutableBufferPointer { result in
                    // (count × dimension) · (dimension × 1) = count × 1.
                    vDSP_mmul(
                        matrix.baseAddress!, 1, vector.baseAddress!, 1, result.baseAddress!, 1,
                        vDSP_Length(count), 1, vDSP_Length(dimension))
                }
            }
        }
        return result
    }

    /// Statistics of the `topK` highest cohort scores of `embedding` (all of
    /// them if the cohort is smaller).
    public func statistics(for embedding: SpeakerEmbedding, topK: Int) -> Statistics {
        precondition(topK > 0, "topK must be positive")
        let top = Array(scores(embedding).sorted(by: >).prefix(topK))
        let mean = vDSP.mean(top)
        let variance = top.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(top.count)
        return Statistics(mean: mean, standardDeviation: variance.squareRoot())
    }

    /// The AS-norm of `score` given both sides' statistics.
    public static func asNorm(_ score: Float, enrollment: Statistics, probe: Statistics) -> Float {
        0.5 * (enrollment.normalize(score) + probe.normalize(score))
    }
}
