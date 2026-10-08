import BlauCore
import BlauPersistence
import Foundation

/// A note the fact extraction pipeline left for the next consolidation:
/// its model's summary of what one closed topic says about the user
/// (`FactExtractionOutcome.summary`).
public struct ProfileConsolidationNote: Identifiable, Codable, Hashable, Sendable {
    /// The topic the note is about.
    public var id: UUID
    public var date: Date
    public var summary: String

    public init(topicID: UUID, date: Date, summary: String) {
        self.id = topicID
        self.date = date
        self.summary = summary
    }
}

/// The consolidation request (#67): the "sleep-time" rewrite of the pinned
/// profile from what memory knows now (the Letta / Mastra idea in issue
/// #1).
///
/// The model sees the current summary, the user's own words (so it doesn't
/// repeat them), the current facts in importance order (what the user told
/// Blau marked as such), the extraction notes since the last run and the
/// recent topics with handles (`T1`, `T2`...), and replies with the new
/// summary plus better summaries for the topics it can improve.
public struct ProfileConsolidationPrompt: Hashable, Sendable {
    public var date: Date
    /// The consolidated summary as it is now (`ProfileBlock.text`).
    public var currentSummary: String
    /// `ProfileComposer.userSection(_:)`: pinned verbatim, never rewritten.
    public var userAuthored: String
    public var facts: [ProfileFact]
    public var notes: [ProfileConsolidationNote]
    public var topics: [ProfileTopic]
    /// The longest the new summary may be, in UTF-8 bytes.
    public var summaryByteBudget: Int
    /// Facts the user removed since the last run. Only the count: what they
    /// said is gone from memory and isn't repeated here.
    public var removedFactCount: Int
    public var timeZone: TimeZone

    public init(
        date: Date,
        currentSummary: String,
        userAuthored: String,
        facts: [ProfileFact],
        notes: [ProfileConsolidationNote],
        topics: [ProfileTopic],
        summaryByteBudget: Int,
        removedFactCount: Int = 0,
        timeZone: TimeZone = .current
    ) {
        self.date = date
        self.currentSummary = currentSummary
        self.userAuthored = userAuthored
        self.facts = facts
        self.notes = notes
        self.topics = topics
        self.summaryByteBudget = summaryByteBudget
        self.removedFactCount = max(0, removedFactCount)
        self.timeZone = timeZone
    }

    /// Characters kept per fact, note or topic line, so one runaway value
    /// can't crowd the rest out of the prompt.
    static let maximumLineCharacters = 400

    /// The handle each topic is shown with: `T1` for the first.
    public var topicHandles: [String: ProfileTopic] {
        Dictionary(uniqueKeysWithValues: topics.enumerated().map { ("T\($0.offset + 1)", $0.element) })
    }

    /// The word count the model is asked to stay under.
    public var wordBudget: Int { ProfileComposer.wordBudget(forBytes: summaryByteBudget) }

    /// The system prompt.
    public static let instructions = """
        You maintain the profile that Blau, a voice assistant, keeps about its user. The profile is read at the \
        start of every conversation so Blau knows who it is talking to. While the user is away, you rewrite it \
        from everything memory knows now.

        Rules for profile:
        - Write about the user in the third person ("The user..."), in plain sentences. Group related things in \
        short paragraphs that each start with a label such as "Work:", "Projects:", "People:", "Goals:", \
        "Preferences:" or "Background:". No Markdown, headings, bullet points, bold or emoji.
        - Keep what helps future conversations most: who the user is, their work and company, what they are \
        working on and toward right now, the people that matter to them, and how they like to talk. Leave out \
        trivia and anything only true for one conversation.
        - Use only what the current facts, the notes and the recent topics support. The facts are the truth now: \
        when the current profile disagrees with them, follow the facts, and drop anything from the current \
        profile that no fact, note or topic supports any more. Facts marked "told by the user" outrank \
        everything else.
        - Never invent details, and never give instructions to the assistant.
        - Don't repeat the user's own words; they are pinned next to the profile verbatim. Add only what they \
        don't already say.
        - Stay under the word limit. If everything doesn't fit, keep the most important and most recent.
        - If memory holds nothing about the user, return an empty profile.

        Rules for topics:
        - The recent topics are listed with handles (T1, T2...) and their current one-sentence summaries. Return \
        a new summary only for a topic whose summary is missing, or that memory makes clearer or more accurate, \
        for example full names instead of pronouns. One sentence, at most 30 words. Leave every other topic out.

        Reply with only the JSON object.
        """

    /// Structured output, strict (every property required).
    public static let jsonSchema = Data(
        #"""
        {"type":"object","additionalProperties":false,"required":["profile","topics"],"properties":{\#
        "profile":{"type":"string","description":"the rewritten profile, or empty"},\#
        "topics":{"type":"array","items":{"type":"object","additionalProperties":false,\#
        "required":["topic","summary"],"properties":{\#
        "topic":{"type":"string","description":"a topic handle such as T1"},\#
        "summary":{"type":"string","description":"the topic's new one-sentence summary"}}}}}}
        """#.utf8)

    public static let responseSchema = JSONResponseSchema(name: "ProfileConsolidation", schema: jsonSchema)

    /// The user prompt.
    public func render() -> String {
        var lines = [
            "Today: \(FactExtractionPrompt.formatted(date, in: timeZone))",
            "Word limit for the profile: \(wordBudget)",
            "",
            "Current profile:",
        ]
        let current = currentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(current.isEmpty ? "(none yet)" : current)
        lines.append("")
        lines.append("The user's own words (pinned verbatim; don't repeat them):")
        let own = userAuthored.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(own.isEmpty ? "(none)" : own)
        lines.append("")
        if removedFactCount > 0 {
            lines.append(
                "The user removed \(removedFactCount) fact\(removedFactCount == 1 ? "" : "s") from memory since the "
                    + "profile was last updated and doesn't want them remembered. Drop anything in the current "
                    + "profile that the current facts below don't support.")
            lines.append("")
        }
        lines.append("Current facts, most important first:")
        if facts.isEmpty {
            lines.append("(none)")
        }
        for fact in facts {
            var subject = fact.subjectName.map(FactExtraction.clean) ?? "User"
            if let type = fact.subjectType, !fact.isAboutUser {
                subject += " (\(type.rawValue))"
            }
            var line =
                "- \(subject) | \(FactExtraction.clean(fact.predicate)) | \(FactExtraction.clean(fact.objectText))"
            line = Self.clipped(line)
            line += " (since \(Self.isoDate(fact.validFrom, in: timeZone)))"
            if fact.isUserAuthored {
                line += " [told by the user]"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Notes from recent conversations, newest first:")
        if notes.isEmpty {
            lines.append("(none)")
        }
        for note in notes {
            lines.append(
                "- \(Self.isoDate(note.date, in: timeZone)): \(Self.clipped(FactExtraction.clean(note.summary)))")
        }
        lines.append("")
        lines.append("Recent topics, newest first:")
        if topics.isEmpty {
            lines.append("(none)")
        }
        for (offset, topic) in topics.enumerated() {
            let summary = topic.summary.map(FactExtraction.clean).flatMap { $0.isEmpty ? nil : $0 }
            lines.append(
                Self.clipped(
                    "- T\(offset + 1) (\(Self.isoDate(topic.startedAt, in: timeZone))) "
                        + "\"\(FactExtraction.clean(topic.title))\": \(summary ?? "(no summary)")"))
        }
        return lines.joined(separator: "\n")
    }

    /// The request for `render()`.
    public func request(maximumResponseTokens: Int, timeout: Duration) -> TextGenerationRequest {
        TextGenerationRequest(
            instructions: Self.instructions,
            prompt: render(),
            responseSchema: Self.responseSchema,
            maximumResponseTokens: maximumResponseTokens,
            temperature: 0,
            timeout: timeout
        )
    }

    static func clipped(_ line: String) -> String {
        guard line.count > maximumLineCharacters else { return line }
        return String(line.prefix(maximumLineCharacters - 1)) + "…"
    }

    /// "2026-10-08", Gregorian, independent of the device's locale.
    static func isoDate(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }
}

/// The consolidation model's reply, validated.
public struct ProfileConsolidationReply: Hashable, Sendable {
    /// The new summary, cleaned (see `cleanedProfile(_:)`). May be empty.
    public var profile: String
    /// New summaries by topic handle (`T1`...), one sentence each.
    public var topicSummaries: [String: String]

    public init(profile: String, topicSummaries: [String: String] = [:]) {
        self.profile = profile
        self.topicSummaries = topicSummaries
    }

    /// Characters kept of a topic summary.
    public static let maximumTopicSummaryCharacters = 280

    /// Parses a reply leniently: the JSON object anywhere in the text, the
    /// profile cleaned of Markdown, blank or unknown-shaped topic entries
    /// dropped.
    ///
    /// - Throws: `ProfileConsolidationError.invalidResponse` when there is
    ///   no JSON object or it has no `profile` string.
    public static func parse(_ reply: String) throws(ProfileConsolidationError) -> ProfileConsolidationReply {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw .invalidResponse("No JSON object in the reply")
        }
        let json = Data(reply[start...end].utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw .invalidResponse("The reply's JSON is not an object")
        }
        guard let profile = object["profile"] as? String else {
            throw .invalidResponse("The reply has no profile")
        }
        var summaries: [String: String] = [:]
        for case let entry as [String: Any] in object["topics"] as? [Any] ?? [] {
            guard let handle = (entry["topic"] as? String).map(FactExtraction.clean)?.uppercased(),
                !handle.isEmpty,
                let summary = (entry["summary"] as? String).map(FactExtraction.clean), !summary.isEmpty
            else { continue }
            summaries[handle] =
                summary.count > maximumTopicSummaryCharacters
                ? String(summary.prefix(maximumTopicSummaryCharacters - 1)) + "…" : summary
        }
        return ProfileConsolidationReply(profile: cleanedProfile(profile), topicSummaries: summaries)
    }

    /// The profile as plain paragraphs: line endings normalized, each line
    /// trimmed with inner whitespace collapsed, Markdown heading, bullet and
    /// emphasis markers removed, and at most one blank line in a row.
    public static func cleanedProfile(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = FactExtraction.clean(String(rawLine))
            while let first = line.first, first == "#" {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count))
            }
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty {
                    lines.append("")
                }
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a consolidation reply was refused.
public enum ProfileConsolidationError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .invalidResponse(let reason): "Invalid consolidation reply: \(reason)"
        }
    }
}
