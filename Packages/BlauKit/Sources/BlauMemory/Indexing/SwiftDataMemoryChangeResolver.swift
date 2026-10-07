import BlauPersistence
import Foundation
import SwiftData

/// Traces the records a `StoreChangeSet` names to the memory sources whose
/// chunks they appear in (#63).
///
/// | Changed record | Re-chunked source |
/// | --- | --- |
/// | `Conversation` | itself |
/// | `Utterance`, `Topic` | its conversation (a topic's title is in its exchanges' keys) |
/// | `Document` | itself, with its collection items (their keys hold its title) |
/// | `CollectionItem` | its document |
/// | `Fact` | itself, and the conversation of the utterance it was extracted from (it is in that exchange's key) |
/// | `MemoryEntity` | its facts (their statements start with its name), and their conversations |
///
/// A deleted record can't be fetched, so deletions become sweeps: the
/// indexer removes the index's sources of that kind that are no longer in
/// the store. A deleted utterance, topic or collection item needs no sweep
/// of its own: SwiftData records an update of the conversation or document
/// whose to-many relationship lost it, which re-chunks that source.
/// Deleting a fact sweeps facts, and the index's `fact_link` table names
/// the conversations whose keys listed it.
public struct SwiftDataMemoryChangeResolver: Sendable {
    /// Must be the container the history was read from: persistent
    /// identifiers only match within one container.
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func resolve(_ changes: StoreChangeSet) throws -> MemorySourceChanges {
        var result = MemorySourceChanges(importedTransactions: changes.importedTransactionCount)
        if changes.historyWasReset {
            result.requiresFullPass = true
            return result
        }
        let context = ModelContext(container)

        let conversations = changes.changes(to: Conversation.self)
        for record in try fetch(Conversation.self, live(conversations), in: context) {
            result.conversations.insert(record.id)
        }
        if !conversations.deleted.isEmpty { result.sweeps.insert(.conversation) }

        for record in try fetch(StoredUtterance.self, live(changes.changes(to: StoredUtterance.self)), in: context) {
            if let conversation = record.conversation { result.conversations.insert(conversation.id) }
        }
        for record in try fetch(Topic.self, live(changes.changes(to: Topic.self)), in: context) {
            if let conversation = record.conversation { result.conversations.insert(conversation.id) }
        }

        let documents = changes.changes(to: MemoryDocument.self)
        for record in try fetch(MemoryDocument.self, live(documents), in: context) {
            result.documents.insert(record.id)
        }
        if !documents.deleted.isEmpty { result.sweeps.formUnion([.document, .collectionItem]) }

        let items = changes.changes(to: CollectionItem.self)
        for record in try fetch(CollectionItem.self, live(items), in: context) {
            if let document = record.document { result.documents.insert(document.id) }
        }
        // An item moved out of its document, or deleted, leaves chunks
        // only a sweep finds.
        if !items.deleted.isEmpty || !items.updated.isEmpty { result.sweeps.insert(.collectionItem) }

        var factUtterances = Set<UUID>()
        let facts = changes.changes(to: Fact.self)
        for record in try fetch(Fact.self, live(facts), in: context) {
            result.facts.insert(record.id)
            if let utterance = record.sourceUtteranceID { factUtterances.insert(utterance) }
        }
        if !facts.deleted.isEmpty { result.sweeps.insert(.fact) }

        for entity in try fetch(MemoryEntity.self, live(changes.changes(to: MemoryEntity.self)), in: context) {
            for fact in entity.facts ?? [] {
                result.facts.insert(fact.id)
                if let utterance = fact.sourceUtteranceID { factUtterances.insert(utterance) }
            }
        }

        // The conversations the changed facts were extracted from.
        for ids in SwiftDataMemorySources.batches(Array(factUtterances)) {
            let utterances = try context.fetch(
                FetchDescriptor<StoredUtterance>(predicate: #Predicate { ids.contains($0.id) }))
            for utterance in utterances {
                if let conversation = utterance.conversation { result.conversations.insert(conversation.id) }
            }
        }
        return result
    }

    private func live(_ changes: StoreChangeSet.Changes) -> [PersistentIdentifier] {
        Array(changes.inserted.union(changes.updated))
    }

    /// The records with these identifiers that still exist (one may have
    /// been deleted after the history was read).
    private func fetch<Model: PersistentModel>(
        _ type: Model.Type, _ identifiers: [PersistentIdentifier], in context: ModelContext
    ) throws -> [Model] {
        var records: [Model] = []
        for ids in SwiftDataMemorySources.batches(identifiers) {
            records += try context.fetch(
                FetchDescriptor<Model>(predicate: #Predicate { ids.contains($0.persistentModelID) }))
        }
        return records
    }
}
