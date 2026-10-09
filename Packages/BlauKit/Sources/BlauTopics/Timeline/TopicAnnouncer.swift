import Foundation

/// Decides what VoiceOver announces when the timeline's current topic
/// changes (#81). The timeline feeds it the current topic every time that
/// changes; it answers with an announcement, or `nil` to stay quiet.
///
/// A voice-first app changes its main screen while the user isn't touching
/// it, so a VoiceOver user hears about the two changes that matter and
/// nothing else:
///
/// - **A new topic opens** in the same conversation, after the one that was
///   current: "New topic: Pricing".
/// - **The current topic's provisional title is refined** by the labeler:
///   "Topic named Pricing Experiments".
///
/// It stays quiet on the first topic it sees (the screen just opened), when
/// the focus moves to another conversation (starting a conversation is
/// announced by the record button), when a conversation's stand-in bullet
/// gives way to its first real topic, when the current topic is merged into
/// the one before it (the "new" current topic is older), for a provisional
/// title replaced by another provisional one (the labeler is still
/// guessing), and for a renamed title that wasn't provisional (the user
/// renamed it themselves).
public struct TopicAnnouncer: Equatable, Sendable {
    /// What to announce.
    public enum Announcement: Equatable, Sendable {
        /// A new topic became current.
        case newTopic(title: String)
        /// The current topic's provisional title was refined.
        case titleRefined(title: String)
    }

    /// What it remembers of a topic between updates.
    private struct Seen: Equatable, Sendable {
        var id: UUID
        var conversationID: UUID
        var title: String
        var titleIsProvisional: Bool
        var startedAt: Date
        var isSynthetic: Bool

        init(_ topic: TimelineTopic) {
            id = topic.id
            conversationID = topic.conversationID
            title = topic.title
            titleIsProvisional = topic.titleIsProvisional
            startedAt = topic.startedAt
            isSynthetic = topic.isSynthetic
        }
    }

    private var last: Seen?

    public init() {}

    /// Follows the current topic.
    ///
    /// - Parameter current: The timeline's current topic, or `nil` when
    ///   there is none.
    /// - Returns: What VoiceOver should announce, if anything.
    public mutating func update(_ current: TimelineTopic?) -> Announcement? {
        let previous = last
        last = current.map(Seen.init)
        guard let previous, let current, !current.isSynthetic else { return nil }
        guard current.conversationID == previous.conversationID else { return nil }

        if current.id == previous.id {
            let refined =
                previous.titleIsProvisional && !current.titleIsProvisional && current.title != previous.title
            return refined ? .titleRefined(title: current.title) : nil
        }
        // A stand-in bullet giving way to the conversation's first topic,
        // or a merge back into an earlier topic, isn't news.
        guard !previous.isSynthetic, current.startedAt > previous.startedAt else { return nil }
        return .newTopic(title: current.title)
    }
}
