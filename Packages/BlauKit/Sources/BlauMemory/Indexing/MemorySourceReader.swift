import Foundation

/// One source a full pass visits, with the date it is ordered by.
public struct MemorySourceStamp: Hashable, Sendable {
    /// `.conversation`, `.document` or `.fact`. Collection items are read
    /// with their document.
    public var kind: MemorySourceKind
    public var id: UUID
    /// A conversation's start, a document's last edit, a fact's
    /// `validFrom`.
    public var date: Date

    public init(kind: MemorySourceKind, id: UUID, date: Date) {
        self.kind = kind
        self.id = id
        self.date = date
    }
}

/// Sources read by id, as snapshots.
public struct MemorySourceBatch: Sendable {
    /// The conversations found; requested ids that are missing were
    /// deleted.
    public var conversations: [ConversationSnapshot]
    /// Facts extracted from those conversations' utterances
    /// (`FactSnapshot.sourceUtteranceID`), ordered by `validFrom`, then
    /// id, as `MemorySourceProvider.facts()` orders them, so the exchange
    /// keys come out exactly as a full rebuild writes them.
    public var exchangeFacts: [FactSnapshot]
    /// The documents found, with their collection items.
    public var documents: [DocumentSnapshot]
    /// The facts found.
    public var facts: [FactSnapshot]

    public init(
        conversations: [ConversationSnapshot] = [],
        exchangeFacts: [FactSnapshot] = [],
        documents: [DocumentSnapshot] = [],
        facts: [FactSnapshot] = []
    ) {
        self.conversations = conversations
        self.exchangeFacts = exchangeFacts
        self.documents = documents
        self.facts = facts
    }
}

/// What the incremental indexer (#63) reads the synced store through:
/// sources by id (for changed sources and resumable rebuilds), the ids of
/// every source (to remove orphans), and every source with its date (to
/// rebuild newest first).
///
/// `SwiftDataMemorySources` is the production implementation; tests use
/// in-memory snapshots.
public protocol MemorySourceReader: Sendable {
    /// Every conversation, document and fact with the date a full pass
    /// orders it by.
    func stamps() async throws -> [MemorySourceStamp]

    /// The ids of every source of `kind` that the index should hold. For
    /// `.collectionItem`, the items that belong to a document.
    func sourceIDs(_ kind: MemorySourceKind) async throws -> Set<UUID>

    /// The sources with these ids that exist. CloudKit duplicates are
    /// merged the way `MemorySourceProvider` merges them.
    func read(conversations: Set<UUID>, documents: Set<UUID>, facts: Set<UUID>) async throws -> MemorySourceBatch
}
