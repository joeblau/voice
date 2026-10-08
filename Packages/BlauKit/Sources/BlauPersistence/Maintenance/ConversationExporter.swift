import Foundation
import SwiftData

/// Writes the user's conversations as one Markdown document, for Settings →
/// iCloud → Export Conversations (shared through the share sheet: Files,
/// iCloud Drive, Mail...).
///
/// Each conversation is a section with its date and topics; each committed
/// utterance is a paragraph led by who spoke. Streaming partials (utterances
/// not yet committed) are left out.
///
/// ```markdown
/// # Blau conversations
///
/// Exported Oct 8, 2026 at 9:41 AM · 2 conversations
///
/// ## Interview prep
///
/// Oct 7, 2026, 6:02 – 6:40 PM
///
/// ### Fundraising
///
/// **You:** How should I answer the market size question?
///
/// **Grok:** Start with the bottom-up number...
/// ```
public struct ConversationExporter: Sendable {
    /// The conversation as the exporter reads it, so formatting can be
    /// tested without a store.
    public struct Snapshot: Sendable, Hashable {
        public struct Line: Sendable, Hashable {
            public var role: UtteranceRole
            public var text: String
            public var startedAt: Date
            /// The topic's title, when the utterance has a topic.
            public var topic: String?

            public init(role: UtteranceRole, text: String, startedAt: Date, topic: String? = nil) {
                self.role = role
                self.text = text
                self.startedAt = startedAt
                self.topic = topic
            }
        }

        public var title: String?
        public var startedAt: Date
        public var endedAt: Date?
        public var lines: [Line]

        public init(title: String?, startedAt: Date, endedAt: Date?, lines: [Line]) {
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.lines = lines
        }
    }

    public var locale: Locale
    public var timeZone: TimeZone

    public init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// Every conversation in `context`'s store, oldest first.
    public static func snapshots(in context: ModelContext) throws -> [Snapshot] {
        let conversations = try context.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt)]))
        return conversations.map { conversation in
            Snapshot(
                title: conversation.title,
                startedAt: conversation.startedAt,
                endedAt: conversation.endedAt,
                lines: conversation.orderedUtterances.filter(\.isFinal).map { utterance in
                    Snapshot.Line(
                        role: UtteranceRole(rawValue: utterance.roleRaw) ?? .system,
                        text: utterance.text,
                        startedAt: utterance.startedAt,
                        topic: utterance.topic?.title)
                })
        }
    }

    /// The Markdown for `conversations`, exported at `date`.
    public func markdown(for conversations: [Snapshot], exportedAt date: Date) -> String {
        var output = "# Blau conversations\n\n"
        let count = conversations.count == 1 ? "1 conversation" : "\(conversations.count) conversations"
        output += "Exported \(format(date, time: true)) · \(count)\n"
        for conversation in conversations {
            output += "\n## \(heading(for: conversation))\n\n"
            output += "\(span(conversation))\n"
            var currentTopic: String?
            for line in conversation.lines {
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let topic = line.topic, topic != currentTopic {
                    output += "\n### \(Self.escapeHeading(topic))\n"
                    currentTopic = topic
                }
                output += "\n**\(Self.speaker(line.role)):** \(text)\n"
            }
        }
        return output
    }

    /// Writes ``markdown(for:exportedAt:)`` to a file named for the date in
    /// `directory` and returns its URL.
    public func write(
        _ conversations: [Snapshot], exportedAt date: Date, to directory: URL = .temporaryDirectory
    ) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "Blau Conversations %04d-%02d-%02d.md", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let url = directory.appending(path: name)
        try Data(markdown(for: conversations, exportedAt: date).utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Formatting

    static func speaker(_ role: UtteranceRole) -> String {
        switch role {
        case .user: "You"
        case .agent: "Grok"
        case .system: "Blau"
        }
    }

    private func heading(for conversation: Snapshot) -> String {
        if let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return Self.escapeHeading(title)
        }
        return format(conversation.startedAt, time: true)
    }

    private func span(_ conversation: Snapshot) -> String {
        guard let end = conversation.endedAt, end > conversation.startedAt else {
            return format(conversation.startedAt, time: true)
        }
        let style = Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return (conversation.startedAt..<end).formatted(style)
    }

    private func format(_ date: Date, time: Bool) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// One line, so a title can't break the heading.
    static func escapeHeading(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
