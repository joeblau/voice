import BlauPersistence
import CoreData
import Foundation
import SQLite3
import SwiftData

/// The data in the checked-in v1 store, `Fixtures/SchemaV1/Blau.store`, and
/// the code that writes it.
///
/// The store was written by `SchemaV1` through SwiftData exactly as a v1 build
/// of the app writes it (named configuration "Blau", CloudKit off), then
/// checkpointed into a single SQLite file. Regenerate it only if this data
/// changes, never because `SchemaV1` changed (it must not):
///
///     BLAU_REGENERATE_FIXTURES=1 swift test --filter SchemaV1FixtureGenerator
///
/// Everything uses fixed ids and dates so the migration tests can check
/// every value.
enum SchemaV1Fixture {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A literal UUID. A typo stops the tests at once.
    static func uuid(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else { preconditionFailure("Malformed UUID literal \(string)") }
        return id
    }

    static let endedConversationID = uuid("6F1D2C3B-0000-4000-8000-000000000001")
    static let openConversationID = uuid("6F1D2C3B-0000-4000-8000-000000000002")
    static let introTopicID = uuid("6F1D2C3B-0000-4000-8000-000000000011")
    static let fundraisingTopicID = uuid("6F1D2C3B-0000-4000-8000-000000000012")
    static let openTopicID = uuid("6F1D2C3B-0000-4000-8000-000000000013")
    static let profileID = uuid("6F1D2C3B-0000-4000-8000-000000000031")

    struct UtteranceRow: Equatable {
        let id: UUID
        let conversationID: UUID
        let topicID: UUID?
        let role: UtteranceRole
        let text: String
        let startOffset: TimeInterval
        let endOffset: TimeInterval?
        let asrConfidence: Double?
        let voiceScore: Double?
        let isFinal: Bool
        let source: TranscriptSource
    }

    static let utterances: [UtteranceRow] = [
        UtteranceRow(
            id: uuid("6F1D2C3B-0000-4000-8000-000000000021"), conversationID: endedConversationID,
            topicID: introTopicID, role: .user, text: "Morning. Let's plan the week.", startOffset: 1,
            endOffset: 3.5, asrConfidence: 0.94, voiceScore: 0.72, isFinal: true, source: .parakeet),
        UtteranceRow(
            id: uuid("6F1D2C3B-0000-4000-8000-000000000022"), conversationID: endedConversationID,
            topicID: introTopicID, role: .agent, text: "Sure. What's first?", startOffset: 4, endOffset: 5.25,
            asrConfidence: nil, voiceScore: nil, isFinal: true, source: .grok),
        UtteranceRow(
            id: uuid("6F1D2C3B-0000-4000-8000-000000000023"), conversationID: endedConversationID,
            topicID: fundraisingTopicID, role: .user, text: "When should we raise the seed round?",
            startOffset: 120, endOffset: 123, asrConfidence: 0.88, voiceScore: 0.69, isFinal: true,
            source: .speechAnalyzer),
        UtteranceRow(
            id: uuid("6F1D2C3B-0000-4000-8000-000000000024"), conversationID: endedConversationID, topicID: nil,
            role: .system, text: "Reconnected.", startOffset: 130, endOffset: nil, asrConfidence: nil,
            voiceScore: nil, isFinal: true, source: .grok),
        UtteranceRow(
            id: uuid("6F1D2C3B-0000-4000-8000-000000000025"), conversationID: openConversationID,
            topicID: openTopicID, role: .user, text: "Remind me what Acme does", startOffset: 3_601,
            endOffset: nil, asrConfidence: 0.5, voiceScore: 0.61, isFinal: false, source: .parakeet),
    ]

    static let centroid: [Float] = (0..<256).map { Float($0) / 256 - 0.5 }
    static let clips: [[Float]] = (0..<3).map { clip in (0..<256).map { Float(clip) * 0.25 - Float($0) / 512 } }

    /// The expected relationship counts: conversations with their topic and
    /// utterance counts.
    static let topicCounts = [endedConversationID: 2, openConversationID: 1]
    static let utteranceCounts = [endedConversationID: 4, openConversationID: 1]

    /// Writes the fixture data with `SchemaV1`, the way a v1 build of the
    /// app does, into a new single-file store at `url`.
    static func write(to url: URL) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "blau-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let storeURL = scratch.appending(path: "Blau.store")
        try writeWithSwiftData(to: storeURL)
        try snapshot(storeURL, into: url)
    }

    private static func writeWithSwiftData(to url: URL) throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        try autoreleasepool {
            let configuration = ModelConfiguration(
                BlauCloud.syncedConfigurationName, schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            let ended = SchemaV1.Conversation(
                id: endedConversationID, startedAt: t0, endedAt: t0 + 600, title: "Monday planning")
            let open = SchemaV1.Conversation(id: openConversationID, startedAt: t0 + 3_600)
            context.insert(ended)
            context.insert(open)

            let intro = SchemaV1.Topic(
                id: introTopicID, conversation: ended, startedAt: t0 + 1, endedAt: t0 + 120, title: "Week plan",
                titleIsProvisional: false, summary: "- Plan the week", ordinal: 0)
            let fundraising = SchemaV1.Topic(
                id: fundraisingTopicID, conversation: ended, startedAt: t0 + 120, endedAt: t0 + 600,
                title: "Seed round", titleIsProvisional: false, summary: "- Raise after launch", ordinal: 1,
                colorSeed: 42)
            let current = SchemaV1.Topic(id: openTopicID, conversation: open, startedAt: t0 + 3_601)
            let topics = [intro.id: intro, fundraising.id: fundraising, current.id: current]
            for topic in topics.values { context.insert(topic) }

            let conversations = [ended.id: ended, open.id: open]
            for row in utterances {
                context.insert(
                    SchemaV1.Utterance(
                        id: row.id, conversation: conversations[row.conversationID],
                        topic: row.topicID.flatMap { topics[$0] }, role: row.role, text: row.text,
                        startedAt: t0 + row.startOffset, endedAt: row.endOffset.map { t0 + $0 },
                        asrConfidence: row.asrConfidence, voiceScore: row.voiceScore, isFinal: row.isFinal,
                        source: row.source))
            }

            let profile = SchemaV1.VoiceProfile(
                id: profileID, name: "Me", embeddingModelVersion: "wespeaker-resnet34-lm-v1", centroid: centroid,
                createdAt: t0, updatedAt: t0 + 60)
            context.insert(profile)
            context.insert(
                SchemaV1.VoiceEnrollmentSet(
                    profile: profile, deviceModel: "iPhone18,1", embeddings: clips, createdAt: t0))
            try context.save()
        }
    }

    /// Copies a consistent snapshot of the SQLite store at `source`, write-
    /// ahead log included, into a new self-contained file at `destination`
    /// in rollback-journal mode. SwiftData may keep `source` open, so this
    /// reads it with `VACUUM INTO` rather than checkpointing it. Core Data
    /// switches the copy back to WAL the next time it opens it.
    private static func snapshot(_ source: URL, into destination: URL) throws {
        try withDatabase(at: source, flags: SQLITE_OPEN_READONLY) { database in
            let path = destination.path(percentEncoded: false).replacingOccurrences(of: "'", with: "''")
            try execute("VACUUM INTO '\(path)';", in: database)
        }
        try withDatabase(at: destination, flags: SQLITE_OPEN_READWRITE) { database in
            try execute("PRAGMA journal_mode=DELETE;", in: database)
        }
    }

    private static func withDatabase(at url: URL, flags: Int32, _ body: (OpaquePointer?) throws -> Void) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path(percentEncoded: false), &database, flags, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("open \(url.lastPathComponent): \(String(cString: sqlite3_errmsg(database)))")
        }
        try body(database)
    }

    private static func execute(_ statement: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("\(statement) \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    enum FixtureError: Error {
        case sqlite(String)
        case missingResource
        case unconvertibleSchema
    }

    /// The checked-in store.
    static var bundledStoreURL: URL {
        get throws {
            guard
                let url = Bundle.module.url(
                    forResource: "Blau", withExtension: "store", subdirectory: "Fixtures/SchemaV1")
            else { throw FixtureError.missingResource }
            return url
        }
    }

    /// The Core Data entity version hashes recorded in the store at `url`.
    static func storedVersionHashes(at url: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        return metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]
    }

    /// The entity version hashes Core Data derives for `schema`.
    static func versionHashes(of schema: any VersionedSchema.Type) throws -> [String: Data] {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: schema)) else {
            throw FixtureError.unconvertibleSchema
        }
        return model.entityVersionHashesByName
    }
}
