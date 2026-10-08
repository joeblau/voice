import BlauPersistence
import Foundation

/// One bullet on the topic timeline (#56): a topic's stored state as a
/// plain value, with the conversation it belongs to.
///
/// Copied out of a `Topic` (and its `Conversation`) on the main actor, so
/// building the timeline never touches SwiftData and runs the same in
/// macOS tests as in the app.
public struct TimelineTopic: Identifiable, Hashable, Sendable {
    /// The topic's id, or for a ``isSynthetic`` bullet, its conversation's.
    public var id: UUID
    public var conversationID: UUID
    /// When the topic's conversation started: the timeline groups and
    /// orders topics by conversation first.
    public var conversationStartedAt: Date
    /// The conversation's own title, if the user or a model gave it one.
    public var conversationTitle: String?
    /// Position within the conversation, starting at 0.
    public var ordinal: Int
    public var title: String
    /// `true` while the title is a placeholder or a first guess: shown in
    /// italics until the labeler refines it or the user renames it.
    public var titleIsProvisional: Bool
    public var summary: String?
    /// Wall-clock time of the topic's first utterance.
    public var startedAt: Date
    /// `nil` while the topic is open.
    public var endedAt: Date?
    /// Seeds the dot color (`TopicPalette.slot(forColorSeed:)`).
    public var colorSeed: Int
    /// A stand-in for a conversation that has no topics yet (recorded
    /// before the topic lifecycle, or in the moment before its first topic
    /// opens). It holds the whole conversation and can't be edited.
    public var isSynthetic: Bool

    public init(
        id: UUID,
        conversationID: UUID,
        conversationStartedAt: Date,
        conversationTitle: String? = nil,
        ordinal: Int,
        title: String,
        titleIsProvisional: Bool,
        summary: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        colorSeed: Int? = nil,
        isSynthetic: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.conversationStartedAt = conversationStartedAt
        self.conversationTitle = conversationTitle
        self.ordinal = ordinal
        self.title = title
        self.titleIsProvisional = titleIsProvisional
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.colorSeed = colorSeed ?? Topic.colorSeed(for: id)
        self.isSynthetic = isSynthetic
    }

    /// The bullet for a stored topic, or `nil` when the topic isn't linked
    /// to a conversation (a sync that delivered the topic before its
    /// conversation, or a topic being deleted).
    public init?(_ topic: Topic) {
        guard let conversation = topic.conversation else { return nil }
        self.init(
            id: topic.id,
            conversationID: conversation.id,
            conversationStartedAt: conversation.startedAt,
            conversationTitle: conversation.title,
            ordinal: topic.ordinal,
            title: topic.title,
            titleIsProvisional: topic.titleIsProvisional,
            summary: topic.summary,
            startedAt: topic.startedAt,
            endedAt: topic.endedAt,
            colorSeed: topic.colorSeed
        )
    }

    /// The stand-in bullet for a conversation without topics: titled with
    /// the conversation's title, or the placeholder (in italics) when it has
    /// none.
    public static func synthetic(for conversation: TimelineConversation) -> TimelineTopic {
        TimelineTopic(
            id: conversation.id,
            conversationID: conversation.id,
            conversationStartedAt: conversation.startedAt,
            conversationTitle: conversation.title,
            ordinal: 0,
            title: conversation.title ?? Topic.placeholderTitle,
            titleIsProvisional: conversation.title == nil,
            startedAt: conversation.startedAt,
            endedAt: conversation.endedAt,
            isSynthetic: true
        )
    }

    /// Whether the topic is still open.
    public var isOpen: Bool { endedAt == nil }

    /// How long the topic lasted, or `nil` while it is open.
    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }
}

/// The conversation the timeline is anchored to: the running one, or else
/// the most recent.
public struct TimelineConversation: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String?

    public init(id: UUID, startedAt: Date, endedAt: Date? = nil, title: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
    }

    public init(_ conversation: Conversation) {
        self.init(
            id: conversation.id, startedAt: conversation.startedAt, endedAt: conversation.endedAt,
            title: conversation.title)
    }
}
