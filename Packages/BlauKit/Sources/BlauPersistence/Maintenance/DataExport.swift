import Foundation
import SwiftData

/// Everything Blau keeps about the user, as plain values: Settings →
/// Privacy & Data → Export All Data (#79).
///
/// It is read from the synced store in one pass (``snapshot(in:exportedAt:app:)``)
/// and then formatted off the store: ``DataExporter`` writes it as JSON
/// (`blau-data.json`, this type encoded) and as Markdown.
///
/// Enumerations are exported as their stored raw values (`role`, `kind`,
/// `origin`...), so a value written by a newer app version on another
/// device is exported as it is rather than dropped.
///
/// The voiceprint is described (its model, when it was enrolled, on which
/// devices, with how many clips) but its vectors are left out. They are a
/// biometric template that only Blau's speaker model can use, and an
/// export is a file that gets shared and kept around; nothing the user can
/// read or take elsewhere is lost by leaving them out.
public struct DataExport: Codable, Hashable, Sendable {
    /// `format` of every Blau export, so a reader can recognize the file.
    public static let formatIdentifier = "com.joeblau.blau.export"
    /// Bumped when a field is removed or changes meaning. Adding a field
    /// doesn't bump it: readers ignore keys they don't know.
    public static let currentFormatVersion = 1

    public var format: String = Self.formatIdentifier
    public var formatVersion: Int = Self.currentFormatVersion
    public var exportedAt: Date
    /// The SwiftData schema the records come from, e.g. "2.0.0".
    public var schemaVersion: String
    /// The app that exported, e.g. "Blau 0.1.0 (1)".
    public var app: String?

    public var conversations: [ConversationRecord]
    public var documents: [DocumentRecord]
    public var entities: [EntityRecord]
    public var facts: [FactRecord]
    public var profileBlocks: [ProfileBlockRecord]
    public var voiceprints: [VoiceprintRecord]

    public init(
        exportedAt: Date, schemaVersion: String, app: String? = nil, conversations: [ConversationRecord] = [],
        documents: [DocumentRecord] = [], entities: [EntityRecord] = [], facts: [FactRecord] = [],
        profileBlocks: [ProfileBlockRecord] = [], voiceprints: [VoiceprintRecord] = []
    ) {
        self.exportedAt = exportedAt
        self.schemaVersion = schemaVersion
        self.app = app
        self.conversations = conversations
        self.documents = documents
        self.entities = entities
        self.facts = facts
        self.profileBlocks = profileBlocks
        self.voiceprints = voiceprints
    }

    // MARK: Records

    public struct ConversationRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var title: String?
        public var startedAt: Date
        public var endedAt: Date?
        public var topics: [TopicRecord]
        /// In spoken order, partials (`isFinal == false`) included.
        public var utterances: [UtteranceRecord]

        public init(
            id: UUID, title: String?, startedAt: Date, endedAt: Date?, topics: [TopicRecord],
            utterances: [UtteranceRecord]
        ) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.topics = topics
            self.utterances = utterances
        }
    }

    public struct TopicRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var title: String
        public var titleIsProvisional: Bool
        public var summary: String?
        public var ordinal: Int
        public var startedAt: Date
        public var endedAt: Date?

        public init(
            id: UUID, title: String, titleIsProvisional: Bool, summary: String?, ordinal: Int, startedAt: Date,
            endedAt: Date?
        ) {
            self.id = id
            self.title = title
            self.titleIsProvisional = titleIsProvisional
            self.summary = summary
            self.ordinal = ordinal
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    public struct UtteranceRecord: Codable, Hashable, Sendable {
        public var id: UUID
        /// The `TopicRecord.id` it belongs to, if any.
        public var topicID: UUID?
        /// `user`, `agent` or `system`.
        public var role: String
        public var text: String
        public var startedAt: Date
        public var endedAt: Date?
        public var isFinal: Bool
        /// `parakeet`, `speechanalyzer` or `grok`.
        public var source: String
        public var asrConfidence: Double?
        public var voiceScore: Double?
        /// `interrupted`, `bargedin` or `stopped` for a reply the user cut
        /// short (schema v3, #160); absent otherwise.
        public var endReason: String?

        public init(
            id: UUID, topicID: UUID?, role: String, text: String, startedAt: Date, endedAt: Date?, isFinal: Bool,
            source: String, asrConfidence: Double? = nil, voiceScore: Double? = nil, endReason: String? = nil
        ) {
            self.id = id
            self.topicID = topicID
            self.role = role
            self.text = text
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isFinal = isFinal
            self.source = source
            self.asrConfidence = asrConfidence
            self.voiceScore = voiceScore
            self.endReason = endReason
        }
    }

    public struct DocumentRecord: Codable, Hashable, Sendable {
        public var id: UUID
        /// `note`, `company`, `profile` or `collection`.
        public var kind: String
        public var title: String
        public var body: String
        public var createdAt: Date
        public var updatedAt: Date
        /// A collection's prompts, in order. Empty for other kinds.
        public var collectionItems: [CollectionItemRecord]

        public init(
            id: UUID, kind: String, title: String, body: String, createdAt: Date, updatedAt: Date,
            collectionItems: [CollectionItemRecord] = []
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.collectionItems = collectionItems
        }
    }

    public struct CollectionItemRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var ordinal: Int
        public var prompt: String
        public var referenceAnswer: String?
        public var createdAt: Date
        public var lastPracticedAt: Date?
        public var practiceCount: Int
        public var score: Double?

        public init(
            id: UUID, ordinal: Int, prompt: String, referenceAnswer: String?, createdAt: Date, lastPracticedAt: Date?,
            practiceCount: Int, score: Double?
        ) {
            self.id = id
            self.ordinal = ordinal
            self.prompt = prompt
            self.referenceAnswer = referenceAnswer
            self.createdAt = createdAt
            self.lastPracticedAt = lastPracticedAt
            self.practiceCount = practiceCount
            self.score = score
        }
    }

    public struct EntityRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        /// `person`, `organization`, `place`...
        public var type: String
        public var aliases: [String]
        public var summary: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: UUID, name: String, type: String, aliases: [String], summary: String?, createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.aliases = aliases
            self.summary = summary
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct FactRecord: Codable, Hashable, Sendable {
        public var id: UUID
        /// The `EntityRecord.id` the fact is about; `nil` for the user.
        public var subjectID: UUID?
        public var predicate: String
        public var object: String
        /// The fact as one sentence, e.g. "Acme raised a $2M seed round"
        /// ("User ..." for a fact about the user).
        public var statement: String
        public var validFrom: Date
        /// When it stopped being true; `nil` while current.
        public var invalidatedAt: Date?
        public var confidence: Double
        /// `extracted` or `user`.
        public var origin: String
        /// The utterance it was learned from, if it is still stored.
        public var sourceUtteranceID: UUID?
        public var createdAt: Date

        public init(
            id: UUID, subjectID: UUID?, predicate: String, object: String, statement: String, validFrom: Date,
            invalidatedAt: Date?, confidence: Double, origin: String, sourceUtteranceID: UUID?, createdAt: Date
        ) {
            self.id = id
            self.subjectID = subjectID
            self.predicate = predicate
            self.object = object
            self.statement = statement
            self.validFrom = validFrom
            self.invalidatedAt = invalidatedAt
            self.confidence = confidence
            self.origin = origin
            self.sourceUtteranceID = sourceUtteranceID
            self.createdAt = createdAt
        }

        public var isCurrent: Bool { invalidatedAt == nil }
    }

    public struct ProfileBlockRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var key: String
        public var text: String
        public var updatedAt: Date

        public init(id: UUID, key: String, text: String, updatedAt: Date) {
            self.id = id
            self.key = key
            self.text = text
            self.updatedAt = updatedAt
        }
    }

    /// A voiceprint without its vectors (see ``DataExport``).
    public struct VoiceprintRecord: Codable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var embeddingModelVersion: String
        public var createdAt: Date
        public var updatedAt: Date
        public var enrollmentSets: [EnrollmentSetRecord]

        public init(
            id: UUID, name: String, embeddingModelVersion: String, createdAt: Date, updatedAt: Date,
            enrollmentSets: [EnrollmentSetRecord]
        ) {
            self.id = id
            self.name = name
            self.embeddingModelVersion = embeddingModelVersion
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.enrollmentSets = enrollmentSets
        }
    }

    public struct EnrollmentSetRecord: Codable, Hashable, Sendable {
        /// The recording device's model identifier, e.g. "iPhone18,1".
        public var deviceModel: String
        public var clipCount: Int
        public var createdAt: Date

        public init(deviceModel: String, clipCount: Int, createdAt: Date) {
            self.deviceModel = deviceModel
            self.clipCount = clipCount
            self.createdAt = createdAt
        }
    }
}

// MARK: - Reading the store

extension DataExport {
    /// Reads every record in `context`'s store.
    ///
    /// Ordering is deterministic so two exports of the same data are the
    /// same file: conversations and facts oldest first (ties by id),
    /// documents by kind then age, entities by name, topics and utterances
    /// in spoken order, profile blocks newest first.
    public static func snapshot(in context: ModelContext, exportedAt date: Date, app: String? = nil) throws
        -> DataExport
    {
        let conversations = try context.fetch(FetchDescriptor<Conversation>())
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            .map(record(_:))
        let documents = try context.fetch(FetchDescriptor<MemoryDocument>())
            .sorted {
                (kindOrder($0.kindRaw), $0.createdAt, $0.id.uuidString)
                    < (kindOrder($1.kindRaw), $1.createdAt, $1.id.uuidString)
            }
            .map(record(_:))
        let entities = try context.fetch(FetchDescriptor<MemoryEntity>())
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
            .map(record(_:))
        let facts = try context.fetch(FetchDescriptor<Fact>())
            .sorted { ($0.createdAt, $0.validFrom, $0.id.uuidString) < ($1.createdAt, $1.validFrom, $1.id.uuidString) }
            .map(record(_:))
        let blocks = try context.fetch(FetchDescriptor<ProfileBlock>())
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
            .map { ProfileBlockRecord(id: $0.id, key: $0.key, text: $0.text, updatedAt: $0.updatedAt) }
        let voiceprints = try context.fetch(FetchDescriptor<VoiceProfile>())
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map(record(_:))
        let version = CurrentSchema.versionIdentifier
        return DataExport(
            exportedAt: date, schemaVersion: "\(version.major).\(version.minor).\(version.patch)", app: app,
            conversations: conversations, documents: documents, entities: entities, facts: facts,
            profileBlocks: blocks, voiceprints: voiceprints)
    }

    /// The user's own pages first: About Me, Company, Notes, Collections,
    /// then kinds this version doesn't know.
    private static func kindOrder(_ raw: String) -> Int {
        switch DocumentKind(rawValue: raw) {
        case .profile: 0
        case .company: 1
        case .note: 2
        case .collection: 3
        case nil: 4
        }
    }

    private static func record(_ conversation: Conversation) -> ConversationRecord {
        ConversationRecord(
            id: conversation.id, title: conversation.title, startedAt: conversation.startedAt,
            endedAt: conversation.endedAt,
            topics: conversation.orderedTopics.map { topic in
                TopicRecord(
                    id: topic.id, title: topic.title, titleIsProvisional: topic.titleIsProvisional,
                    summary: topic.summary, ordinal: topic.ordinal, startedAt: topic.startedAt, endedAt: topic.endedAt)
            },
            utterances: conversation.orderedUtterances.map { utterance in
                UtteranceRecord(
                    id: utterance.id, topicID: utterance.topic?.id, role: utterance.roleRaw, text: utterance.text,
                    startedAt: utterance.startedAt, endedAt: utterance.endedAt, isFinal: utterance.isFinal,
                    source: utterance.sourceRaw, asrConfidence: utterance.asrConfidence,
                    voiceScore: utterance.voiceScore, endReason: utterance.endReasonRaw)
            })
    }

    private static func record(_ document: MemoryDocument) -> DocumentRecord {
        DocumentRecord(
            id: document.id, kind: document.kindRaw, title: document.title, body: document.body,
            createdAt: document.createdAt, updatedAt: document.updatedAt,
            collectionItems: document.orderedCollectionItems.map { item in
                CollectionItemRecord(
                    id: item.id, ordinal: item.ordinal, prompt: item.prompt, referenceAnswer: item.referenceAnswer,
                    createdAt: item.createdAt, lastPracticedAt: item.lastPracticedAt,
                    practiceCount: item.practiceCount, score: item.score)
            })
    }

    private static func record(_ entity: MemoryEntity) -> EntityRecord {
        EntityRecord(
            id: entity.id, name: entity.name, type: entity.typeRaw, aliases: entity.aliasNames,
            summary: entity.summary, createdAt: entity.createdAt, updatedAt: entity.updatedAt)
    }

    private static func record(_ fact: Fact) -> FactRecord {
        FactRecord(
            id: fact.id, subjectID: fact.subject?.id, predicate: fact.predicate, object: fact.objectText,
            statement: fact.statement(), validFrom: fact.validFrom,
            invalidatedAt: fact.invalidatedAt, confidence: fact.confidence, origin: fact.originRaw,
            sourceUtteranceID: fact.sourceUtteranceID, createdAt: fact.createdAt)
    }

    private static func record(_ profile: VoiceProfile) -> VoiceprintRecord {
        VoiceprintRecord(
            id: profile.id, name: profile.name, embeddingModelVersion: profile.embeddingModelVersion,
            createdAt: profile.createdAt, updatedAt: profile.updatedAt,
            enrollmentSets: (profile.enrollmentSets ?? [])
                .sorted { $0.createdAt < $1.createdAt }
                .map {
                    EnrollmentSetRecord(deviceModel: $0.deviceModel, clipCount: $0.clipCount, createdAt: $0.createdAt)
                })
    }
}

// MARK: - Counts

extension DataExport {
    /// How much the export holds, for the UI and the README.
    public struct Counts: Hashable, Sendable {
        public var conversations: Int
        public var utterances: Int
        public var documents: Int
        public var facts: Int
        public var entities: Int
        public var voiceprints: Int

        public init(conversations: Int, utterances: Int, documents: Int, facts: Int, entities: Int, voiceprints: Int) {
            self.conversations = conversations
            self.utterances = utterances
            self.documents = documents
            self.facts = facts
            self.entities = entities
            self.voiceprints = voiceprints
        }
    }

    public var counts: Counts {
        Counts(
            conversations: conversations.count,
            utterances: conversations.reduce(0) { $0 + $1.utterances.count },
            documents: documents.count, facts: facts.count, entities: entities.count, voiceprints: voiceprints.count)
    }

    /// Whether there is nothing to export.
    public var isEmpty: Bool {
        conversations.isEmpty && documents.isEmpty && entities.isEmpty && facts.isEmpty && profileBlocks.isEmpty
            && voiceprints.isEmpty
    }
}
