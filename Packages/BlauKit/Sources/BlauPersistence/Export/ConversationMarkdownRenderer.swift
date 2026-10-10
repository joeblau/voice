import Foundation

/// Renders one conversation as a Markdown file (#78).
///
/// The output is a pure function of the snapshot and `timeZone`: no export
/// time, locale or device name goes into it. That is what makes re-exporting
/// idempotent. The exporter compares the rendered bytes with the file on
/// disk and leaves an unchanged file alone, and two devices exporting the
/// same conversation (with the time zone recorded in the file) write the
/// same bytes.
///
/// ```markdown
/// ---
/// title: "Hiring Plan"
/// conversation: 7B0C...
/// started: 2026-10-08T14:03:00-07:00
/// ended: 2026-10-08T15:10:00-07:00
/// time-zone: America/Los_Angeles
/// topics: 2
/// utterances: 42
/// generator: Blau Markdown export 1
/// ---
///
/// # Hiring Plan
///
/// 2026-10-08 14:03 – 15:10
///
/// ## Hiring Plan
///
/// 14:03 – 14:20
///
/// > Deciding who to hire first.
///
/// **14:03:12 · You:** I think we need a designer first.
///
/// **14:03:20 · Grok:** Why a designer before an engineer?
/// ```
///
/// Topics are `##` headings in the order they were talked about, each with
/// its time span and summary. Utterances spoken before the first topic come
/// right after the conversation's heading; any other utterance without a
/// topic goes under "No topic". A topic the conversation came back to after
/// another one is headed again, marked "(continued)".
public struct ConversationMarkdownRenderer: Sendable {
    /// Bumped when the format changes in a way readers may care about. It is
    /// written into every file, so changing it rewrites every export once.
    public static let formatVersion = 1

    /// The heading for utterances that belong to no topic.
    public static let noTopicHeading = "No topic"

    /// Where times are shown.
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: - File

    /// The file's contents, ending with one newline.
    public func render(_ conversation: ConversationExportSnapshot) -> String {
        let format = ExportDateFormat(timeZone: timeZone)
        let title = Self.title(for: conversation)
        let sections = Self.sections(for: conversation)
        let topicCount = Set(sections.compactMap(\.topic?.id)).count

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(MarkdownText.yamlQuoted(title))")
        lines.append("conversation: \(conversation.id.uuidString)")
        lines.append("started: \(format.iso8601(conversation.startedAt))")
        if let endedAt = conversation.endedAt {
            lines.append("ended: \(format.iso8601(endedAt))")
        }
        lines.append("time-zone: \(timeZone.identifier)")
        lines.append("topics: \(topicCount)")
        lines.append("utterances: \(conversation.utterances.count)")
        lines.append("generator: \(MarkdownExportMetadata.generator) \(Self.formatVersion)")
        lines.append("---")
        lines.append("")
        lines.append("# \(MarkdownText.inline(title))")
        lines.append("")
        lines.append(format.span(from: conversation.startedAt, to: conversation.endedAt, day: nil))

        let day = format.day(conversation.startedAt)
        for (index, section) in sections.enumerated() {
            if let topic = section.topic {
                lines.append("")
                let heading = MarkdownText.inline(Self.trimmed(topic.title) ?? CurrentSchema.Topic.placeholderTitle)
                lines.append("## \(heading)\(section.isContinuation ? " (continued)" : "")")
                if !section.isContinuation {
                    lines.append("")
                    lines.append(format.span(from: topic.startedAt, to: topic.endedAt, day: day))
                    if let summary = Self.trimmed(topic.summary) {
                        lines.append("")
                        lines.append("> \(MarkdownText.inline(summary))")
                    }
                }
            } else if index > 0 {
                lines.append("")
                lines.append("## \(Self.noTopicHeading)")
            }
            for utterance in section.utterances {
                lines.append("")
                lines.append(Self.line(for: utterance, time: format.time(utterance.startedAt, day: day)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file name: start time, title and the first eight hex digits of
    /// the conversation id, for example
    /// `2026-10-08 14.03 Hiring Plan (7b0c1d2e).md`. The id keeps the name
    /// unique and lets the exporter find the file again after the title
    /// changes. `longID` uses the whole id, for the (unlikely) case of
    /// another file already having the short name.
    public func fileName(for conversation: ConversationExportSnapshot, longID: Bool = false) -> String {
        let format = ExportDateFormat(timeZone: timeZone)
        let title = MarkdownExportFileName.sanitizedTitle(Self.title(for: conversation))
        let id = longID ? conversation.id.uuidString.lowercased() : MarkdownExportFileName.shortID(conversation.id)
        return "\(format.fileStamp(conversation.startedAt)) \(title) (\(id)).\(MarkdownExportFileName.pathExtension)"
    }

    // MARK: - Content rules

    /// The conversation's title, else the first named topic's, else
    /// "Conversation".
    public static func title(for conversation: ConversationExportSnapshot) -> String {
        if let title = trimmed(conversation.title) {
            return title
        }
        // Only topics that appear in the file, so the title is always one of
        // its headings.
        let topicIDs = Set(conversation.utterances.compactMap(\.topicID))
        for topic in conversation.topics where topicIDs.contains(topic.id) {
            if let title = trimmed(topic.title), title != CurrentSchema.Topic.placeholderTitle {
                return title
            }
        }
        return "Conversation"
    }

    /// Follows the text of a reply the user cut short (#160), whose text is
    /// only what was heard: `**14:03:20 · Grok:** Why a designer — *interrupted*`.
    public static let interruptedMarker = " — *interrupted*"

    /// One utterance's line: time, speaker, the escaped text, and the
    /// marker when the reply was cut short.
    static func line(for utterance: ConversationExportSnapshot.Utterance, time: String) -> String {
        let marker = utterance.isInterrupted ? interruptedMarker : ""
        return "**\(time) · \(speaker(for: utterance.role)):** \(MarkdownText.inline(utterance.text))\(marker)"
    }

    /// How a speaker is labelled.
    public static func speaker(for role: UtteranceRole?) -> String {
        switch role {
        case .user: "You"
        case .agent: "Grok"
        case .system: "Blau"
        case nil: "Unknown"
        }
    }

    /// A run of consecutive utterances under one heading.
    struct Section: Equatable {
        var topic: ConversationExportSnapshot.Topic?
        var isContinuation: Bool
        var utterances: [ConversationExportSnapshot.Utterance]
    }

    /// Walks the utterances in time order and starts a section whenever the
    /// topic changes. Topics with no utterances are left out; an utterance
    /// whose topic isn't in the snapshot counts as having none.
    static func sections(for conversation: ConversationExportSnapshot) -> [Section] {
        let topics = Dictionary(conversation.topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [Section] = []
        var seen: Set<UUID> = []
        for utterance in conversation.utterances {
            let topic = utterance.topicID.flatMap { topics[$0] }
            if let last = sections.last, last.topic?.id == topic?.id {
                sections[sections.count - 1].utterances.append(utterance)
                continue
            }
            let isContinuation = topic.map { seen.contains($0.id) } ?? false
            if let topic { seen.insert(topic.id) }
            sections.append(Section(topic: topic, isContinuation: isContinuation, utterances: [utterance]))
        }
        return sections
    }

    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Dates

/// Locale-independent date text in a fixed time zone, so the export reads
/// the same on every device and in every language.
struct ExportDateFormat {
    let timeZone: TimeZone
    private let calendar: Calendar

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// `2026-10-08`
    func day(_ date: Date) -> String {
        let parts = parts(date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `14:03`
    func minute(_ date: Date) -> String {
        let parts = parts(date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `14:03:12`, prefixed with the day when it isn't `day`.
    func time(_ date: Date, day reference: String) -> String {
        let parts = parts(date)
        let time = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let day = day(date)
        return day == reference ? time : "\(day) \(time)"
    }

    /// `2026-10-08 14.03`: no colons, which Finder shows as slashes.
    func fileStamp(_ date: Date) -> String {
        let parts = parts(date)
        return String(format: "%@ %02d.%02d", day(date), parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `2026-10-08T14:03:00-07:00`, or `...Z` in UTC.
    func iso8601(_ date: Date) -> String {
        let parts = parts(date)
        let offset = timeZone.secondsFromGMT(for: date)
        let zone: String
        if offset == 0 {
            zone = "Z"
        } else {
            let minutes = abs(offset) / 60
            zone = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", minutes / 60, minutes % 60)
        }
        return String(
            format: "%@T%02d:%02d:%02d%@", day(date), parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, zone)
    }

    /// A start–end span. Each end shows its day when it differs from `day`
    /// (`nil`: always show the start's day). An open span ends in "now".
    func span(from start: Date, to end: Date?, day reference: String?) -> String {
        let startDay = day(start)
        let startText = startDay == reference ? minute(start) : "\(startDay) \(minute(start))"
        guard let end else { return "\(startText) – now" }
        let endDay = day(end)
        let endText = endDay == startDay ? minute(end) : "\(endDay) \(minute(end))"
        return "\(startText) – \(endText)"
    }
}

// MARK: - Text

/// Escaping for text that came from speech recognition or the user.
enum MarkdownText {
    /// Characters Markdown would read as emphasis, code, links or HTML.
    private static let escaped: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<"]

    /// One line of text: whitespace runs (newlines included) become one
    /// space, control characters are dropped, and Markdown syntax
    /// characters are backslash-escaped so a transcript can never turn into
    /// formatting.
    static func inline(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in collapsed(text) {
            if escaped.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// A double-quoted YAML scalar.
    static func yamlQuoted(_ text: String) -> String {
        var result = "\""
        for character in collapsed(text) {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.append(character)
            }
        }
        return result + "\""
    }

    /// Trims, folds whitespace runs (newlines included) to single spaces and
    /// drops control characters. Works on Unicode scalars so emoji and
    /// combining sequences stay intact.
    static func collapsed(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control {
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
