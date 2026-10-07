import BlauPersistence
import Foundation
import SwiftData

/// Reads the synced SwiftData store for the memory index, as Sendable
/// snapshots.
///
/// Each call uses its own `ModelContext` and finishes with it before
/// returning, so it can run on any task without touching the UI's context.
/// CloudKit can't enforce uniqueness, so two records can share an id (the
/// same record created on two devices while offline); they are merged on
/// read: a conversation's topics and utterances are combined (one per id),
/// the most recently edited copy of a document wins, and a fact keeps the
/// earliest invalidation.
///
/// It is both the full rebuild's `MemorySourceProvider` and the incremental
/// indexer's `MemorySourceReader` (#63), which reads sources by id.
public struct SwiftDataMemorySources: MemorySourceProvider, MemorySourceReader {
    public let container: ModelContainer

    /// Ids per `IN (...)` query, well under SQLite's variable limit.
    static let queryBatchSize = 500

    public init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - MemorySourceProvider

    public func conversationIDs() async throws -> [UUID] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.id)])
        descriptor.propertiesToFetch = [\.id, \.startedAt]
        var seen = Set<UUID>()
        return try context.fetch(descriptor).map(\.id).filter { seen.insert($0).inserted }
    }

    public func conversations(_ ids: [UUID]) async throws -> [ConversationSnapshot] {
        guard !ids.isEmpty else { return [] }
        let context = ModelContext(container)
        var records: [Conversation] = []
        for batch in Self.batches(Array(Set(ids))) {
            records += try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { batch.contains($0.id) }))
        }
        let byID = Dictionary(grouping: records, by: \.id)
        return ids.compactMap { id in byID[id].flatMap { Self.snapshot(id: id, copies: $0) } }
    }

    public func documents() async throws -> [DocumentSnapshot] {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<MemoryDocument>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
        return Self.documentSnapshots(records)
    }

    public func facts() async throws -> [FactSnapshot] {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.validFrom), SortDescriptor(\.id)]))
        return Self.factSnapshots(records)
    }

    // MARK: - MemorySourceReader

    public func stamps() async throws -> [MemorySourceStamp] {
        let context = ModelContext(container)
        var conversations: [UUID: Date] = [:]
        var conversationDescriptor = FetchDescriptor<Conversation>()
        conversationDescriptor.propertiesToFetch = [\.id, \.startedAt]
        for record in try context.fetch(conversationDescriptor) {
            conversations[record.id] = min(conversations[record.id] ?? record.startedAt, record.startedAt)
        }
        var documents: [UUID: Date] = [:]
        var documentDescriptor = FetchDescriptor<MemoryDocument>()
        documentDescriptor.propertiesToFetch = [\.id, \.updatedAt]
        for record in try context.fetch(documentDescriptor) {
            documents[record.id] = max(documents[record.id] ?? record.updatedAt, record.updatedAt)
        }
        var facts: [UUID: Date] = [:]
        var factDescriptor = FetchDescriptor<Fact>()
        factDescriptor.propertiesToFetch = [\.id, \.validFrom]
        for record in try context.fetch(factDescriptor) {
            facts[record.id] = min(facts[record.id] ?? record.validFrom, record.validFrom)
        }
        return conversations.map { MemorySourceStamp(kind: .conversation, id: $0.key, date: $0.value) }
            + documents.map { MemorySourceStamp(kind: .document, id: $0.key, date: $0.value) }
            + facts.map { MemorySourceStamp(kind: .fact, id: $0.key, date: $0.value) }
    }

    public func sourceIDs(_ kind: MemorySourceKind) async throws -> Set<UUID> {
        let context = ModelContext(container)
        switch kind {
        case .conversation:
            var descriptor = FetchDescriptor<Conversation>()
            descriptor.propertiesToFetch = [\.id]
            return Set(try context.fetch(descriptor).map(\.id))
        case .document:
            var descriptor = FetchDescriptor<MemoryDocument>()
            descriptor.propertiesToFetch = [\.id]
            return Set(try context.fetch(descriptor).map(\.id))
        case .collectionItem:
            // Only items in a document are indexed (keyed with its title).
            var descriptor = FetchDescriptor<CollectionItem>(predicate: #Predicate { $0.document != nil })
            descriptor.propertiesToFetch = [\.id]
            return Set(try context.fetch(descriptor).map(\.id))
        case .fact:
            var descriptor = FetchDescriptor<Fact>()
            descriptor.propertiesToFetch = [\.id]
            return Set(try context.fetch(descriptor).map(\.id))
        }
    }

    public func read(
        conversations conversationIDs: Set<UUID>, documents documentIDs: Set<UUID>, facts factIDs: Set<UUID>
    )
        async throws -> MemorySourceBatch
    {
        let context = ModelContext(container)
        var batch = MemorySourceBatch()

        if !conversationIDs.isEmpty {
            var records: [Conversation] = []
            for ids in Self.batches(Array(conversationIDs)) {
                records += try context.fetch(
                    FetchDescriptor<Conversation>(predicate: #Predicate { ids.contains($0.id) }))
            }
            let byID = Dictionary(grouping: records, by: \.id)
            batch.conversations = byID.compactMap { Self.snapshot(id: $0.key, copies: $0.value) }
                .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }

            var factRecords: [Fact] = []
            let utteranceIDs = batch.conversations.flatMap { $0.utterances.map(\.id) }
            for ids in Self.batches(utteranceIDs) {
                factRecords += try context.fetch(
                    FetchDescriptor<Fact>(
                        predicate: #Predicate { fact in fact.sourceUtteranceID.flatMap { ids.contains($0) } ?? false }))
            }
            batch.exchangeFacts = Self.factSnapshots(Self.sortedFacts(factRecords))
        }

        if !documentIDs.isEmpty {
            var records: [MemoryDocument] = []
            for ids in Self.batches(Array(documentIDs)) {
                records += try context.fetch(
                    FetchDescriptor<MemoryDocument>(predicate: #Predicate { ids.contains($0.id) }))
            }
            batch.documents = Self.documentSnapshots(records)
        }

        if !factIDs.isEmpty {
            var records: [Fact] = []
            for ids in Self.batches(Array(factIDs)) {
                records += try context.fetch(FetchDescriptor<Fact>(predicate: #Predicate { ids.contains($0.id) }))
            }
            batch.facts = Self.factSnapshots(Self.sortedFacts(records))
        }
        return batch
    }

    // MARK: - Merging CloudKit duplicates

    /// One snapshot of every copy of a conversation: topics and utterances
    /// combined, one per id.
    static func snapshot(id: UUID, copies: [Conversation]) -> ConversationSnapshot? {
        guard let first = copies.first else { return nil }
        var topics: [UUID: ConversationSnapshot.TopicSnapshot] = [:]
        var utterances: [UUID: ConversationSnapshot.UtteranceSnapshot] = [:]
        for copy in copies {
            for topic in copy.topics ?? [] where topics[topic.id] == nil {
                topics[topic.id] = ConversationSnapshot.TopicSnapshot(id: topic.id, title: Self.title(of: topic))
            }
            for utterance in copy.utterances ?? [] where utterance.isFinal && utterances[utterance.id] == nil {
                utterances[utterance.id] = ConversationSnapshot.UtteranceSnapshot(
                    id: utterance.id, role: utterance.role, text: utterance.text,
                    startedAt: utterance.startedAt, topicID: utterance.topic?.id)
            }
        }
        return ConversationSnapshot(
            id: id, startedAt: copies.map(\.startedAt).min() ?? first.startedAt,
            topics: topics.values.sorted { $0.id.uuidString < $1.id.uuidString },
            utterances: utterances.values.sorted {
                ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString)
            })
    }

    /// One snapshot per document id, in the order the ids first appear:
    /// the most recently edited copy wins, items of every copy combined.
    static func documentSnapshots(_ records: [MemoryDocument]) -> [DocumentSnapshot] {
        var order: [UUID] = []
        var byID: [UUID: [MemoryDocument]] = [:]
        for record in records {
            if byID[record.id] == nil { order.append(record.id) }
            byID[record.id, default: []].append(record)
        }
        return order.compactMap { id in
            guard let copies = byID[id],
                let latest = copies.max(by: { ($0.updatedAt, $0.contentHash) < ($1.updatedAt, $1.contentHash) })
            else { return nil }
            var items: [UUID: DocumentSnapshot.ItemSnapshot] = [:]
            for copy in copies {
                for item in copy.collectionItems ?? [] where items[item.id] == nil {
                    items[item.id] = DocumentSnapshot.ItemSnapshot(
                        id: item.id, ordinal: item.ordinal, prompt: item.prompt,
                        referenceAnswer: item.referenceAnswer, createdAt: item.createdAt)
                }
            }
            return DocumentSnapshot(
                id: id, kind: latest.kind, title: latest.title, body: latest.body, updatedAt: latest.updatedAt,
                items: items.values.sorted {
                    ($0.ordinal, $0.createdAt, $0.id.uuidString) < ($1.ordinal, $1.createdAt, $1.id.uuidString)
                })
        }
    }

    /// One snapshot per fact id, in the order the ids first appear; a
    /// duplicated fact keeps its earliest invalidation.
    static func factSnapshots(_ records: [Fact]) -> [FactSnapshot] {
        var order: [UUID] = []
        var byID: [UUID: FactSnapshot] = [:]
        for record in records {
            if var existing = byID[record.id] {
                if let invalidatedAt = record.invalidatedAt {
                    existing.invalidatedAt = min(existing.invalidatedAt ?? invalidatedAt, invalidatedAt)
                    byID[record.id] = existing
                }
                continue
            }
            order.append(record.id)
            byID[record.id] = FactSnapshot(
                id: record.id, statement: record.statement(), validFrom: record.validFrom,
                invalidatedAt: record.invalidatedAt, sourceUtteranceID: record.sourceUtteranceID)
        }
        return order.compactMap { byID[$0] }
    }

    /// Facts in `facts()`'s order: `validFrom`, then id (SwiftData sorts
    /// UUIDs by their string form).
    static func sortedFacts(_ records: [Fact]) -> [Fact] {
        records.sorted { ($0.validFrom, $0.id.uuidString) < ($1.validFrom, $1.id.uuidString) }
    }

    static func batches<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: queryBatchSize).map {
            Array(values[$0..<min(values.count, $0 + queryBatchSize)])
        }
    }

    /// Every entity with its aliases and every fact's subject and validity,
    /// for entity expansion in hybrid retrieval (#64). Entities CloudKit
    /// duplicated are merged by id (aliases combined); a duplicated fact
    /// keeps its earliest invalidation, as in `facts()`.
    public func entityGraph() async throws -> MemoryEntityGraph {
        let context = ModelContext(container)
        let entities = try context.fetch(
            FetchDescriptor<MemoryEntity>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        ).map { entity in
            MemoryEntityGraph.Entity(id: entity.id, name: entity.name, aliases: entity.aliasNames, type: entity.type)
        }
        var order: [UUID] = []
        var links: [UUID: MemoryEntityGraph.FactLink] = [:]
        for fact in try context.fetch(
            FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.validFrom), SortDescriptor(\.id)]))
        {
            if var existing = links[fact.id] {
                if let invalidatedAt = fact.invalidatedAt {
                    existing.invalidatedAt = min(existing.invalidatedAt ?? invalidatedAt, invalidatedAt)
                }
                if existing.subjectID == nil { existing.subjectID = fact.subject?.id }
                links[fact.id] = existing
                continue
            }
            order.append(fact.id)
            links[fact.id] = MemoryEntityGraph.FactLink(
                id: fact.id, subjectID: fact.subject?.id, validFrom: fact.validFrom, invalidatedAt: fact.invalidatedAt)
        }
        return MemoryEntityGraph(entities: entities, facts: order.compactMap { links[$0] })
    }

    /// The topic's title, or `nil` while it is still the placeholder.
    static func title(of topic: Topic) -> String? {
        let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != Topic.placeholderTitle else { return nil }
        return title
    }
}
