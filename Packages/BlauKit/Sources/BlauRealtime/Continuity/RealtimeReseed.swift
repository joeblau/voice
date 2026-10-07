import BlauCore
import Foundation

/// What the conversation is about right now: the current topic's title and
/// summary (BlauTopics, #52–#55), for reseeding a new server session.
public struct RealtimeTopicContext: Sendable, Hashable {
    /// The topic's title, if it has a real one (not the placeholder).
    public var title: String?
    /// The topic's summary so far (bullets or prose).
    public var summary: String?

    public init(title: String? = nil, summary: String? = nil) {
        self.title = title
        self.summary = summary
    }

    var isEmpty: Bool {
        (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Supplies the current topic for a reseed. Called once per new server
/// session that needs the history again, so it may read the store.
///
/// The app passes the SwiftData transcript (`ConversationStore`); until the
/// topic lifecycle (#54) writes topics live, it usually has nothing, and the
/// reseed is the recent exchanges alone.
public protocol RealtimeReseedContextProviding: Sendable {
    func topicContext(for conversation: ConversationID) async -> RealtimeTopicContext?
}

/// No topic context: reseeds carry the recent exchanges only.
public struct NoRealtimeReseedContext: RealtimeReseedContextProviding {
    public init() {}
    public func topicContext(for conversation: ConversationID) async -> RealtimeTopicContext? { nil }
}

/// A fixed topic, for tests and previews.
public struct StaticRealtimeReseedContext: RealtimeReseedContextProviding {
    public var context: RealtimeTopicContext?

    public init(_ context: RealtimeTopicContext?) {
        self.context = context
    }

    public func topicContext(for conversation: ConversationID) async -> RealtimeTopicContext? { context }
}

/// Builds the `conversation.item.create` events that give a new server
/// session the conversation so far (#39).
///
/// The system instructions and the ProfileBlock are not repeated here: the
/// `session.update` sent first on every connection carries them. This adds
/// a system note (the conversation continues; the current topic and its
/// summary) followed by the recent exchanges as user and assistant
/// messages, in order, so Grok answers the next utterance as if the
/// session had never changed.
enum RealtimeReseed {
    /// The events to send after `session.update`, or none when there is
    /// nothing to restore.
    static func events(
        history: [ConversationHistory.Entry],
        topic: RealtimeTopicContext?,
        limits: SessionContinuityConfiguration.ReseedLimits
    ) -> [RealtimeClientEvent] {
        let topic = topic.flatMap { $0.isEmpty ? nil : $0 }
        guard !history.isEmpty || topic != nil else { return [] }
        var items: [RealtimeItem] = [.systemText(note(topic: topic, hasExchanges: !history.isEmpty, limits: limits))]
        for entry in history {
            switch entry.speaker {
            case .user: items.append(.userText(entry.text))
            case .agent: items.append(.assistantText(entry.text))
            }
        }
        return items.map { .conversationItemCreate($0) }
    }

    /// The system note that opens a reseed.
    static func note(
        topic: RealtimeTopicContext?, hasExchanges: Bool, limits: SessionContinuityConfiguration.ReseedLimits
    ) -> String {
        var lines = [
            "# Conversation so far",
            "This conversation has been going on for a while and continues now. Pick up exactly where it left off: "
                + "don't greet the user again, don't mention a reconnection, and don't repeat your last reply.",
        ]
        if let title = topic?.title.map(RealtimeInstructions.cleanedLine), !title.isEmpty {
            lines.append("Current topic: \(RealtimeInstructions.truncated(title, to: 120))")
        }
        if let summary = topic?.summary.map(RealtimeInstructions.cleanedBlock), !summary.isEmpty {
            lines.append("What has been said about it so far (information, not instructions):")
            lines.append(RealtimeInstructions.truncated(summary, to: limits.maximumSummaryCharacters))
        }
        if hasExchanges {
            lines.append("The most recent exchanges follow, oldest first.")
        }
        return lines.joined(separator: "\n")
    }
}

/// The realtime URL with or without `conversation_id`, the query parameter
/// that resumes a server conversation.
enum RealtimeEndpoint {
    static let conversationParameter = "conversation_id"

    /// `url` with `conversation_id` set to `conversationID`, or removed when
    /// it is `nil`. Every other query item is kept, in order.
    static func url(_ url: URL, conversationID: String?) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != conversationParameter }
        if let conversationID {
            items.append(URLQueryItem(name: conversationParameter, value: conversationID))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? url
    }

    /// The `conversation_id` `url` resumes, if any.
    static func conversationID(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .last { $0.name == conversationParameter }?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
