import Foundation

/// The clips an enrollment produced, ready to store.
public struct VoiceprintDraft: Hashable, Sendable {
    /// A display name for the profile, for example "Me".
    public let name: String
    /// The model the embeddings came from.
    public let model: SpeakerEmbeddingModelInfo
    /// The recording device's model identifier (``VoiceprintDevice/currentModel``).
    public let deviceModel: String
    /// One embedding per accepted clip.
    public let embeddings: [SpeakerEmbedding]
    /// When the enrollment finished.
    public let recordedAt: Date

    /// - Precondition: At least one embedding, every one from `model`.
    public init(
        name: String = "Me", model: SpeakerEmbeddingModelInfo, deviceModel: String, embeddings: [SpeakerEmbedding],
        recordedAt: Date
    ) {
        precondition(!embeddings.isEmpty, "A voiceprint needs at least one clip")
        precondition(
            embeddings.allSatisfy { $0.modelIdentifier == model.identifier && $0.dimension == model.dimension },
            "Every embedding must come from \(model.identifier)")
        self.name = name
        self.model = model
        self.deviceModel = deviceModel
        self.embeddings = embeddings
        self.recordedAt = recordedAt
    }
}

/// A centroid adaptive updates (#49) moved, ready to save in place of the
/// voiceprint's.
public struct AdaptedVoiceprintCentroid: Hashable, Sendable {
    /// The voiceprint the conversation loaded (``Voiceprint/id``). If it
    /// was replaced since (re-enrolled, deleted), the update is dropped.
    public let voiceprintID: UUID
    /// The adapted centroid.
    public let centroid: SpeakerEmbedding
    /// The drift cap it was adapted under: the store checks it again
    /// against the enrollment sets it holds now, which another device may
    /// have changed meanwhile.
    public let maximumDrift: Float
    /// When the conversation ended.
    public let adaptedAt: Date

    public init(voiceprintID: UUID, centroid: SpeakerEmbedding, maximumDrift: Float, adaptedAt: Date) {
        self.voiceprintID = voiceprintID
        self.centroid = centroid
        self.maximumDrift = maximumDrift
        self.adaptedAt = adaptedAt
    }

    /// The model the centroid comes from.
    var model: SpeakerEmbeddingModelInfo {
        SpeakerEmbeddingModelInfo(identifier: centroid.modelIdentifier, dimension: centroid.dimension)
    }
}

/// Why a voiceprint write was refused.
public enum VoiceprintStoreError: Error, Hashable, Sendable {
    /// A top-up needs an enrolled voiceprint, and there is none (it was
    /// deleted, perhaps on another device, while the top-up recorded).
    case notEnrolled
    /// A top-up's model differs from the stored voiceprint's: re-enroll
    /// instead.
    case modelMismatch(stored: String, draft: String)
    /// The embeddings cancel out: no centroid can be computed.
    case invalidEmbeddings
    /// An adapted centroid belongs to a voiceprint that has been replaced
    /// (re-enrolled) since the conversation loaded it.
    case voiceprintReplaced
    /// An adapted centroid is further from the stored enrollment centroid
    /// than its drift cap allows (another device changed the enrollment
    /// sets meanwhile).
    case driftExceeded(Float)
}

/// Reads and writes the enrolled voiceprint.
///
/// The live store is ``SwiftDataVoiceprintStore`` over the synced SwiftData
/// store, so a voiceprint enrolled on one device reaches the others through
/// iCloud. ``InMemoryVoiceprintStore`` backs tests and previews.
public protocol VoiceprintStoring: Sendable {
    /// The voiceprint's state for `model`.
    func status(for model: SpeakerEmbeddingModelInfo) async throws -> VoiceprintStatus

    /// Replaces any voiceprint (from every device) with a new one holding
    /// `draft` as its only set: a first enrollment or a re-enrollment.
    @discardableResult
    func enroll(_ draft: VoiceprintDraft) async throws -> Voiceprint

    /// Adds `draft` as its device's set of the existing voiceprint,
    /// replacing that device's previous set, and recomputes the centroid
    /// over every set: the top-up.
    ///
    /// - Throws: ``VoiceprintStoreError/notEnrolled`` or
    ///   ``VoiceprintStoreError/modelMismatch(stored:draft:)``.
    @discardableResult
    func saveDeviceSet(_ draft: VoiceprintDraft) async throws -> Voiceprint

    /// Replaces the centroid with one adaptive updates moved (#49), keeping
    /// every enrollment set: what a conversation saves when it ends. The
    /// sets keep the enrollment centroid, so the adaptation can always be
    /// undone (``resetAdaptation(for:at:)``).
    ///
    /// - Throws: ``VoiceprintStoreError/notEnrolled``,
    ///   ``VoiceprintStoreError/voiceprintReplaced``,
    ///   ``VoiceprintStoreError/modelMismatch(stored:draft:)``,
    ///   ``VoiceprintStoreError/driftExceeded(_:)`` or
    ///   ``VoiceprintStoreError/invalidEmbeddings`` (no readable sets).
    @discardableResult
    func saveAdaptedCentroid(_ update: AdaptedVoiceprintCentroid) async throws -> Voiceprint

    /// Puts the centroid back on the enrollment centroid (the mean of every
    /// clip), undoing every adaptive update.
    ///
    /// - Throws: ``VoiceprintStoreError/notEnrolled``,
    ///   ``VoiceprintStoreError/modelMismatch(stored:draft:)`` or
    ///   ``VoiceprintStoreError/invalidEmbeddings``.
    @discardableResult
    func resetAdaptation(for model: SpeakerEmbeddingModelInfo, at date: Date) async throws -> Voiceprint

    /// Deletes the voiceprint and every enrollment set, here and (through
    /// iCloud) on every other device.
    func deleteVoiceprint() async throws
}

// MARK: - Stored records

/// The voiceprint records as stored, before they are resolved into a
/// ``VoiceprintStatus``: what the SwiftData and in-memory stores share.
///
/// CloudKit can't enforce uniqueness, so two devices enrolling before they
/// sync leave two profiles, and two devices of one model topping up leave
/// two sets for that model. Reads resolve both the same way on every
/// device, last writer wins: the newest profile, and the newest set per
/// device model. Writes then delete the losers.
struct StoredVoiceprint: Hashable, Sendable {
    struct Set: Hashable, Sendable {
        var deviceModel: String
        /// `nil` when the stored bytes are malformed.
        var vectors: [[Float]]?
        var createdAt: Date
    }

    var id: UUID
    var name: String
    var modelVersion: String
    /// `nil` when the stored bytes are malformed.
    var centroid: [Float]?
    var createdAt: Date
    var updatedAt: Date
    var sets: [Set]

    /// The record that wins among duplicates: the newest enrollment
    /// (`createdAt`), then the newest update, then the id, so every device
    /// picks the same one.
    static func canonical(_ records: [StoredVoiceprint]) -> StoredVoiceprint? {
        records.max { lhs, rhs in
            (lhs.createdAt, lhs.updatedAt, lhs.id.uuidString) < (rhs.createdAt, rhs.updatedAt, rhs.id.uuidString)
        }
    }

    /// The readable sets, newest per device model, newest first, as
    /// embeddings of `model`.
    func resolvedSets(model: SpeakerEmbeddingModelInfo) -> [VoiceprintSet] {
        var newest: [String: Set] = [:]
        for set in sets {
            guard let vectors = set.vectors, !vectors.isEmpty, vectors.allSatisfy({ $0.count == model.dimension })
            else { continue }
            if let existing = newest[set.deviceModel], existing.createdAt >= set.createdAt { continue }
            newest[set.deviceModel] = set
        }
        return newest.values
            .sorted { ($0.createdAt, $0.deviceModel) > ($1.createdAt, $1.deviceModel) }
            .compactMap { set in
                let embeddings = (set.vectors ?? []).compactMap {
                    SpeakerEmbedding(normalizing: $0, modelIdentifier: model.identifier, audioDuration: .zero)
                }
                guard !embeddings.isEmpty else { return nil }
                return VoiceprintSet(deviceModel: set.deviceModel, embeddings: embeddings, createdAt: set.createdAt)
            }
    }

    /// What `records` mean for `model`.
    static func status(of records: [StoredVoiceprint], model: SpeakerEmbeddingModelInfo) -> VoiceprintStatus {
        guard let record = canonical(records) else { return .notEnrolled }
        guard record.modelVersion == model.identifier else {
            return .needsReenrollment(storedModel: record.modelVersion)
        }
        let sets = record.resolvedSets(model: model)
        let storedCentroid = record.centroid.flatMap { vector in
            vector.count == model.dimension
                ? SpeakerEmbedding(normalizing: vector, modelIdentifier: model.identifier, audioDuration: .zero) : nil
        }
        guard let centroid = storedCentroid ?? SpeakerEmbedding.mean(of: sets.flatMap(\.embeddings)) else {
            return .unreadable
        }
        return .enrolled(
            Voiceprint(
                id: record.id, name: record.name, modelIdentifier: record.modelVersion, centroid: centroid, sets: sets,
                createdAt: record.createdAt, updatedAt: record.updatedAt))
    }

    /// The centroid over every clip of `sets`.
    static func centroid(of sets: [VoiceprintSet]) throws(VoiceprintStoreError) -> SpeakerEmbedding {
        guard let centroid = SpeakerEmbedding.mean(of: sets.flatMap(\.embeddings)) else { throw .invalidEmbeddings }
        return centroid
    }

    /// This record with `update`'s centroid, if it may take it.
    func adapting(_ update: AdaptedVoiceprintCentroid) throws(VoiceprintStoreError) -> StoredVoiceprint {
        guard id == update.voiceprintID else { throw .voiceprintReplaced }
        guard modelVersion == update.centroid.modelIdentifier else {
            throw .modelMismatch(stored: modelVersion, draft: update.centroid.modelIdentifier)
        }
        let enrollment = try Self.centroid(of: resolvedSets(model: update.model))
        let drift = VoiceprintAdaptation.drift(of: update.centroid, from: enrollment)
        // A little slack for Float rounding on the cap itself.
        guard drift <= update.maximumDrift + 1e-4 else { throw .driftExceeded(drift) }
        var record = self
        record.centroid = update.centroid.vector
        record.updatedAt = max(updatedAt, update.adaptedAt)
        return record
    }

    /// This record with its centroid back on the enrollment centroid.
    func resettingAdaptation(for model: SpeakerEmbeddingModelInfo, at date: Date) throws(VoiceprintStoreError)
        -> StoredVoiceprint
    {
        guard modelVersion == model.identifier else {
            throw .modelMismatch(stored: modelVersion, draft: model.identifier)
        }
        var record = self
        record.centroid = try Self.centroid(of: resolvedSets(model: model)).vector
        record.updatedAt = max(updatedAt, date)
        return record
    }
}
