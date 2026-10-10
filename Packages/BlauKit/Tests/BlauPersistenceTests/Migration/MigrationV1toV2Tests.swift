import BlauPersistence
import CoreData
import Foundation
import SwiftData
import Testing

private typealias Fixture = SchemaV1Fixture

/// Where a v1 store under test comes from.
enum V1StoreSource: String, CaseIterable, CustomTestStringConvertible {
    /// `Fixtures/SchemaV1/Blau.store`, written once and checked in.
    case checkedInFixture
    /// Written by `SchemaV1Fixture.write(to:)` during the test.
    case writtenNow

    var testDescription: String { rawValue }

    /// Puts a v1 store at `url`.
    func materialize(at url: URL) throws {
        switch self {
        case .checkedInFixture:
            try FileManager.default.copyItem(at: try Fixture.bundledStoreURL, to: url)
        case .writtenNow:
            try Fixture.write(to: url)
        }
    }
}

/// A new temporary directory. Shared with the v2 → v3 migration tests.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "blau-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Opens `url` the way the app opens its synced store when iCloud is off.
func openMigrated(_ url: URL) throws -> ModelContainer {
    try BlauModelContainer.make(configurations: [
        ModelConfiguration(
            BlauCloud.syncedConfigurationName, schema: BlauModelContainer.schema, url: url, cloudKitDatabase: .none)
    ])
}

/// Checks every value of the v1 fixture's data through the current model
/// types. `SchemaV2Fixture` holds the same conversations and voiceprint, so
/// the v2 → v3 tests check them with this too.
func expectFixtureData(in container: ModelContainer) throws {
    let context = ModelContext(container)
    let conversations = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt)]))
    #expect(conversations.map(\.id) == [Fixture.endedConversationID, Fixture.openConversationID])

    let ended = try #require(conversations.first)
    #expect(ended.title == "Monday planning")
    #expect(ended.startedAt == Fixture.t0)
    #expect(ended.endedAt == Fixture.t0 + 600)
    #expect(!ended.isOpen)
    #expect(ended.orderedTopics.map(\.id) == [Fixture.introTopicID, Fixture.fundraisingTopicID])
    #expect(ended.orderedTopics.map(\.title) == ["Week plan", "Seed round"])
    #expect(ended.orderedTopics.map(\.titleIsProvisional) == [false, false])
    #expect(ended.orderedTopics.map(\.summary) == ["- Plan the week", "- Raise after launch"])
    #expect(ended.orderedTopics.last?.colorSeed == 42)
    #expect(ended.orderedTopics.first?.colorSeed == Topic.colorSeed(for: Fixture.introTopicID))

    let open = try #require(conversations.last)
    #expect(open.isOpen)
    #expect(open.title == nil)
    #expect(open.orderedTopics.map(\.title) == [Topic.placeholderTitle])
    #expect(open.orderedTopics.first?.isOpen == true)

    for conversation in conversations {
        #expect(conversation.topics?.count == Fixture.topicCounts[conversation.id])
        #expect(conversation.utterances?.count == Fixture.utteranceCounts[conversation.id])
    }

    let stored = try context.fetch(FetchDescriptor<StoredUtterance>(sortBy: [SortDescriptor(\.startedAt)]))
    #expect(stored.count == Fixture.utterances.count)
    for (row, utterance) in zip(Fixture.utterances, stored) {
        #expect(utterance.id == row.id)
        #expect(utterance.conversation?.id == row.conversationID)
        #expect(utterance.topic?.id == row.topicID)
        #expect(utterance.role == row.role)
        #expect(utterance.text == row.text)
        #expect(utterance.startedAt == Fixture.t0 + row.startOffset)
        #expect(utterance.endedAt == row.endOffset.map { Fixture.t0 + $0 })
        #expect(utterance.asrConfidence == row.asrConfidence)
        #expect(utterance.voiceScore == row.voiceScore)
        #expect(utterance.isFinal == row.isFinal)
        #expect(utterance.source == row.source)
        // No row stored before v3 carries the interrupted mark (#160).
        #expect(utterance.endReasonRaw == nil)
        #expect(!utterance.isInterrupted)
    }

    let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
    let profile = try #require(profiles.first)
    #expect(profiles.count == 1)
    #expect(profile.id == Fixture.profileID)
    #expect(profile.name == "Me")
    #expect(profile.embeddingModelVersion == "wespeaker-resnet34-lm-v1")
    #expect(profile.createdAt == Fixture.t0)
    #expect(profile.updatedAt == Fixture.t0 + 60)
    #expect(profile.centroidVector == Fixture.centroid)
    let set = try #require(profile.enrollmentSets?.first)
    #expect(profile.enrollmentSets?.count == 1)
    #expect(set.deviceModel == "iPhone18,1")
    #expect(set.clipCount == 3)
    #expect(set.embeddingVectors == Fixture.clips)
}

/// How many documents, collection items, entities, facts and profile blocks
/// the store holds.
func memoryCounts(in container: ModelContainer) throws -> [Int] {
    let context = ModelContext(container)
    return [
        try context.fetchCount(FetchDescriptor<MemoryDocument>()),
        try context.fetchCount(FetchDescriptor<CollectionItem>()),
        try context.fetchCount(FetchDescriptor<MemoryEntity>()),
        try context.fetchCount(FetchDescriptor<Fact>()),
        try context.fetchCount(FetchDescriptor<ProfileBlock>()),
    ]
}

/// A v1 store opened by the current app: it migrates v1 → v2, then on
/// through the later stages (v2 → v3, `MigrationV2toV3Tests`) to the current
/// schema.
@Suite("Migration v1 → v2")
struct MigrationV1toV2Tests {
    @Test func thePlanMigratesV1ToV2WithALightweightStage() {
        #expect(
            Array(BlauMigrationPlan.schemas.prefix(2).map { $0.versionIdentifier }) == [
                SchemaV1.versionIdentifier, SchemaV2.versionIdentifier,
            ])
        let stage = BlauMigrationPlan.migrateV1toV2
        guard case .lightweight(let from, let to) = stage else {
            Issue.record("v1 → v2 must be lightweight, got \(stage)")
            return
        }
        #expect(from.versionIdentifier == SchemaV1.versionIdentifier)
        #expect(to.versionIdentifier == SchemaV2.versionIdentifier)
    }

    @Test(arguments: V1StoreSource.allCases)
    func aV1StoreMigratesWithEveryRowAndRelationshipIntact(source: V1StoreSource) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")
        try source.materialize(at: url)
        #expect(try Fixture.storedVersionHashes(at: url) == Fixture.versionHashes(of: SchemaV1.self))

        let container = try openMigrated(url)
        try expectFixtureData(in: container)
        #expect(try memoryCounts(in: container) == [0, 0, 0, 0, 0])
        #expect(try Fixture.storedVersionHashes(at: url) == Fixture.versionHashes(of: CurrentSchema.self))
    }

    @Test func theMigratedStoreTakesMemoryModelsAndReopens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")
        try V1StoreSource.checkedInFixture.materialize(at: url)

        let documentID = UUID()
        let entityID = UUID()
        do {
            let context = ModelContext(try openMigrated(url))
            let document = MemoryDocument(
                id: documentID, kind: .collection, title: "YC interview", createdAt: Fixture.t0 + 7_200)
            context.insert(document)
            context.insert(
                CollectionItem(document: document, ordinal: 0, prompt: "What are you building?", createdAt: Fixture.t0))
            let acme = MemoryEntity(
                id: entityID, name: "Acme", type: .organization, aliases: ["Acme Inc"], createdAt: Fixture.t0)
            context.insert(acme)
            context.insert(
                Fact(
                    subject: acme, predicate: "raised", objectText: "a seed round",
                    sourceUtteranceID: Fixture.utterances[2].id, validFrom: Fixture.t0 + 120, origin: .extracted))
            context.insert(ProfileBlock(text: "Founder of Acme.", updatedAt: Fixture.t0 + 7_200))
            try context.save()
        }

        // Reopening the migrated store runs no migration and keeps both old
        // and new data.
        let reopened = try openMigrated(url)
        try expectFixtureData(in: reopened)
        #expect(try memoryCounts(in: reopened) == [1, 1, 1, 1, 1])
        let context = ModelContext(reopened)
        let document = try #require(try context.fetch(FetchDescriptor<MemoryDocument>()).first)
        #expect(document.id == documentID)
        #expect(document.orderedCollectionItems.map(\.prompt) == ["What are you building?"])
        let fact = try #require(try context.fetch(FetchDescriptor<Fact>()).first)
        #expect(fact.subject?.id == entityID)
        #expect(fact.sourceUtteranceID == Fixture.utterances[2].id)
        #expect(fact.statement() == "Acme raised a seed round")
    }

    /// The real launch path: `PersistenceBootstrap` opens the v1 file in
    /// place, migrates it and stays on disk instead of falling back to
    /// memory.
    @Test func theAppBootstrapMigratesTheSyncedStoreInPlace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StoreLocation(directory: directory)
        try location.prepare()
        try V1StoreSource.checkedInFixture.materialize(at: location.syncedStoreURL)

        let mode = SyncMode.localOnly(.account(.noAccount))
        let stack = PersistenceBootstrap.hermetic().makeStack(
            mode: mode, options: PersistenceOptions(location: location, cloudKitEntitled: true))
        #expect(stack.mode == mode)
        #expect(stack.syncedStoreURL == location.syncedStoreURL)
        try expectFixtureData(in: stack.container)
        #expect(
            try Fixture.storedVersionHashes(at: location.syncedStoreURL)
                == Fixture.versionHashes(of: CurrentSchema.self))
    }
}

@Suite("SchemaV1 fixture")
struct SchemaV1FixtureTests {
    /// Fails if `SchemaV1` was edited in place: the checked-in store was
    /// written by the shipped v1, so its hashes are what real v1 stores hold.
    @Test func theCheckedInStoreMatchesSchemaV1() throws {
        let url = try Fixture.bundledStoreURL
        #expect(try Fixture.storedVersionHashes(at: url) == Fixture.versionHashes(of: SchemaV1.self))
    }

    @Test func theCheckedInStoreIsOneSelfContainedFile() throws {
        let url = try Fixture.bundledStoreURL
        for suffix in ["-wal", "-shm"] {
            let companion = url.deletingLastPathComponent().appending(path: url.lastPathComponent + suffix)
            #expect(!FileManager.default.fileExists(atPath: companion.path(percentEncoded: false)))
        }
    }

    @Test func v2KeepsEveryV1EntityHashUnchanged() throws {
        let v1 = try Fixture.versionHashes(of: SchemaV1.self)
        let v2 = try Fixture.versionHashes(of: SchemaV2.self)
        for (entity, hash) in v1 {
            #expect(v2[entity] == hash, "\(entity) changed between v1 and v2")
        }
        #expect(
            Set(v2.keys).subtracting(v1.keys)
                == ["Document", "CollectionItem", "MemoryEntity", "Fact", "ProfileBlock"])
    }
}

/// Rewrites `Fixtures/SchemaV1/Blau.store`. Skipped unless
/// `BLAU_REGENERATE_FIXTURES=1`; see Fixtures/README.md.
@Suite("SchemaV1FixtureGenerator")
struct SchemaV1FixtureGenerator {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_REGENERATE_FIXTURES"] == "1"))
    func regenerate() throws {
        let destination = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/SchemaV1/Blau.store")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appending(path: "Blau.store")
        try Fixture.write(to: scratch)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: destination.path(percentEncoded: false) + suffix))
        }
        try FileManager.default.copyItem(at: scratch, to: destination)
    }
}
