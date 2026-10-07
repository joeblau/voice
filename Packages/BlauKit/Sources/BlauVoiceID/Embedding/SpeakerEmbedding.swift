import Accelerate

/// Identifies the model behind a speaker embedding.
///
/// Embeddings from different models (or different weights of the same
/// model) live in different spaces and must never be compared. The
/// identifier is what the voiceprint stores
/// (`VoiceProfile.embeddingModelVersion`), so a change of model shows up as
/// a mismatch and triggers re-enrollment.
public struct SpeakerEmbeddingModelInfo: Hashable, Codable, Sendable {
    /// Stable identifier, stored next to every vector the model produces.
    public let identifier: String

    /// Width of the embedding.
    public let dimension: Int

    public init(identifier: String, dimension: Int) {
        precondition(dimension > 0, "An embedding needs at least one dimension")
        self.identifier = identifier
        self.dimension = dimension
    }

    /// WeSpeaker ResNet34-LM (pyannote's VoxCeleb fine-tune), as converted to
    /// Core ML by FluidAudio (`wespeaker_v2.mlmodelc`, 8-bit palettized
    /// weights) and pinned at revision `df2625ac` of
    /// `FluidInference/speaker-diarization-coreml`.
    ///
    /// Bump the suffix whenever the pinned weights change: the old vectors
    /// are not comparable with the new ones.
    public static let weSpeakerResNet34LM = SpeakerEmbeddingModelInfo(
        identifier: "wespeaker-resnet34-lm@df2625ac",
        dimension: 256
    )
}

/// One speaker embedding: a unit-length vector that summarizes who is
/// speaking in a stretch of audio.
///
/// Vectors are L2-normalized when they are made, so the cosine similarity of
/// two embeddings is their dot product. Higher means more alike: on Blau's
/// fixture set, WeSpeaker scores the same speaker at least 0.57 and
/// different speakers at most 0.37 (docs/benchmarks.md). Thresholds are
/// calibrated on real recordings in #48.
public struct SpeakerEmbedding: Hashable, Codable, Sendable {
    /// The L2-normalized vector.
    public let vector: [Float]

    /// `SpeakerEmbeddingModelInfo.identifier` of the model that made it.
    public let modelIdentifier: String

    /// How much audio the embedding summarizes.
    public let audioDuration: Duration

    /// Normalizes `raw` to unit length.
    ///
    /// - Returns: `nil` if `raw` is empty, has a non-finite component or has
    ///   zero length, since such a vector has no direction to compare.
    public init?(normalizing raw: [Float], modelIdentifier: String, audioDuration: Duration) {
        guard let unit = Self.normalized(raw) else { return nil }
        self.vector = unit
        self.modelIdentifier = modelIdentifier
        self.audioDuration = audioDuration
    }

    /// Number of components.
    public var dimension: Int { vector.count }

    /// Cosine similarity with `other`, in `-1...1`.
    ///
    /// - Precondition: Both come from the same model. Vectors from different
    ///   models are not comparable.
    public func cosineSimilarity(to other: SpeakerEmbedding) -> Float {
        precondition(
            modelIdentifier == other.modelIdentifier && dimension == other.dimension,
            "Speaker embeddings from different models are not comparable"
        )
        return min(1, max(-1, vDSP.dot(vector, other.vector)))
    }

    /// The mean direction of `embeddings`: their average, normalized again.
    ///
    /// - Returns: `nil` if `embeddings` is empty, mixes models, or the
    ///   vectors cancel out.
    public static func mean(of embeddings: [SpeakerEmbedding]) -> SpeakerEmbedding? {
        guard let first = embeddings.first,
            embeddings.allSatisfy({ $0.modelIdentifier == first.modelIdentifier && $0.dimension == first.dimension })
        else { return nil }
        var sum = [Float](repeating: 0, count: first.dimension)
        for embedding in embeddings {
            vDSP.add(sum, embedding.vector, result: &sum)
        }
        let duration = embeddings.reduce(Duration.zero) { $0 + $1.audioDuration }
        return SpeakerEmbedding(normalizing: sum, modelIdentifier: first.modelIdentifier, audioDuration: duration)
    }

    /// `vector` scaled to unit length, or `nil` if it has no direction.
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        // Sum of squares in Double: 256 Float squares can't overflow, but this
        // keeps tiny vectors from underflowing to zero.
        let sumOfSquares = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        let norm = sumOfSquares.squareRoot()
        guard norm.isNormal else { return nil }
        return vDSP.divide(vector, Float(norm))
    }
}
