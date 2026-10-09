import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import os

/// The voiceprint in the synced SwiftData store: `VoiceProfile` and its
/// `VoiceEnrollmentSet`s (schema v1, #19), mirrored to the private CloudKit
/// database with the rest of the user's data (product decision 2 in #1).
/// The vector fields are CloudKit-encrypted.
///
/// - **Enroll once, every device.** Another device reads the same records
///   once they sync, so voice ID works there without enrolling again.
/// - **Per-device sets.** A device with its own microphones adds a set
///   (``saveDeviceSet(_:)``) keyed by its hardware model; scoring takes the
///   best of the centroid and every set (``VoiceprintMatcher``).
/// - **Conflicts: last writer wins.** CloudKit resolves concurrent edits of
///   one record that way. Duplicates it can't merge (two devices enrolling
///   before they sync, two devices of one model topping up) are resolved on
///   read the same way on every device: the newest profile and the newest
///   set per device model. Every write deletes the losers.
/// - **Deleting** goes through `DataEraser`, record by record, so the
///   deletion syncs to every device.
///
/// A `ModelActor` on its own queue, like the other stores: reads and saves
/// never run on the main thread. Settings reads the profile with `@Query`
/// on the main context, which picks up these saves.
public actor SwiftDataVoiceprintStore: ModelActor, VoiceprintStoring {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.voiceprint",
            floor: .userInitiated
        )
    }

    // MARK: Reading

    public func status(for model: SpeakerEmbeddingModelInfo) throws -> VoiceprintStatus {
        StoredVoiceprint.status(of: try storedRecords(), model: model)
    }

    private func storedRecords() throws -> [StoredVoiceprint] {
        try modelContext.fetch(FetchDescriptor<VoiceProfile>()).map(Self.snapshot)
    }

    private static func snapshot(_ profile: VoiceProfile) -> StoredVoiceprint {
        StoredVoiceprint(
            id: profile.id, name: profile.name, modelVersion: profile.embeddingModelVersion,
            centroid: profile.centroidVector, createdAt: profile.createdAt, updatedAt: profile.updatedAt,
            sets: (profile.enrollmentSets ?? []).map {
                .init(deviceModel: $0.deviceModel, vectors: $0.embeddingVectors, createdAt: $0.createdAt)
            })
    }

    // MARK: Writing

    @discardableResult
    public func enroll(_ draft: VoiceprintDraft) throws -> Voiceprint {
        let set = VoiceprintSet(
            deviceModel: draft.deviceModel, embeddings: draft.embeddings, createdAt: draft.recordedAt)
        let centroid = try StoredVoiceprint.centroid(of: [set])
        do {
            // Everything goes: earlier profiles (from any device and any
            // model) and sets, including ones whose profile is gone.
            let oldProfiles = try modelContext.fetch(FetchDescriptor<VoiceProfile>())
            let oldSets = try modelContext.fetch(FetchDescriptor<VoiceEnrollmentSet>())
            for set in oldSets { modelContext.delete(set) }
            for profile in oldProfiles { modelContext.delete(profile) }

            let profile = VoiceProfile(
                name: draft.name, embeddingModelVersion: draft.model.identifier, centroid: centroid.vector,
                createdAt: draft.recordedAt)
            modelContext.insert(profile)
            insertSet(draft, into: profile)
            try save()
            Log.voiceID.notice(
                "Enrolled a voiceprint: \(draft.embeddings.count, privacy: .public) clips on \(draft.deviceModel, privacy: .public), replaced \(oldProfiles.count, privacy: .public) profile(s)"
            )
            // What a read returns (stored vectors don't keep audio durations).
            let record = StoredVoiceprint(
                id: profile.id, name: profile.name, modelVersion: draft.model.identifier, centroid: centroid.vector,
                createdAt: draft.recordedAt, updatedAt: draft.recordedAt,
                sets: [
                    .init(
                        deviceModel: draft.deviceModel, vectors: draft.embeddings.map(\.vector),
                        createdAt: draft.recordedAt)
                ])
            guard case .enrolled(let voiceprint) = StoredVoiceprint.status(of: [record], model: draft.model) else {
                throw VoiceprintStoreError.invalidEmbeddings
            }
            return voiceprint
        } catch {
            modelContext.rollback()
            Log.voiceID.error("Saving the voiceprint failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    @discardableResult
    public func saveDeviceSet(_ draft: VoiceprintDraft) throws -> Voiceprint {
        do {
            let profiles = try modelContext.fetch(FetchDescriptor<VoiceProfile>())
            let snapshots = profiles.map(Self.snapshot)
            guard let winner = StoredVoiceprint.canonical(snapshots),
                let profile = profiles.first(where: { Self.snapshot($0) == winner })
            else { throw VoiceprintStoreError.notEnrolled }
            guard profile.embeddingModelVersion == draft.model.identifier else {
                throw VoiceprintStoreError.modelMismatch(
                    stored: profile.embeddingModelVersion, draft: draft.model.identifier)
            }

            // Duplicate profiles lose to the canonical one (last writer wins).
            for duplicate in profiles where duplicate !== profile {
                for set in duplicate.enrollmentSets ?? [] { modelContext.delete(set) }
                modelContext.delete(duplicate)
            }
            // This device model's previous set(s) are replaced.
            for set in profile.enrollmentSets ?? [] where set.deviceModel == draft.deviceModel {
                modelContext.delete(set)
            }
            insertSet(draft, into: profile)

            var record = Self.snapshot(profile)
            record.sets.removeAll { $0.deviceModel == draft.deviceModel }
            record.sets.append(
                .init(
                    deviceModel: draft.deviceModel, vectors: draft.embeddings.map(\.vector),
                    createdAt: draft.recordedAt))
            let centroid = try StoredVoiceprint.centroid(of: record.resolvedSets(model: draft.model))
            profile.updateCentroid(centroid.vector, at: draft.recordedAt)
            record.centroid = centroid.vector
            record.updatedAt = draft.recordedAt
            try save()
            Log.voiceID.notice(
                "Saved this device's enrollment set: \(draft.embeddings.count, privacy: .public) clips on \(draft.deviceModel, privacy: .public)"
            )
            guard case .enrolled(let voiceprint) = StoredVoiceprint.status(of: [record], model: draft.model) else {
                throw VoiceprintStoreError.invalidEmbeddings
            }
            return voiceprint
        } catch {
            modelContext.rollback()
            Log.voiceID.error("Saving the enrollment set failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    @discardableResult
    public func saveAdaptedCentroid(_ update: AdaptedVoiceprintCentroid) throws -> Voiceprint {
        do {
            let (profile, record) = try canonicalProfile()
            let adapted = try record.adapting(update)
            profile.updateCentroid(update.centroid.vector, at: adapted.updatedAt)
            try save()
            Log.voiceID.notice("Saved the adapted voiceprint centroid")
            return try Self.voiceprint(adapted, model: update.model)
        } catch {
            modelContext.rollback()
            Log.voiceID.error(
                "Saving the adapted voiceprint failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    @discardableResult
    public func resetAdaptation(for model: SpeakerEmbeddingModelInfo, at date: Date) throws -> Voiceprint {
        do {
            let (profile, record) = try canonicalProfile()
            let reset = try record.resettingAdaptation(for: model, at: date)
            profile.updateCentroid(reset.centroid ?? [], at: reset.updatedAt)
            try save()
            Log.voiceID.notice("Reset the voiceprint's adaptation to the enrollment centroid")
            return try Self.voiceprint(reset, model: model)
        } catch {
            modelContext.rollback()
            Log.voiceID.error(
                "Resetting the voiceprint's adaptation failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The profile every device resolves to, with duplicates deleted (last
    /// writer wins), and its snapshot.
    private func canonicalProfile() throws -> (VoiceProfile, StoredVoiceprint) {
        let profiles = try modelContext.fetch(FetchDescriptor<VoiceProfile>())
        let snapshots = profiles.map(Self.snapshot)
        guard let winner = StoredVoiceprint.canonical(snapshots),
            let profile = profiles.first(where: { Self.snapshot($0) == winner })
        else { throw VoiceprintStoreError.notEnrolled }
        for duplicate in profiles where duplicate !== profile {
            for set in duplicate.enrollmentSets ?? [] { modelContext.delete(set) }
            modelContext.delete(duplicate)
        }
        return (profile, winner)
    }

    private static func voiceprint(_ record: StoredVoiceprint, model: SpeakerEmbeddingModelInfo) throws -> Voiceprint {
        guard case .enrolled(let voiceprint) = StoredVoiceprint.status(of: [record], model: model) else {
            throw VoiceprintStoreError.invalidEmbeddings
        }
        return voiceprint
    }

    public func deleteVoiceprint() throws {
        try DataEraser.erase(.voiceprint, in: modelContext)
    }

    private func insertSet(_ draft: VoiceprintDraft, into profile: VoiceProfile) {
        let set = VoiceEnrollmentSet(
            deviceModel: draft.deviceModel, embeddings: draft.embeddings.map(\.vector), createdAt: draft.recordedAt)
        modelContext.insert(set)
        set.profile = profile
    }

    private func save() throws {
        try Signposts.withInterval(.dbSave) { try modelContext.save() }
    }
}
