import BlauCore
import BlauPersistence
import Foundation

/// Where the topic lifecycle reads and writes topics. `ConversationStore`
/// (#21) is the production implementation; see `ConversationStore+Topics`
/// in BlauPersistence for what each call does.
///
/// The lifecycle must write through the same store that records the
/// transcript, so the store's current topic follows every boundary. In the
/// app that store is replaced when the iCloud account changes, so the app
/// passes a `DeferredTopicStore` that looks it up on every call.
public protocol TopicStore: Sendable {
    func openTopic(in conversationID: ConversationID, at startedAt: Date, title: String) async throws -> UUID
    func splitTopic(_ topicID: UUID, at date: Date, title: String) async throws -> UUID
    func moveTopicStart(_ topicID: UUID, to date: Date) async throws
    func mergeTopicWithPrevious(_ topicID: UUID) async throws -> UUID
    func removeTopicIfEmpty(_ topicID: UUID) async throws -> Bool
    func applyTopicLabel(_ topicID: UUID, title: String?, summary: String?, finalizesTitle: Bool) async throws -> Bool
    func replaceTopicLabel(_ topicID: UUID, expectedTitle: String, title: String, summary: String?) async throws -> Bool
    func renameTopic(_ topicID: UUID, to title: String) async throws
    func topicSnapshot(_ topicID: UUID) async throws -> TopicSnapshot
    func topicSnapshots(in conversationID: ConversationID) async throws -> [TopicSnapshot]
    func topicUtterances(_ topicID: UUID) async throws -> [Utterance]
    /// Saves whatever is waiting.
    func flush() async throws
}

extension ConversationStore: TopicStore {}

/// A `TopicStore` that asks for the current `ConversationStore` on every
/// call. The app's transcript recorder replaces its store when the SwiftData
/// container changes; this keeps the lifecycle writing to the same one.
public struct DeferredTopicStore: TopicStore {
    private let store: @Sendable () async throws -> ConversationStore

    public init(_ store: @escaping @Sendable () async throws -> ConversationStore) {
        self.store = store
    }

    public func openTopic(in conversationID: ConversationID, at startedAt: Date, title: String) async throws -> UUID {
        try await store().openTopic(in: conversationID, at: startedAt, title: title)
    }

    public func splitTopic(_ topicID: UUID, at date: Date, title: String) async throws -> UUID {
        try await store().splitTopic(topicID, at: date, title: title)
    }

    public func moveTopicStart(_ topicID: UUID, to date: Date) async throws {
        try await store().moveTopicStart(topicID, to: date)
    }

    public func mergeTopicWithPrevious(_ topicID: UUID) async throws -> UUID {
        try await store().mergeTopicWithPrevious(topicID)
    }

    public func removeTopicIfEmpty(_ topicID: UUID) async throws -> Bool {
        try await store().removeTopicIfEmpty(topicID)
    }

    public func applyTopicLabel(
        _ topicID: UUID, title: String?, summary: String?, finalizesTitle: Bool
    ) async throws -> Bool {
        try await store().applyTopicLabel(topicID, title: title, summary: summary, finalizesTitle: finalizesTitle)
    }

    public func replaceTopicLabel(
        _ topicID: UUID, expectedTitle: String, title: String, summary: String?
    ) async throws -> Bool {
        try await store().replaceTopicLabel(topicID, expectedTitle: expectedTitle, title: title, summary: summary)
    }

    public func renameTopic(_ topicID: UUID, to title: String) async throws {
        try await store().renameTopic(topicID, to: title)
    }

    public func topicSnapshot(_ topicID: UUID) async throws -> TopicSnapshot {
        try await store().topicSnapshot(topicID)
    }

    public func topicSnapshots(in conversationID: ConversationID) async throws -> [TopicSnapshot] {
        try await store().topicSnapshots(in: conversationID)
    }

    public func topicUtterances(_ topicID: UUID) async throws -> [Utterance] {
        try await store().topicUtterances(topicID)
    }

    public func flush() async throws {
        try await store().flush()
    }
}
