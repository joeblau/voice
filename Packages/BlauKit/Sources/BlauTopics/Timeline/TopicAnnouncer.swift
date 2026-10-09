import BlauPersistence
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
///   current: "New topic: Pricing", or plain "New topic" while it still has
///   the placeholder title (`Topic.placeholderTitle`).
/// - **The current topic gets its name**: "Topic named Pricing
///   Experiments". That is the first real title replacing the placeholder
///   (the labeler's first guess, which stays provisional while the topic is
///   open), or a provisional title refined into a final one.
///
/// The placeholder counts as "no title yet", never as a name, so the user
/// never hears "New topic: New topic", and the topic's real name is spoken
/// when it arrives rather than only when the conversation ends.
///
/// It stays quiet on the first topic it sees (the screen just opened), when
/// the focus moves to another conversation (starting a conversation is
/// announced by the record button), when a conversation's stand-in bullet
/// gives way to its first real topic, when the current topic is merged into
/// the one before it (the "new" current topic is older), for a title the
/// user typed (`renamedByUser`), for a real
/// provisional title replaced by another provisional one (the labeler is
/// still guessing), for a title that goes back to the placeholder, and for
/// a renamed title that wasn't provisional (the user renamed it
/// themselves).
public struct TopicAnnouncer: Equatable, Sendable {
    /// What to announce.
    public enum Announcement: Equatable, Sendable {
        /// A new topic became current. `title` is `nil` while the topic
        /// still has the placeholder title.
        case newTopic(title: String?)
        /// The current topic got its name: its placeholder was replaced by
        /// a real title, or its provisional title was refined.
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
    /// - Parameters:
    ///   - current: The timeline's current topic, or `nil` when there is
    ///     none.
    ///   - renamedByUser: The topics the user renamed on this screen. Their
    ///     new title is what the user just typed, so it isn't news, even
    ///     when it replaces a provisional title (the current topic's title
    ///     is provisional for as long as it is open).
    /// - Returns: What VoiceOver should announce, if anything.
    public mutating func update(_ current: TimelineTopic?, renamedByUser: Set<UUID> = []) -> Announcement? {
        let previous = last
        last = current.map(Seen.init)
        guard let previous, let current, !current.isSynthetic else { return nil }
        guard current.conversationID == previous.conversationID else { return nil }

        if current.id == previous.id {
            guard !renamedByUser.contains(current.id) else { return nil }
            guard let title = Self.name(current.title), title != Self.name(previous.title) else { return nil }
            // The first real title, even a provisional one: the labeler's
            // first guess stays provisional for as long as the topic is
            // open, so waiting for a final title would mean waiting for the
            // topic to close.
            let named = Self.name(previous.title) == nil
            let refined = previous.titleIsProvisional && !current.titleIsProvisional
            return named || refined ? .titleRefined(title: title) : nil
        }
        // A stand-in bullet giving way to the conversation's first topic,
        // or a merge back into an earlier topic, isn't news.
        guard !previous.isSynthetic, current.startedAt > previous.startedAt else { return nil }
        return .newTopic(title: Self.name(current.title))
    }

    /// A title as something worth speaking: `nil` for the placeholder (or
    /// an empty title), which means the topic has no name yet.
    private static func name(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == Topic.placeholderTitle ? nil : trimmed
    }
}
