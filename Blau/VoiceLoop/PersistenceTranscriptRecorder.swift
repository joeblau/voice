import BlauCore
import BlauPersistence
import BlauRealtime
import Foundation
import SwiftData

/// Writes the turn orchestrator's transcript (#36) through a
/// `ConversationStore` over whichever SwiftData store is open, and reads
/// the current topic back for reseeding a realtime session (#39).
///
/// `PersistenceController` opens its stores asynchronously and replaces the
/// container when the iCloud account changes (`generation`), so the
/// container is looked up on every call rather than captured at launch. When
/// it changes mid-conversation, the conversation is reopened in the new
/// store before the next utterance is written.
actor PersistenceTranscriptRecorder: TurnTranscriptRecording, RealtimeReseedContextProviding {
    /// Thrown while no store is open yet.
    struct StoreUnavailableError: Error, CustomStringConvertible {
        var description: String { "The SwiftData store isn't open yet" }
    }

    private let container: @MainActor @Sendable () -> ModelContainer?
    private var store: ConversationStore?
    private var active: (id: ConversationID, startedAt: Date)?

    /// - Parameter container: The open container, read on the main actor
    ///   (`PersistenceController.stack?.container`).
    init(container: @escaping @MainActor @Sendable () -> ModelContainer?) {
        self.container = container
    }

    /// Records into `persistence`'s current store.
    init(persistence: PersistenceController) {
        self.init { [weak persistence] in persistence?.stack?.container }
    }

    func beginConversation(_ id: ConversationID, at date: Date) async throws {
        active = (id, date)
        try await currentStore(reopening: false).beginConversation(id, at: date)
    }

    func record(_ utterance: BlauCore.Utterance) async throws {
        try await currentStore(reopening: true).record(utterance)
    }

    func finishConversation(_ id: ConversationID, at date: Date) async throws {
        defer { active = nil }
        try await currentStore(reopening: true).finishConversation(id, at: date)
    }

    func flush() async throws {
        try await store?.flush()
    }

    /// The conversation's current topic from the store, for reseeding a new
    /// realtime session (#39). `nil` while no store is open.
    func topicContext(for conversation: ConversationID) async -> RealtimeTopicContext? {
        guard let store = try? await currentStore(reopening: false) else { return nil }
        return await store.topicContext(for: conversation)
    }

    /// The store the transcript is written to, for the topic lifecycle
    /// (#54), which must change topics through the same store so its
    /// current topic follows every boundary.
    ///
    /// - Throws: `StoreUnavailableError` while no store is open.
    func conversationStore() async throws -> ConversationStore {
        try await currentStore(reopening: true)
    }

    /// The store over the current container. A new container gets a new
    /// store; with `reopening`, the active conversation is started (or
    /// resumed) in it first.
    private func currentStore(reopening: Bool) async throws -> ConversationStore {
        guard let container = await container() else { throw StoreUnavailableError() }
        if let store, store.modelContainer === container { return store }
        try? await store?.flush()
        let fresh = ConversationStore(modelContainer: container)
        store = fresh
        if reopening, let active {
            try await fresh.beginConversation(active.id, at: active.startedAt)
        }
        return fresh
    }
}
