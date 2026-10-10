import BlauCore
import BlauPersistence
import CoreData
import Foundation
import SwiftData
import Testing

private typealias Fixture = SchemaV2Fixture

/// Where a v2 store under test comes from.
enum V2StoreSource: String, CaseIterable, CustomTestStringConvertible {
    /// `Fixtures/SchemaV2/Blau.store`, written once and checked in.
    case checkedInFixture
    /// Written by `SchemaV2Fixture.write(to:)` during the test.
    case writtenNow

    var testDescription: String { rawValue }

    /// Puts a v2 store at `url`.
    func materialize(at url: URL) throws {
        switch self {
        case .checkedInFixture:
            try FileManager.default.copyItem(at: try Fixture.bundledStoreURL, to: url)
        case .writtenNow:
            try Fixture.write(to: url)
        }
    }
}

/// Checks every memory value of the v2 fixture through the current model
/// types.
private func expectMemoryData(in container: ModelContainer) throws {
    let context = ModelContext(container)
    #expect(try memoryCounts(in: container) == [2, 1, 1, 1, 1])

    let documents = try context.fetch(FetchDescriptor<MemoryDocument>(sortBy: [SortDescriptor(\.createdAt)]))
    #expect(documents.map(\.id) == [Fixture.noteID, Fixture.collectionID])
    let note = try #require(documents.first)
    #expect(note.kind == .note)
    #expect(note.title == "Launch")
    #expect(note.body == "Ship on the 14th.")
    #expect(note.createdAt == Fixture.t0 + 100)
    #expect(note.updatedAt == Fixture.t0 + 200)
    #expect(note.isContentHashCurrent)
    let collection = try #require(documents.last)
    #expect(collection.kind == .collection)
    #expect(collection.title == "YC interview")
    let item = try #require(collection.orderedCollectionItems.first)
    #expect(collection.orderedCollectionItems.count == 1)
    #expect(item.id == Fixture.itemID)
    #expect(item.prompt == "What are you building?")
    #expect(item.referenceAnswer == "A voice companion that remembers.")
    #expect(item.lastPracticedAt == Fixture.t0 + 7_300)
    #expect(item.practiceCount == 2)
    #expect(item.score == 0.75)

    let entity = try #require(try context.fetch(FetchDescriptor<MemoryEntity>()).first)
    #expect(entity.id == Fixture.entityID)
    #expect(entity.name == "Acme")
    #expect(entity.type == .organization)
    #expect(entity.aliasNames == ["Acme Inc"])
    #expect(entity.summary == "The user's company")
    #expect(entity.updatedAt == Fixture.t0 + 10)

    let fact = try #require(try context.fetch(FetchDescriptor<Fact>()).first)
    #expect(fact.id == Fixture.factID)
    #expect(fact.subject?.id == Fixture.entityID)
    #expect(fact.statement() == "Acme raised a seed round")
    #expect(fact.sourceUtteranceID == SchemaV1Fixture.utterances[2].id)
    #expect(fact.validFrom == Fixture.t0 + 120)
    #expect(fact.invalidatedAt == Fixture.t0 + 500)
    #expect(fact.confidence == 0.8)
    #expect(fact.origin == .extracted)
    #expect(fact.createdAt == Fixture.t0 + 130)

    let block = try #require(try context.fetch(FetchDescriptor<ProfileBlock>()).first)
    #expect(block.id == Fixture.profileBlockID)
    #expect(block.key == ProfileBlock.userKey)
    #expect(block.text == "Founder of Acme.")
    #expect(block.updatedAt == Fixture.t0 + 7_200)
}

private func storedReply(in container: ModelContainer) throws -> StoredUtterance {
    let id = Fixture.agentReplyID
    let descriptor = FetchDescriptor<StoredUtterance>(predicate: #Predicate { $0.id == id })
    return try #require(try ModelContext(container).fetch(descriptor).first)
}

/// A v2 store opened by a v3 build (#160): every row and relationship
/// survives, utterances gain an empty `endReasonRaw`, and the interrupted
/// mark can then be written and read back.
@Suite("Migration v2 → v3")
struct MigrationV2toV3Tests {
    @Test func thePlanMigratesV2ToV3WithALightweightStage() {
        #expect(
            BlauMigrationPlan.schemas.map { $0.versionIdentifier } == [
                SchemaV1.versionIdentifier, SchemaV2.versionIdentifier, SchemaV3.versionIdentifier,
            ])
        #expect(BlauMigrationPlan.stages.count == 2)
        let stage = BlauMigrationPlan.migrateV2toV3
        guard case .lightweight(let from, let to) = stage else {
            Issue.record("v2 → v3 must be lightweight, got \(stage)")
            return
        }
        #expect(from.versionIdentifier == SchemaV2.versionIdentifier)
        #expect(to.versionIdentifier == SchemaV3.versionIdentifier)
    }

    @Test(arguments: V2StoreSource.allCases)
    func aV2StoreMigratesWithEveryRowAndRelationshipIntact(source: V2StoreSource) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")
        try source.materialize(at: url)
        #expect(try SchemaV1Fixture.storedVersionHashes(at: url) == SchemaV1Fixture.versionHashes(of: SchemaV2.self))

        let container = try openMigrated(url)
        // Conversations, topics, utterances (none marked) and the voiceprint.
        try expectFixtureData(in: container)
        try expectMemoryData(in: container)
        #expect(
            try SchemaV1Fixture.storedVersionHashes(at: url) == SchemaV1Fixture.versionHashes(of: SchemaV3.self))
    }

    @Test func theMigratedStoreKeepsTheInterruptedMarkAcrossAReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")
        try V2StoreSource.checkedInFixture.materialize(at: url)

        do {
            let store = ConversationStore(modelContainer: try openMigrated(url), savePolicy: .immediate)
            #expect(try await store.markEnded(utteranceID: Fixture.agentReplyID, reason: .bargedIn))
            #expect(!(try await store.markEnded(utteranceID: UUID(), reason: .interrupted)))
            try await store.flush()
        }

        // Reopening runs no migration; the mark and every other value stay.
        let reopened = try openMigrated(url)
        let reply = try storedReply(in: reopened)
        #expect(reply.endReason == .bargedIn)
        #expect(reply.endReasonRaw == "bargedin")
        #expect(reply.isInterrupted)
        #expect(reply.text == SchemaV1Fixture.utterances[1].text)
        let others = try ModelContext(reopened).fetch(FetchDescriptor<StoredUtterance>())
            .filter { $0.id != Fixture.agentReplyID }
        #expect(others.count == SchemaV1Fixture.utterances.count - 1)
        #expect(others.allSatisfy { $0.endReasonRaw == nil })
        try expectMemoryData(in: reopened)
    }

    /// The real launch path: `PersistenceBootstrap` opens the v2 file in
    /// place, migrates it and stays on disk instead of falling back to
    /// memory.
    @Test func theAppBootstrapMigratesTheSyncedStoreInPlace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation(directory: directory)
        try location.prepare()
        try V2StoreSource.checkedInFixture.materialize(at: location.syncedStoreURL)

        let mode = SyncMode.localOnly(.account(.noAccount))
        let stack = PersistenceBootstrap.hermetic().makeStack(
            mode: mode, options: PersistenceOptions(location: location, cloudKitEntitled: true))
        #expect(stack.mode == mode)
        #expect(stack.syncedStoreURL == location.syncedStoreURL)
        try expectFixtureData(in: stack.container)
        try expectMemoryData(in: stack.container)
        #expect(
            try SchemaV1Fixture.storedVersionHashes(at: location.syncedStoreURL)
                == SchemaV1Fixture.versionHashes(of: SchemaV3.self))
    }
}

@Suite("SchemaV2 fixture")
struct SchemaV2FixtureTests {
    /// Fails if `SchemaV2` was edited in place: the checked-in store was
    /// written by v2 as it shipped, so its hashes are what real v2 stores
    /// hold.
    @Test func theCheckedInStoreMatchesSchemaV2() throws {
        let url = try Fixture.bundledStoreURL
        #expect(try SchemaV1Fixture.storedVersionHashes(at: url) == SchemaV1Fixture.versionHashes(of: SchemaV2.self))
    }

    @Test func theCheckedInStoreIsOneSelfContainedFile() throws {
        let url = try Fixture.bundledStoreURL
        for suffix in ["-wal", "-shm"] {
            let companion = url.deletingLastPathComponent().appending(path: url.lastPathComponent + suffix)
            #expect(!FileManager.default.fileExists(atPath: companion.path(percentEncoded: false)))
        }
    }

    /// v3 changes only `Utterance`, and only by adding `endReasonRaw`.
    @Test func v3KeepsEveryV2EntityAndOnlyAddsEndReasonRaw() throws {
        let v2 = try SchemaV1Fixture.versionHashes(of: SchemaV2.self)
        let v3 = try SchemaV1Fixture.versionHashes(of: SchemaV3.self)
        #expect(Set(v3.keys) == Set(v2.keys))
        for (entity, hash) in v2 where entity != "Utterance" {
            #expect(v3[entity] == hash, "\(entity) changed between v2 and v3")
        }
        #expect(v3["Utterance"] != v2["Utterance"])
        #expect(CloudKitCompatibility.breakingChanges(from: SchemaV2.self, to: SchemaV3.self).isEmpty)

        let older = try #require(
            NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: SchemaV2.self))?
                .entitiesByName["Utterance"])
        let newer = try #require(
            NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: SchemaV3.self))?
                .entitiesByName["Utterance"])
        #expect(Set(newer.propertiesByName.keys).subtracting(older.propertiesByName.keys) == ["endReasonRaw"])
        let added = try #require(newer.attributesByName["endReasonRaw"])
        #expect(added.isOptional)
        #expect(added.type == .string)
        #expect(!added.allowsCloudEncryption)
    }
}

/// Rewrites `Fixtures/SchemaV2/Blau.store`. Skipped unless
/// `BLAU_REGENERATE_FIXTURES=1`; see Fixtures/README.md.
@Suite("SchemaV2FixtureGenerator")
struct SchemaV2FixtureGenerator {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_REGENERATE_FIXTURES"] == "1"))
    func regenerate() throws {
        let destination = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/SchemaV2/Blau.store")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appending(path: "Blau.store")
        try Fixture.write(to: scratch)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: destination.path(percentEncoded: false) + suffix))
        }
        try FileManager.default.copyItem(at: scratch, to: destination)
    }
}
