import Foundation
import SwiftData

/// Reads conversations for the Markdown export. The exporter calls it on its
/// own serial queue.
public protocol ConversationExportSource: Sendable {
    /// Every conversation's id, oldest first.
    func conversationIDs() throws -> [UUID]
    /// The conversation with `id`, or `nil` if it no longer exists.
    func snapshot(of id: UUID) throws -> ConversationExportSnapshot?
    /// The conversations that `changes` inserted or updated, or whose topics
    /// or utterances it inserted or updated.
    func conversationIDs(affectedBy changes: StoreChangeSet) throws -> Set<UUID>
}

/// Reads conversations from the synced SwiftData store.
///
/// Each call opens a fresh `ModelContext` on the calling (export) thread and
/// drops it when it returns, so a full export of hundreds of conversations
/// never holds more than one in memory, and nothing it reads is shared with
/// the main context or the pipeline's `ConversationStore`.
public struct SwiftDataConversationExportSource: ConversationExportSource {
    public let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    public func conversationIDs() throws -> [UUID] {
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt)])
        descriptor.propertiesToFetch = [\.id, \.startedAt]
        var seen: Set<UUID> = []
        // CloudKit can't enforce unique ids, so the same conversation can
        // exist twice; export it once.
        return try makeContext().fetch(descriptor).map(\.id).filter { seen.insert($0).inserted }
    }

    public func snapshot(of id: UUID) throws -> ConversationExportSnapshot? {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        let matches = try makeContext().fetch(descriptor)
        // De-duplicate on read: if two devices both created this
        // conversation, export the copy with the most utterances (ties: the
        // earliest start), the same choice on every device.
        let best = matches.max { lhs, rhs in
            let left = (lhs.utterances?.count ?? 0, -lhs.startedAt.timeIntervalSinceReferenceDate)
            let right = (rhs.utterances?.count ?? 0, -rhs.startedAt.timeIntervalSinceReferenceDate)
            return left < right
        }
        return best.map(ConversationExportSnapshot.init)
    }

    public func conversationIDs(affectedBy changes: StoreChangeSet) throws -> Set<UUID> {
        let context = makeContext()
        var ids: Set<UUID> = []

        let conversations = changes.changes(to: Conversation.self)
        let conversationModels = conversations.inserted.union(conversations.updated)
        if !conversationModels.isEmpty {
            let descriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate { conversationModels.contains($0.persistentModelID) })
            ids.formUnion(try context.fetch(descriptor).map(\.id))
        }

        let topics = changes.changes(to: Topic.self)
        let topicModels = topics.inserted.union(topics.updated)
        if !topicModels.isEmpty {
            let descriptor = FetchDescriptor<Topic>(
                predicate: #Predicate { topicModels.contains($0.persistentModelID) })
            ids.formUnion(try context.fetch(descriptor).compactMap { $0.conversation?.id })
        }

        let utterances = changes.changes(to: StoredUtterance.self)
        let utteranceModels = utterances.inserted.union(utterances.updated)
        if !utteranceModels.isEmpty {
            let descriptor = FetchDescriptor<StoredUtterance>(
                predicate: #Predicate { utteranceModels.contains($0.persistentModelID) })
            ids.formUnion(try context.fetch(descriptor).compactMap { $0.conversation?.id })
        }
        return ids
    }
}
