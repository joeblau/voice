import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauVoiceID

/// The voiceprint's storage: the synced SwiftData store and the in-memory
/// one share the same rules.
@Suite("Voiceprint store")
struct VoiceprintStoreTests {
    let model = TestEmbeddings.model
    let owner = TestEmbeddings.speaker(0, count: 4)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func draft(_ embeddings: [SpeakerEmbedding], device: String = "iPhone18,1", at offset: TimeInterval = 0)
        -> VoiceprintDraft
    {
        VoiceprintDraft(model: model, deviceModel: device, embeddings: embeddings, recordedAt: start + offset)
    }

    /// Both stores, fresh.
    static func stores() throws -> [any VoiceprintStoring] {
        [InMemoryVoiceprintStore(), SwiftDataVoiceprintStore(modelContainer: try BlauModelContainer.makeInMemory())]
    }

    // MARK: Shared behaviour

    @Test func enrollStoresTheModelVersionTheSetAndTheCentroid() async throws {
        for store in try Self.stores() {
            #expect(try await store.status(for: model) == .notEnrolled)
            let saved = try await store.enroll(draft(owner))
            guard case .enrolled(let voiceprint) = try await store.status(for: model) else {
                Issue.record("\(type(of: store)): not enrolled")
                continue
            }
            #expect(voiceprint.id == saved.id)
            #expect(voiceprint.modelIdentifier == model.identifier)
            #expect(voiceprint.name == "Me")
            #expect(voiceprint.sets.count == 1)
            #expect(voiceprint.sets[0].deviceModel == "iPhone18,1")
            #expect(voiceprint.clipCount == 4)
            #expect(voiceprint.createdAt == start)
            let expected = SpeakerEmbedding.mean(of: owner)!
            #expect(voiceprint.centroid.cosineSimilarity(to: expected) > 0.9999)
            #expect(!voiceprint.offersTopUp(onDevice: "iPhone18,1"))
            #expect(voiceprint.offersTopUp(onDevice: "iPad16,3"))
        }
    }

    @Test func aModelChangeMeansReenrollment() async throws {
        for store in try Self.stores() {
            try await store.enroll(draft(owner))
            let newer = SpeakerEmbeddingModelInfo(identifier: "wespeaker-resnet34-lm@newer", dimension: 256)
            #expect(try await store.status(for: newer) == .needsReenrollment(storedModel: model.identifier))
            #expect(try await store.status(for: newer).requiresEnrollment)
            // A top-up can't mix models.
            let newerDraft = VoiceprintDraft(
                model: newer, deviceModel: "iPad16,3",
                embeddings: owner.map {
                    SpeakerEmbedding(normalizing: $0.vector, modelIdentifier: newer.identifier, audioDuration: .zero)!
                }, recordedAt: start + 10)
            await #expect(throws: VoiceprintStoreError.modelMismatch(stored: model.identifier, draft: newer.identifier))
            {
                try await store.saveDeviceSet(newerDraft)
            }
            // Re-enrolling with the new model replaces the old voiceprint.
            try await store.enroll(newerDraft)
            #expect(try await store.status(for: newer).voiceprint?.modelIdentifier == newer.identifier)
            #expect(try await store.status(for: model) == .needsReenrollment(storedModel: newer.identifier))
        }
    }

    @Test func aTopUpAddsThisDevicesSetAndRecomputesTheCentroid() async throws {
        let ipad = TestEmbeddings.speaker(2, count: 3)
        for store in try Self.stores() {
            try await store.enroll(draft(owner))
            let voiceprint = try await store.saveDeviceSet(draft(ipad, device: "iPad16,3", at: 60))
            #expect(voiceprint.sets.map(\.deviceModel) == ["iPad16,3", "iPhone18,1"])
            #expect(voiceprint.clipCount == 7)
            #expect(voiceprint.updatedAt == start + 60)
            #expect(voiceprint.createdAt == start)
            let expected = SpeakerEmbedding.mean(of: owner + ipad)!
            #expect(voiceprint.centroid.cosineSimilarity(to: expected) > 0.9999)
            #expect(try await store.status(for: model) == .enrolled(voiceprint))

            // Topping up again on the same device model replaces its set:
            // last writer wins per set.
            let again = try await store.saveDeviceSet(draft(Array(ipad.prefix(2)), device: "iPad16,3", at: 120))
            #expect(again.sets.count == 2)
            #expect(again.set(forDevice: "iPad16,3")?.embeddings.count == 2)
            #expect(again.set(forDevice: "iPhone18,1")?.embeddings.count == 4)
        }
    }

    @Test func aTopUpNeedsAVoiceprint() async throws {
        for store in try Self.stores() {
            await #expect(throws: VoiceprintStoreError.notEnrolled) {
                try await store.saveDeviceSet(draft(owner))
            }
        }
    }

    @Test func reenrollingReplacesEveryDevicesSet() async throws {
        for store in try Self.stores() {
            try await store.enroll(draft(owner))
            try await store.saveDeviceSet(draft(TestEmbeddings.speaker(0, count: 3), device: "iPad16,3", at: 30))
            let fresh = try await store.enroll(draft(TestEmbeddings.speaker(0, count: 4), at: 90))
            let status = try await store.status(for: model)
            #expect(status.voiceprint?.id == fresh.id)
            #expect(status.voiceprint?.sets.map(\.deviceModel) == ["iPhone18,1"])
        }
    }

    @Test func deletingRemovesEverything() async throws {
        for store in try Self.stores() {
            try await store.enroll(draft(owner))
            try await store.saveDeviceSet(draft(owner, device: "iPad16,3", at: 30))
            try await store.deleteVoiceprint()
            #expect(try await store.status(for: model) == .notEnrolled)
        }
    }

    // MARK: SwiftData records

    @Test func deletingGoesThroughTheSyncedRecords() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let store = SwiftDataVoiceprintStore(modelContainer: container)
        try await store.enroll(draft(owner))
        try await store.saveDeviceSet(draft(owner, device: "iPad16,3", at: 30))
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<VoiceEnrollmentSet>()) == 2)
        let profile = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first)
        #expect(profile.embeddingModelVersion == model.identifier)
        #expect((profile.enrollmentSets ?? []).map(\.clipCount).sorted() == [4, 4])

        try await store.deleteVoiceprint()
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<VoiceProfile>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<VoiceEnrollmentSet>()) == 0)
    }

    /// Two devices enrolled before they synced: both profiles arrive on each
    /// device. Every device reads the newer one, and the next write removes
    /// the older.
    @Test func duplicateProfilesResolveToTheNewestAndAreCleanedUp() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let older = VoiceProfile(
            name: "Me", embeddingModelVersion: model.identifier, centroid: TestEmbeddings.vector(5), createdAt: start)
        let newer = VoiceProfile(
            name: "Me", embeddingModelVersion: model.identifier, centroid: TestEmbeddings.vector(0),
            createdAt: start + 10)
        context.insert(older)
        context.insert(newer)
        let olderSet = VoiceEnrollmentSet(
            deviceModel: "iPad16,3", embeddings: [TestEmbeddings.vector(5)], createdAt: start)
        let newerSet = VoiceEnrollmentSet(
            deviceModel: "iPhone18,1", embeddings: owner.map(\.vector), createdAt: start + 10)
        context.insert(olderSet)
        context.insert(newerSet)
        olderSet.profile = older
        newerSet.profile = newer
        try context.save()

        let store = SwiftDataVoiceprintStore(modelContainer: container)
        let status = try await store.status(for: model)
        #expect(status.voiceprint?.id == newer.id)
        #expect(status.voiceprint?.sets.map(\.deviceModel) == ["iPhone18,1"])

        try await store.saveDeviceSet(draft(owner, device: "iPad16,3", at: 20))
        let after = ModelContext(container)
        let profiles = try after.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.map(\.id) == [newer.id])
        #expect(Set((profiles.first?.enrollmentSets ?? []).map(\.deviceModel)) == ["iPhone18,1", "iPad16,3"])
        #expect(try after.fetchCount(FetchDescriptor<VoiceEnrollmentSet>()) == 2)
    }

    @Test func malformedVectorsAreUnreadable() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let profile = VoiceProfile(name: "Me", embeddingModelVersion: model.identifier, centroid: [], createdAt: start)
        profile.centroid = Data([1, 2, 3])
        context.insert(profile)
        try context.save()
        let store = SwiftDataVoiceprintStore(modelContainer: container)
        #expect(try await store.status(for: model) == .unreadable)
        #expect(try await store.status(for: model).requiresEnrollment)
    }

    /// Settings reads the profiles with `@Query` and resolves them the way
    /// the store does, so a voiceprint whose CloudKit-encrypted vectors
    /// were lost (an iCloud Keychain reset leaves them empty) isn't shown as
    /// enrolled.
    @Test func queriedProfilesResolveLikeTheStore() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let store = SwiftDataVoiceprintStore(modelContainer: container)
        let context = ModelContext(container)
        #expect(SwiftDataVoiceprintStore.status(of: [], model: model) == .notEnrolled)

        try await store.enroll(draft(owner))
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
        let stored = try await store.status(for: model)
        #expect(SwiftDataVoiceprintStore.status(of: profiles, model: model) == stored)
        #expect(SwiftDataVoiceprintStore.status(of: profiles, model: model).voiceprint != nil)

        // The encrypted fields didn't come back.
        let profile = try #require(profiles.first)
        profile.centroid = Data()
        for set in profile.enrollmentSets ?? [] { set.embeddings = Data() }
        try context.save()
        #expect(SwiftDataVoiceprintStore.status(of: [profile], model: model) == .unreadable)
        #expect(try await store.status(for: model) == .unreadable)
    }

    // MARK: Resolution rules

    @Test func theNewestSetPerDeviceModelWins() {
        let record = StoredVoiceprint(
            id: UUID(), name: "Me", modelVersion: model.identifier, centroid: nil, createdAt: start, updatedAt: start,
            sets: [
                .init(deviceModel: "iPhone18,1", vectors: [TestEmbeddings.vector(1)], createdAt: start),
                .init(deviceModel: "iPhone18,1", vectors: [TestEmbeddings.vector(2)], createdAt: start + 5),
                .init(deviceModel: "iPad16,3", vectors: nil, createdAt: start + 9),
                .init(deviceModel: "iPad16,3", vectors: [[1, 2, 3]], createdAt: start + 9),
            ])
        let sets = record.resolvedSets(model: model)
        #expect(sets.map(\.deviceModel) == ["iPhone18,1"])
        #expect(sets[0].embeddings[0].vector == TestEmbeddings.vector(2))
        // Without a readable centroid the sets give one.
        let status = StoredVoiceprint.status(of: [record], model: model)
        #expect(status.voiceprint?.centroid.vector == TestEmbeddings.vector(2))
    }

    @Test func profileTiesBreakTheSameWayEverywhere() {
        let a = StoredVoiceprint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A", modelVersion: model.identifier,
            centroid: TestEmbeddings.vector(1), createdAt: start, updatedAt: start, sets: [])
        var b = a
        b.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        b.name = "B"
        #expect(StoredVoiceprint.canonical([a, b])?.name == "B")
        #expect(StoredVoiceprint.canonical([b, a])?.name == "B")
        var updated = a
        updated.updatedAt = start + 1
        #expect(StoredVoiceprint.canonical([updated, b])?.name == "A")
        #expect(StoredVoiceprint.canonical([]) == nil)
    }

    @Test func inMemoryDuplicatesResolveLikeSwiftData() async throws {
        let store = InMemoryVoiceprintStore()
        try await store.enroll(draft(owner))
        await store.insert(
            StoredVoiceprint(
                id: UUID(), name: "Other device", modelVersion: model.identifier, centroid: TestEmbeddings.vector(9),
                createdAt: start - 100, updatedAt: start - 100, sets: []))
        #expect(await store.recordCount == 2)
        #expect(await store.status(for: model).voiceprint?.name == "Me")
        try await store.saveDeviceSet(draft(owner, device: "iPad16,3", at: 5))
        #expect(await store.recordCount == 1)
    }
}
