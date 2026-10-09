import Foundation

/// A ``VoiceprintStoring`` in memory, with the same rules as the SwiftData
/// store. For tests and previews.
public actor InMemoryVoiceprintStore: VoiceprintStoring {
    private var records: [StoredVoiceprint] = []

    public init() {}

    /// A store that already holds `voiceprint`.
    public init(voiceprint: Voiceprint) {
        records = [Self.record(voiceprint)]
    }

    public func status(for model: SpeakerEmbeddingModelInfo) -> VoiceprintStatus {
        StoredVoiceprint.status(of: records, model: model)
    }

    @discardableResult
    public func enroll(_ draft: VoiceprintDraft) throws -> Voiceprint {
        let set = VoiceprintSet(
            deviceModel: draft.deviceModel, embeddings: draft.embeddings, createdAt: draft.recordedAt)
        let voiceprint = Voiceprint(
            id: UUID(), name: draft.name, modelIdentifier: draft.model.identifier,
            centroid: try StoredVoiceprint.centroid(of: [set]), sets: [set], createdAt: draft.recordedAt,
            updatedAt: draft.recordedAt)
        records = [Self.record(voiceprint)]
        // What a read returns (stored vectors don't keep audio durations).
        return StoredVoiceprint.status(of: records, model: draft.model).voiceprint ?? voiceprint
    }

    @discardableResult
    public func saveDeviceSet(_ draft: VoiceprintDraft) throws -> Voiceprint {
        guard let canonical = StoredVoiceprint.canonical(records) else { throw VoiceprintStoreError.notEnrolled }
        guard canonical.modelVersion == draft.model.identifier else {
            throw VoiceprintStoreError.modelMismatch(stored: canonical.modelVersion, draft: draft.model.identifier)
        }
        var record = canonical
        record.sets.removeAll { $0.deviceModel == draft.deviceModel }
        record.sets.append(
            .init(deviceModel: draft.deviceModel, vectors: draft.embeddings.map(\.vector), createdAt: draft.recordedAt))
        let sets = record.resolvedSets(model: draft.model)
        record.centroid = try StoredVoiceprint.centroid(of: sets).vector
        record.updatedAt = draft.recordedAt
        records = [record]
        guard case .enrolled(let voiceprint) = StoredVoiceprint.status(of: records, model: draft.model) else {
            throw VoiceprintStoreError.invalidEmbeddings
        }
        return voiceprint
    }

    @discardableResult
    public func saveAdaptedCentroid(_ update: AdaptedVoiceprintCentroid) throws -> Voiceprint {
        guard let canonical = StoredVoiceprint.canonical(records) else { throw VoiceprintStoreError.notEnrolled }
        records = [try canonical.adapting(update)]
        return try read(update.model)
    }

    @discardableResult
    public func resetAdaptation(for model: SpeakerEmbeddingModelInfo, at date: Date) throws -> Voiceprint {
        guard let canonical = StoredVoiceprint.canonical(records) else { throw VoiceprintStoreError.notEnrolled }
        records = [try canonical.resettingAdaptation(for: model, at: date)]
        return try read(model)
    }

    private func read(_ model: SpeakerEmbeddingModelInfo) throws -> Voiceprint {
        guard case .enrolled(let voiceprint) = StoredVoiceprint.status(of: records, model: model) else {
            throw VoiceprintStoreError.invalidEmbeddings
        }
        return voiceprint
    }

    public func deleteVoiceprint() {
        records.removeAll()
    }

    /// Adds a raw record, as if it had synced from another device. Tests use
    /// it to create duplicates.
    func insert(_ record: StoredVoiceprint) {
        records.append(record)
    }

    /// How many profile records are stored (duplicates included).
    var recordCount: Int { records.count }

    private static func record(_ voiceprint: Voiceprint) -> StoredVoiceprint {
        StoredVoiceprint(
            id: voiceprint.id, name: voiceprint.name, modelVersion: voiceprint.modelIdentifier,
            centroid: voiceprint.centroid.vector, createdAt: voiceprint.createdAt, updatedAt: voiceprint.updatedAt,
            sets: voiceprint.sets.map {
                .init(deviceModel: $0.deviceModel, vectors: $0.embeddings.map(\.vector), createdAt: $0.createdAt)
            })
    }
}
