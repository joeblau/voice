import BlauPersistence
import CoreData
import Foundation
import SwiftData

/// The data in the checked-in v2 store, `Fixtures/SchemaV2/Blau.store`, and
/// the code that writes it.
///
/// The store was written by `SchemaV2` through SwiftData exactly as a v2 build
/// of the app writes it (named configuration "Blau", CloudKit off), then
/// checkpointed into a single SQLite file. It holds the v1 fixture's
/// conversations, topics, utterances and voiceprint (`SchemaV1Fixture`, so
/// the same checks apply) and one of each memory model. Regenerate it only
/// if this data changes, never because `SchemaV2` changed (it must not):
///
///     BLAU_REGENERATE_FIXTURES=1 swift test --filter SchemaV2FixtureGenerator
///
/// Everything uses fixed ids and dates so the migration tests can check
/// every value.
enum SchemaV2Fixture {
    private typealias V1 = SchemaV1Fixture

    static let t0 = SchemaV1Fixture.t0

    static let collectionID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000041")
    static let noteID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000042")
    static let itemID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000043")
    static let entityID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000051")
    static let factID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000052")
    static let profileBlockID = SchemaV1Fixture.uuid("6F1D2C3B-0000-4000-8000-000000000053")

    /// The agent reply in the fixture (`SchemaV1Fixture.utterances[1]`): v3
    /// can mark it interrupted after the migration.
    static var agentReplyID: UUID { SchemaV1Fixture.utterances[1].id }

    /// Writes the fixture data with `SchemaV2`, the way a v2 build of the
    /// app does, into a new single-file store at `url`.
    static func write(to url: URL) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "blau-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let storeURL = scratch.appending(path: "Blau.store")
        try writeWithSwiftData(to: storeURL)
        try SchemaV1Fixture.snapshot(storeURL, into: url)
    }

    private static func writeWithSwiftData(to url: URL) throws {
        let schema = Schema(versionedSchema: SchemaV2.self)
        try autoreleasepool {
            let configuration = ModelConfiguration(
                BlauCloud.syncedConfigurationName, schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            try insertV1Data(into: context)
            insertMemory(into: context)
            try context.save()
        }
    }

    /// `SchemaV1Fixture`'s conversations and voiceprint, as `SchemaV2` models.
    private static func insertV1Data(into context: ModelContext) throws {
        let ended = SchemaV2.Conversation(
            id: V1.endedConversationID, startedAt: t0, endedAt: t0 + 600, title: "Monday planning")
        let open = SchemaV2.Conversation(id: V1.openConversationID, startedAt: t0 + 3_600)
        context.insert(ended)
        context.insert(open)

        let intro = SchemaV2.Topic(
            id: V1.introTopicID, conversation: ended, startedAt: t0 + 1, endedAt: t0 + 120, title: "Week plan",
            titleIsProvisional: false, summary: "- Plan the week", ordinal: 0)
        let fundraising = SchemaV2.Topic(
            id: V1.fundraisingTopicID, conversation: ended, startedAt: t0 + 120, endedAt: t0 + 600,
            title: "Seed round", titleIsProvisional: false, summary: "- Raise after launch", ordinal: 1,
            colorSeed: 42)
        let current = SchemaV2.Topic(id: V1.openTopicID, conversation: open, startedAt: t0 + 3_601)
        let topics = [intro.id: intro, fundraising.id: fundraising, current.id: current]
        for topic in topics.values { context.insert(topic) }

        let conversations = [ended.id: ended, open.id: open]
        for row in V1.utterances {
            context.insert(
                SchemaV2.Utterance(
                    id: row.id, conversation: conversations[row.conversationID],
                    topic: row.topicID.flatMap { topics[$0] }, role: row.role, text: row.text,
                    startedAt: t0 + row.startOffset, endedAt: row.endOffset.map { t0 + $0 },
                    asrConfidence: row.asrConfidence, voiceScore: row.voiceScore, isFinal: row.isFinal,
                    source: row.source))
        }

        let profile = SchemaV2.VoiceProfile(
            id: V1.profileID, name: "Me", embeddingModelVersion: "wespeaker-resnet34-lm-v1", centroid: V1.centroid,
            createdAt: t0, updatedAt: t0 + 60)
        context.insert(profile)
        context.insert(
            SchemaV2.VoiceEnrollmentSet(
                profile: profile, deviceModel: "iPhone18,1", embeddings: V1.clips, createdAt: t0))
    }

    /// One of each memory model, every optional field set.
    private static func insertMemory(into context: ModelContext) {
        let collection = SchemaV2.Document(
            id: collectionID, kind: .collection, title: "YC interview", createdAt: t0 + 7_200)
        context.insert(collection)
        let item = SchemaV2.CollectionItem(
            id: itemID, document: collection, ordinal: 0, prompt: "What are you building?",
            referenceAnswer: "A voice companion that remembers.", createdAt: t0 + 7_200)
        item.lastPracticedAt = t0 + 7_300
        item.practiceCount = 2
        item.score = 0.75
        context.insert(item)
        context.insert(
            SchemaV2.Document(
                id: noteID, kind: .note, title: "Launch", body: "Ship on the 14th.", createdAt: t0 + 100,
                updatedAt: t0 + 200))

        let acme = SchemaV2.MemoryEntity(
            id: entityID, name: "Acme", type: .organization, aliases: ["Acme Inc"], summary: "The user's company",
            createdAt: t0, updatedAt: t0 + 10)
        context.insert(acme)
        context.insert(
            SchemaV2.Fact(
                id: factID, subject: acme, predicate: "raised", objectText: "a seed round",
                sourceUtteranceID: V1.utterances[2].id, validFrom: t0 + 120, invalidatedAt: t0 + 500,
                confidence: 0.8, origin: .extracted, createdAt: t0 + 130))
        context.insert(SchemaV2.ProfileBlock(id: profileBlockID, text: "Founder of Acme.", updatedAt: t0 + 7_200))
    }

    /// The checked-in store.
    static var bundledStoreURL: URL {
        get throws {
            guard
                let url = Bundle.module.url(
                    forResource: "Blau", withExtension: "store", subdirectory: "Fixtures/SchemaV2")
            else { throw SchemaV1Fixture.FixtureError.missingResource }
            return url
        }
    }
}
