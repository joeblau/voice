import Foundation

/// The memory sources a batch of store changes touched: what the
/// incremental indexer (#63) re-reads, re-chunks and (where the key text
/// changed) re-embeds.
///
/// `SwiftDataMemoryChangeResolver` builds one from a `StoreChangeSet` (the
/// synced store's persistent history). Changed records are traced to the
/// source whose chunks they appear in: an utterance or topic to its
/// conversation, a collection item to its document, a fact to itself and
/// to the conversation it was extracted from. A deleted record can't be
/// read any more, so a deletion asks for a sweep of its kind instead: the
/// indexer compares the index's sources of that kind with the store's and
/// removes the orphans.
public struct MemorySourceChanges: Hashable, Sendable {
    /// Conversations to re-chunk (or remove, if they no longer exist).
    public var conversations: Set<UUID>
    /// Documents to re-chunk with their collection items.
    public var documents: Set<UUID>
    /// Facts to re-chunk. The conversations whose exchange keys list them
    /// are re-chunked too.
    public var facts: Set<UUID>
    /// Kinds that lost records: their orphans are removed.
    public var sweeps: Set<MemorySourceKind>
    /// The changes can't be known (the history cursor had expired), so
    /// every source must be read again.
    public var requiresFullPass: Bool
    /// Transactions CloudKit imported from another device, for the log.
    public var importedTransactions: Int

    public init(
        conversations: Set<UUID> = [],
        documents: Set<UUID> = [],
        facts: Set<UUID> = [],
        sweeps: Set<MemorySourceKind> = [],
        requiresFullPass: Bool = false,
        importedTransactions: Int = 0
    ) {
        self.conversations = conversations
        self.documents = documents
        self.facts = facts
        self.sweeps = sweeps
        self.requiresFullPass = requiresFullPass
        self.importedTransactions = importedTransactions
    }

    /// Nothing to do.
    public var isEmpty: Bool {
        conversations.isEmpty && documents.isEmpty && facts.isEmpty && sweeps.isEmpty && !requiresFullPass
    }

    /// Sources to re-read.
    public var sourceCount: Int { conversations.count + documents.count + facts.count }

    /// Adds `other`'s sources and sweeps to these.
    public mutating func formUnion(_ other: MemorySourceChanges) {
        conversations.formUnion(other.conversations)
        documents.formUnion(other.documents)
        facts.formUnion(other.facts)
        sweeps.formUnion(other.sweeps)
        requiresFullPass = requiresFullPass || other.requiresFullPass
        importedTransactions += other.importedTransactions
    }
}
