import BlauCore
import BlauPersistence
import Foundation

/// One utterance of a topic with the number the prompt shows for it, so a
/// fact's `source` can be traced back to `Fact.sourceUtteranceID`.
public struct NumberedUtterance: Hashable, Sendable {
    /// 1-based, over the whole topic.
    public var number: Int
    public var utterance: Utterance

    public init(number: Int, utterance: Utterance) {
        self.number = number
        self.utterance = utterance
    }
}

/// The extraction request sent to the text model for one window of a closed
/// topic: instructions, the transcript with numbered lines, what memory
/// already knows that the window mentions, and the structured-output
/// schema.
///
/// Known facts are shown with short handles (`F1`, `F2`...) so the model
/// can name the ones a new fact contradicts (`replaces`), the Mem0 /
/// Graphiti approach to add-only memory: the contradicted fact is
/// invalidated, never deleted.
public struct FactExtractionPrompt: Hashable, Sendable {
    /// When the window was spoken, for resolving "next Friday".
    public var date: Date
    /// The topic's title, if it has a real one.
    public var topicTitle: String?
    /// Known entities the window mentions.
    public var entities: [KnownEntity]
    /// Current facts about the user and those entities, newest first.
    public var facts: [KnownFact]
    public var utterances: [NumberedUtterance]
    /// Time zone the date is written in.
    public var timeZone: TimeZone

    public init(
        date: Date,
        topicTitle: String?,
        entities: [KnownEntity],
        facts: [KnownFact],
        utterances: [NumberedUtterance],
        timeZone: TimeZone = .current
    ) {
        self.date = date
        self.topicTitle = topicTitle
        self.entities = entities
        self.facts = facts
        self.utterances = utterances
        self.timeZone = timeZone
    }

    /// The handle each known fact is shown with: `F1` for the first.
    public var factHandles: [String: KnownFact] {
        Dictionary(uniqueKeysWithValues: facts.enumerated().map { ("F\($0.offset + 1)", $0.element) })
    }

    /// The system prompt.
    public static let instructions = """
        You maintain the long-term memory that Blau, a voice assistant, keeps about its user. Read the transcript \
        and extract the durable facts worth remembering in future conversations: about the user (background, \
        work, company, projects, goals, preferences, relationships, plans, important dates) and about the people, \
        organizations, places, products, projects and events they talk about.

        Rules:
        - Only facts the user stated or clearly confirmed. Never treat Blau's questions, suggestions or guesses \
        as facts.
        - Skip small talk, passing moods and anything only true for this conversation.
        - A fact is subject, predicate, object. The subject is "user" for the user, otherwise the exact name of an \
        entity in your entities list. The predicate is a short lowercase verb phrase ("works at", "lives in", \
        "prefers", "co-founded", "raised"). The object is a short phrase. Resolve "I", "my" and "we" to the user, \
        resolve pronouns, and turn relative dates ("next Friday") into dates using the conversation date.
        - confidence: 0 to 1, how sure you are the user means it as a lasting fact.
        - source: the number of the transcript line the fact comes from.
        - replaces: the handles (F1, F2...) of known facts that the new fact makes no longer true, for example a \
        new employer replaces the old one. A fact that only adds detail replaces nothing. Never repeat a known \
        fact that is still true.
        - entities: every entity you use as a subject, and other important ones mentioned. Reuse a known \
        entity's exact name when it is the same thing. type is one of person, organization, place, product, \
        project, event, concept, other. aliases: other names the transcript uses for it. summary: a short \
        description if the transcript says what it is, otherwise "".
        - summary: one or two sentences on what this part of the conversation says about the user.
        If there is nothing worth remembering, return empty lists.
        Reply with only the JSON object.
        """

    /// Structured output: the issue's `{entities, facts, summary}` with
    /// every property required, as strict mode requires. Types are listed
    /// in descriptions rather than as an `enum`, so the schema stays within
    /// what every structured-output implementation accepts; the parser
    /// maps unknown types to `.other`.
    public static let jsonSchema = Data(
        #"""
        {"type":"object","additionalProperties":false,"required":["entities","facts","summary"],"properties":{\#
        "entities":{"type":"array","items":{"type":"object","additionalProperties":false,\#
        "required":["name","type","aliases","summary"],"properties":{\#
        "name":{"type":"string"},\#
        "type":{"type":"string","description":"person, organization, place, product, project, event, concept or other"},\#
        "aliases":{"type":"array","items":{"type":"string"}},\#
        "summary":{"type":"string","description":"short description, or empty"}}}},\#
        "facts":{"type":"array","items":{"type":"object","additionalProperties":false,\#
        "required":["subject","predicate","object","confidence","source","replaces"],"properties":{\#
        "subject":{"type":"string","description":"\"user\" or an entity name"},\#
        "predicate":{"type":"string"},\#
        "object":{"type":"string"},\#
        "confidence":{"type":"number","description":"0 to 1"},\#
        "source":{"type":"integer","description":"transcript line number"},\#
        "replaces":{"type":"array","items":{"type":"string"},"description":"handles of known facts it contradicts"}}}},\#
        "summary":{"type":"string"}}}
        """#.utf8)

    /// The schema as a `TextGenerationRequest` takes it.
    public static let responseSchema = JSONResponseSchema(name: "MemoryExtraction", schema: jsonSchema)

    /// The user prompt.
    public func render() -> String {
        var lines = ["Conversation date: \(Self.formatted(date, in: timeZone))"]
        if let topicTitle, !topicTitle.isEmpty {
            lines.append("Topic: \(FactExtraction.clean(topicTitle))")
        }
        lines.append("")
        lines.append("Known entities:")
        if entities.isEmpty {
            lines.append("(none)")
        }
        for entity in entities {
            var line = "- \(entity.name) (\(entity.type?.rawValue ?? MemoryEntityType.other.rawValue)"
            if !entity.aliases.isEmpty {
                line += "; also: \(entity.aliases.joined(separator: ", "))"
            }
            line += ")"
            if let summary = entity.summary, !summary.isEmpty {
                line += ": \(FactExtraction.clean(summary))"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Known facts (still true):")
        if facts.isEmpty {
            lines.append("(none)")
        }
        let names = Dictionary(entities.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for (offset, fact) in facts.enumerated() {
            let subject = fact.subjectID.map { names[$0] ?? "?" } ?? FactExtraction.userSubject
            lines.append(
                "- F\(offset + 1): \(subject) | \(FactExtraction.clean(fact.predicate)) | "
                    + "\(FactExtraction.clean(fact.objectText)) (since \(Self.formatted(fact.validFrom, in: timeZone)))"
            )
        }
        lines.append("")
        lines.append("Transcript:")
        for line in utterances {
            let speaker = line.utterance.speaker == .user ? "User" : "Blau"
            lines.append("[\(line.number)] \(speaker): \(FactExtraction.clean(line.utterance.text))")
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

    // MARK: Windows

    /// A rough token count for budgeting: UTF-8 bytes / 3, which
    /// overestimates English text for typical tokenizers.
    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    /// Splits a topic into windows whose transcripts fit `budget` estimated
    /// tokens, in order, each a separate request. A single utterance longer
    /// than the budget is cut to fit; nothing else is dropped.
    public static func windows(of utterances: [NumberedUtterance], budget: Int) -> [[NumberedUtterance]] {
        let budget = max(budget, 64)
        var windows: [[NumberedUtterance]] = []
        var current: [NumberedUtterance] = []
        var used = 0
        for var line in utterances {
            var cost = estimatedTokens(line.utterance.text) + 4
            if cost > budget {
                line.utterance.text = truncated(line.utterance.text, toUTF8Count: (budget - 4) * 3)
                cost = budget
            }
            if used + cost > budget, !current.isEmpty {
                windows.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += cost
        }
        if !current.isEmpty {
            windows.append(current)
        }
        return windows
    }

    /// `text` cut to at most `limit` UTF-8 bytes, at a character boundary.
    static func truncated(_ text: String, toUTF8Count limit: Int) -> String {
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text[index].utf8.count
            guard count + next <= limit else { break }
            count += next
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    // MARK: Known memory

    /// The known entities whose name or an alias appears in `text` as whole
    /// words (ignoring case and diacritics), at most `limit`, longest name
    /// first so "Acme Robotics" wins over "Acme".
    public static func mentionedEntities(_ entities: [KnownEntity], in text: String, limit: Int) -> [KnownEntity] {
        let haystack = Self.searchable(text)
        var mentioned: [(entity: KnownEntity, length: Int)] = []
        for entity in entities {
            let lengths = entity.names.map(Self.searchable).filter { !$0.isEmpty && containsWord($0, in: haystack) }
                .map(\.count)
            if let longest = lengths.max() {
                mentioned.append((entity, longest))
            }
        }
        return
            mentioned
            .sorted { lhs, rhs in
                lhs.length != rhs.length ? lhs.length > rhs.length : lhs.entity.createdAt < rhs.entity.createdAt
            }
            .prefix(max(0, limit))
            .map(\.entity)
    }

    /// Lowercased, diacritics folded, whitespace collapsed.
    static func searchable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `needle` occurs in `haystack` with no letter or digit right
    /// before or after it.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before =
                range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let isBoundary = { (character: Character?) in
                guard let character else { return true }
                return !(character.isLetter || character.isNumber)
            }
            if isBoundary(before) && isBoundary(after) {
                return true
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    // MARK: Dates

    /// `Wednesday, October 8, 2026`, spelled out by hand (Gregorian, English
    /// names) so the prompt doesn't depend on the device's locale.
    static func formatted(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let month = MemoryChunker.monthNames[max(0, min(11, (parts.month ?? 1) - 1))]
        let weekday = weekdayNames[max(0, min(6, (parts.weekday ?? 1) - 1))]
        return "\(weekday), \(month) \(parts.day ?? 1), \(parts.year ?? 1970)"
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
