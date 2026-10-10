import Foundation

extension ConversationExportSnapshot {
    /// The utterances of topic `topicID`, in the order they were spoken:
    /// the ones the store linked to it, and the ones linked to no topic that
    /// were said while it was open (lines written a moment before the store
    /// assigned them). An unknown `topicID` has none.
    public func utterances(inTopic topicID: UUID) -> [Utterance] {
        guard let topic = topics.first(where: { $0.id == topicID }) else { return [] }
        let end = topic.endedAt ?? .distantFuture
        return utterances.filter { utterance in
            if let linked = utterance.topicID { return linked == topicID }
            return utterance.startedAt >= topic.startedAt && utterance.startedAt < end
        }
    }
}

/// Renders one topic as a Markdown document to share (#58): the timeline's
/// "Share as Markdown".
///
/// The format follows the conversation export (#78,
/// `ConversationMarkdownRenderer`), so a shared topic reads like a section
/// of an exported file: front matter, the title, its span, the summary as a
/// quote and one line per utterance.
///
/// ```markdown
/// ---
/// title: "Hiring Plan"
/// conversation: 7B0C...
/// topic: 1F2E...
/// started: 2026-10-08T14:03:00-07:00
/// ended: 2026-10-08T14:20:00-07:00
/// time-zone: America/Los_Angeles
/// utterances: 2
/// generator: Blau topic 1
/// ---
///
/// # Hiring Plan
///
/// 2026-10-08 14:03 – 14:20 · Planning
///
/// > Deciding who to hire first.
///
/// **14:03:12 · You:** I think we need a designer first.
/// ```
///
/// Its `generator` is deliberately not the export's
/// (`MarkdownExportMetadata.generator`): a shared topic saved into iCloud
/// Drive → Blau must never be taken for the conversation's export file,
/// which the exporter would then rewrite or remove.
public struct TopicMarkdownRenderer: Sendable {
    /// The `generator:` value of a shared topic.
    public static let generator = "Blau topic"
    public static let formatVersion = 1

    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// The document for topic `topicID` of `conversation`, ending with one
    /// newline. A `topicID` that isn't one of the conversation's topics (a
    /// conversation recorded before topics, shown as one stand-in bullet)
    /// renders the whole conversation as the export does.
    public func render(topicID: UUID, of conversation: ConversationExportSnapshot) -> String {
        guard let topic = conversation.topics.first(where: { $0.id == topicID }) else {
            return ConversationMarkdownRenderer(timeZone: timeZone).render(conversation)
        }
        let format = ExportDateFormat(timeZone: timeZone)
        let utterances = conversation.utterances(inTopic: topicID)
        let title = Self.title(of: topic)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(MarkdownText.yamlQuoted(title))")
        lines.append("conversation: \(conversation.id.uuidString)")
        lines.append("topic: \(topic.id.uuidString)")
        lines.append("started: \(format.iso8601(topic.startedAt))")
        if let endedAt = topic.endedAt {
            lines.append("ended: \(format.iso8601(endedAt))")
        }
        lines.append("time-zone: \(timeZone.identifier)")
        lines.append("utterances: \(utterances.count)")
        lines.append("generator: \(Self.generator) \(Self.formatVersion)")
        lines.append("---")
        lines.append("")
        lines.append("# \(MarkdownText.inline(title))")
        lines.append("")
        var span = format.span(from: topic.startedAt, to: topic.endedAt, day: nil)
        if let conversationTitle = ConversationMarkdownRenderer.trimmed(conversation.title),
            conversationTitle != title
        {
            span += " · \(MarkdownText.inline(conversationTitle))"
        }
        lines.append(span)
        if let summary = ConversationMarkdownRenderer.trimmed(topic.summary) {
            lines.append("")
            lines.append("> \(MarkdownText.inline(summary))")
        }
        let day = format.day(topic.startedAt)
        for utterance in utterances {
            lines.append("")
            lines.append(
                ConversationMarkdownRenderer.line(for: utterance, time: format.time(utterance.startedAt, day: day)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The shared file's name: start time and title, e.g.
    /// `2026-10-08 14.03 Hiring Plan.md`. No id: it is a copy to send, not
    /// a file Blau looks for again.
    public func fileName(topicID: UUID, of conversation: ConversationExportSnapshot) -> String {
        let format = ExportDateFormat(timeZone: timeZone)
        guard let topic = conversation.topics.first(where: { $0.id == topicID }) else {
            let title = MarkdownExportFileName.sanitizedTitle(ConversationMarkdownRenderer.title(for: conversation))
            return "\(format.fileStamp(conversation.startedAt)) \(title).\(MarkdownExportFileName.pathExtension)"
        }
        let title = MarkdownExportFileName.sanitizedTitle(Self.title(of: topic))
        return "\(format.fileStamp(topic.startedAt)) \(title).\(MarkdownExportFileName.pathExtension)"
    }

    /// The topic's title, or "Topic" while it is still the placeholder.
    static func title(of topic: ConversationExportSnapshot.Topic) -> String {
        guard let title = ConversationMarkdownRenderer.trimmed(topic.title),
            title != CurrentSchema.Topic.placeholderTitle
        else { return "Topic" }
        return title
    }
}
