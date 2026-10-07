import BlauCore
import Foundation

/// When `ConversationStore` writes its changes to disk (and from there to
/// CloudKit).
///
/// Every save is a disk write and, with CloudKit mirroring on, schedules an
/// export, so the store batches the pipeline's many small changes: a change
/// waits at most `interval` before it is saved, and a burst is saved as soon
/// as `maxPendingChanges` changes have piled up. Conversation start and end
/// and `flush()` always save at once.
public struct ConversationStoreSavePolicy: Hashable, Sendable {
    /// The longest a change waits before it is saved. `.zero` saves after
    /// every change.
    public var interval: Duration

    /// Save at once when this many changes are waiting, so a burst doesn't
    /// grow one huge transaction. At least 1.
    public var maxPendingChanges: Int

    /// - Precondition: `interval >= .zero` and `maxPendingChanges >= 1`.
    public init(interval: Duration, maxPendingChanges: Int) {
        precondition(interval >= .zero, "Save interval must not be negative")
        precondition(maxPendingChanges >= 1, "maxPendingChanges must be at least 1")
        self.interval = interval
        self.maxPendingChanges = maxPendingChanges
    }

    /// Save at most every 2 s, or once 500 changes are waiting.
    public static let coalesced = ConversationStoreSavePolicy(interval: .seconds(2), maxPendingChanges: 500)

    /// Save after every change. For comparisons and debugging; it costs one
    /// disk transaction and one CloudKit export per utterance.
    public static let immediate = ConversationStoreSavePolicy(interval: .zero, maxPendingChanges: 1)

    /// Whether every change is saved straight away.
    public var savesEveryChange: Bool { interval <= .zero || maxPendingChanges <= 1 }
}

/// Counters describing a `ConversationStore`'s saves. For tests, the
/// performance HUD and diagnostics.
public struct ConversationStoreStatistics: Hashable, Sendable {
    /// Successful `ModelContext.save()` calls.
    public var saveCount = 0

    /// Saves that threw. The changes stay in the context and are retried by
    /// the next save.
    public var failedSaveCount = 0

    /// Saves that ran on the main thread. Always 0 unless the store's
    /// executor is broken; a debug build also stops at an assertion.
    public var mainThreadSaveCount = 0

    /// Changes made since the last successful save.
    public var pendingChangeCount = 0

    /// Utterances inserted (not counting refinements of an existing one).
    public var insertedUtteranceCount = 0

    /// How long the last successful save took, measured on the store's
    /// clock.
    public var lastSaveDuration: Duration?

    public init() {}
}

/// Errors thrown by `ConversationStore`.
public enum ConversationStoreError: Error, Hashable, Sendable {
    /// No conversation with this identifier exists in the store.
    case conversationNotFound(ConversationID)
    /// No topic with this identifier exists in the store.
    case topicNotFound(UUID)
    /// The call needs an active conversation and none is started.
    case noActiveConversation
    /// The topic is the first of its conversation, so there is nothing to
    /// merge it into or move its start against.
    case noPreviousTopic(UUID)
    /// The date doesn't fall strictly inside the topic's span, so the topic
    /// can't be split there or its start moved there.
    case invalidTopicBoundary(UUID)
    /// A manual title was empty or only whitespace.
    case emptyTitle
    /// A compare-and-swap edit was refused: the topic's title or span is no
    /// longer what the caller read (it was renamed, moved, merged or split
    /// meanwhile).
    case topicChanged(UUID)
}

/// A topic's title and summary, as `ConversationStore.topicDigest(for:)`
/// reads them.
public struct TopicDigest: Hashable, Sendable {
    /// The title, or `nil` while it is still the placeholder.
    public var title: String?
    /// Whether the title is a first guess the labeler may still refine.
    public var titleIsProvisional: Bool
    /// The bullet summary, once the labeler has written one.
    public var summary: String?

    public init(title: String?, titleIsProvisional: Bool, summary: String?) {
        self.title = title
        self.titleIsProvisional = titleIsProvisional
        self.summary = summary
    }
}
