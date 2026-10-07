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
public struct SwiftDataMemorySources: MemorySourceProvider {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

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
        let wanted = ids
        let records = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { wanted.contains($0.id) }))
        let byID = Dictionary(grouping: records, by: \.id)
        return ids.compactMap { id in
            guard let copies = byID[id], let first = copies.first else { return nil }
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
    }

    public func documents() async throws -> [DocumentSnapshot] {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<MemoryDocument>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
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

    public func facts() async throws -> [FactSnapshot] {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.validFrom), SortDescriptor(\.id)]))
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

    /// The topic's title, or `nil` while it is still the placeholder.
    static func title(of topic: Topic) -> String? {
        let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != Topic.placeholderTitle else { return nil }
        return title
    }
}
