import BlauPersistence
import Foundation

// Sendable copies of the SwiftData records the index is built from. The
// chunker and the rebuilder work on these, never on `@Model` objects, so
// they run off the model context's queue and are tested without SwiftData.

/// A conversation with its topics and utterances.
public struct ConversationSnapshot: Identifiable, Hashable, Sendable {
    public struct TopicSnapshot: Identifiable, Hashable, Sendable {
        public var id: UUID
        /// The topic's title, or `nil` while it is the placeholder
        /// (`Topic.placeholderTitle`).
        public var title: String?

        public init(id: UUID, title: String?) {
            self.id = id
            self.title = title
        }
    }

    public struct UtteranceSnapshot: Identifiable, Hashable, Sendable {
        public var id: UUID
        /// `nil` for a role written by a newer app version.
        public var role: UtteranceRole?
        public var text: String
        public var startedAt: Date
        public var topicID: UUID?

        public init(id: UUID, role: UtteranceRole?, text: String, startedAt: Date, topicID: UUID? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.startedAt = startedAt
            self.topicID = topicID
        }
    }

    public var id: UUID
    public var startedAt: Date
    public var topics: [TopicSnapshot]
    /// In any order; the chunker orders them by `startedAt`.
    public var utterances: [UtteranceSnapshot]

    public init(id: UUID, startedAt: Date, topics: [TopicSnapshot] = [], utterances: [UtteranceSnapshot]) {
        self.id = id
        self.startedAt = startedAt
        self.topics = topics
        self.utterances = utterances
    }
}

/// A knowledge-base document and, for a collection, its items.
public struct DocumentSnapshot: Identifiable, Hashable, Sendable {
    public struct ItemSnapshot: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var ordinal: Int
        public var prompt: String
        public var referenceAnswer: String?
        public var createdAt: Date

        public init(id: UUID, ordinal: Int, prompt: String, referenceAnswer: String? = nil, createdAt: Date) {
            self.id = id
            self.ordinal = ordinal
            self.prompt = prompt
            self.referenceAnswer = referenceAnswer
            self.createdAt = createdAt
        }
    }

    public var id: UUID
    /// `nil` for a kind written by a newer app version.
    public var kind: DocumentKind?
    public var title: String
    public var body: String
    public var updatedAt: Date
    /// The collection's items; empty for other kinds.
    public var items: [ItemSnapshot]

    public init(
        id: UUID, kind: DocumentKind?, title: String, body: String, updatedAt: Date, items: [ItemSnapshot] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
        self.items = items
    }
}

/// One fact, as the sentence the index stores.
public struct FactSnapshot: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `Fact.statement()`, e.g. "Acme raised a $2M seed round".
    public var statement: String
    public var validFrom: Date
    public var invalidatedAt: Date?
    /// The utterance it was extracted from, which puts it in that
    /// exchange's key text.
    public var sourceUtteranceID: UUID?

    public init(
        id: UUID, statement: String, validFrom: Date, invalidatedAt: Date? = nil, sourceUtteranceID: UUID? = nil
    ) {
        self.id = id
        self.statement = statement
        self.validFrom = validFrom
        self.invalidatedAt = invalidatedAt
        self.sourceUtteranceID = sourceUtteranceID
    }
}

/// Reads the synced store for the index. `SwiftDataMemorySources` is the
/// production implementation; tests pass in-memory snapshots.
public protocol MemorySourceProvider: Sendable {
    /// Every conversation's id, oldest first.
    func conversationIDs() async throws -> [UUID]
    /// The conversations with these ids (missing ones are skipped).
    func conversations(_ ids: [UUID]) async throws -> [ConversationSnapshot]
    /// Every knowledge-base document with its collection items.
    func documents() async throws -> [DocumentSnapshot]
    /// Every fact, current and invalidated.
    func facts() async throws -> [FactSnapshot]
}
