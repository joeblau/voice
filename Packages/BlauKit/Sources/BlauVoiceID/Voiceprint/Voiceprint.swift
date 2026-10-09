import BlauTelemetry
import Foundation

/// One device's enrollment clips: the embeddings of the clips recorded on
/// that device model's microphones.
///
/// Microphones differ (an iPhone's, an iPad's, AirPods'), so each device can
/// add a set of its own to the synced voiceprint (issue #46). Sets are keyed
/// by the hardware model identifier: two devices of the same model share
/// microphones and share a set, last writer wins.
public struct VoiceprintSet: Hashable, Sendable {
    /// The recording device's model identifier, for example `iPhone18,1`.
    public let deviceModel: String
    /// One embedding per accepted clip.
    public let embeddings: [SpeakerEmbedding]
    public let createdAt: Date

    public init(deviceModel: String, embeddings: [SpeakerEmbedding], createdAt: Date) {
        self.deviceModel = deviceModel
        self.embeddings = embeddings
        self.createdAt = createdAt
    }

    /// The set's own centroid, `nil` for an empty set.
    public var centroid: SpeakerEmbedding? { SpeakerEmbedding.mean(of: embeddings) }
}

/// The enrolled user's voiceprint as the gate scores it: the profile's
/// centroid plus every device's enrollment set, all from one embedding
/// model.
///
/// Read it from a ``VoiceprintStoring`` (``VoiceprintStatus/enrolled(_:)``)
/// and score with ``VoiceprintMatcher``.
public struct Voiceprint: Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// The model every vector came from (`VoiceProfile.embeddingModelVersion`).
    public let modelIdentifier: String
    /// The profile's centroid: the normalized mean of every clip, possibly
    /// moved since by adaptive updates (#49).
    public let centroid: SpeakerEmbedding
    /// One set per device model, newest first.
    public let sets: [VoiceprintSet]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, name: String, modelIdentifier: String, centroid: SpeakerEmbedding, sets: [VoiceprintSet],
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.centroid = centroid
        self.sets = sets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Clips across every set.
    public var clipCount: Int { sets.reduce(0) { $0 + $1.embeddings.count } }

    /// The set recorded on `deviceModel`, if any.
    public func set(forDevice deviceModel: String) -> VoiceprintSet? {
        sets.first { $0.deviceModel == deviceModel }
    }

    /// Whether `deviceModel` has no set of its own yet, so the optional
    /// top-up is worth offering there.
    public func offersTopUp(onDevice deviceModel: String) -> Bool {
        set(forDevice: deviceModel) == nil
    }

    /// The centroid enrollment gave: the normalized mean of every clip of
    /// every set. Adaptive updates (#49) move ``centroid`` away from it, at
    /// most to the drift cap. `nil` without readable sets.
    public var enrollmentCentroid: SpeakerEmbedding? {
        SpeakerEmbedding.mean(of: sets.flatMap(\.embeddings))
    }

    /// How far adaptive updates have moved ``centroid`` from
    /// ``enrollmentCentroid`` (cosine distance), `nil` without readable
    /// sets.
    public var adaptationDrift: Float? {
        enrollmentCentroid.map { VoiceprintAdaptation.drift(of: centroid, from: $0) }
    }

    /// This voiceprint with another centroid (an adapted one).
    public func withCentroid(_ centroid: SpeakerEmbedding, updatedAt: Date? = nil) -> Voiceprint {
        Voiceprint(
            id: id, name: name, modelIdentifier: modelIdentifier, centroid: centroid, sets: sets, createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt)
    }
}

/// Where the voiceprint stands for the embedding model the app runs.
public enum VoiceprintStatus: Hashable, Sendable {
    /// No voiceprint has been enrolled (or it was deleted).
    case notEnrolled
    /// A usable voiceprint for the current model.
    case enrolled(Voiceprint)
    /// The voiceprint came from another embedding model (`storedModel`):
    /// its vectors can't be compared with the current model's, so the user
    /// must enroll again.
    case needsReenrollment(storedModel: String)
    /// A voiceprint exists but its vectors can't be read: malformed, or the
    /// CloudKit-encrypted fields were lost with a reset iCloud Keychain. The
    /// user must enroll again.
    case unreadable

    /// The usable voiceprint, if any.
    public var voiceprint: Voiceprint? {
        if case .enrolled(let voiceprint) = self { return voiceprint }
        return nil
    }

    /// Whether the user has to (re-)enroll before voice ID can work.
    public var requiresEnrollment: Bool { voiceprint == nil }
}

/// The current device's hardware model, the key of its enrollment set.
public enum VoiceprintDevice {
    /// `hw.machine` on iOS (the simulated model in the simulator), for
    /// example `iPhone18,1`.
    public static var currentModel: String { BenchmarkDevice.current.modelIdentifier }
}
