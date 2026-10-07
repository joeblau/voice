import BlauPersistence
import Foundation

/// What the text model extracted from one window of a closed topic: the
/// structured reply of the extraction prompt (`FactExtractionPrompt`),
/// validated.
///
/// The reply's shape is the issue's
/// `{entities:[{name,type,aliases}], facts:[{subject,predicate,object,confidence}], summary}`
/// plus three fields the pipeline needs: an entity's one-line `summary`, a
/// fact's `source` (the number of the utterance it came from, for
/// `Fact.sourceUtteranceID`) and `replaces` (the handles of known facts it
/// contradicts, which are invalidated rather than deleted).
public struct FactExtraction: Hashable, Sendable {
    public var entities: [Entity]
    public var facts: [Statement]
    /// One or two sentences on what the window says about the user.
    public var summary: String

    public init(entities: [Entity] = [], facts: [Statement] = [], summary: String = "") {
        self.entities = entities
        self.facts = facts
        self.summary = summary
    }

    /// Someone or something the conversation mentions.
    public struct Entity: Hashable, Sendable {
        public var name: String
        public var type: MemoryEntityType
        public var aliases: [String]
        /// A short description, e.g. "Co-founder of Y Combinator", or `nil`.
        public var summary: String?

        public init(name: String, type: MemoryEntityType, aliases: [String] = [], summary: String? = nil) {
            self.name = name
            self.type = type
            self.aliases = aliases
            self.summary = summary
        }
    }

    /// One "<subject> <predicate> <object>" statement.
    public struct Statement: Hashable, Sendable {
        /// The entity the fact is about, by the name the reply used, or
        /// `nil` for the user.
        public var subject: String?
        public var predicate: String
        public var object: String
        /// In `0...1`.
        public var confidence: Double
        /// The 1-based number of the utterance the fact comes from, as the
        /// prompt numbered them, or `nil`.
        public var source: Int?
        /// Handles (`F1`, `F2`...) of known facts this one contradicts.
        public var replaces: [String]

        public init(
            subject: String?,
            predicate: String,
            object: String,
            confidence: Double = 1,
            source: Int? = nil,
            replaces: [String] = []
        ) {
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.confidence = confidence
            self.source = source
            self.replaces = replaces
        }
    }
}

/// Why an extraction reply was refused.
public enum FactExtractionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The reply isn't the JSON object the prompt asked for.
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .invalidResponse(let reason): "Invalid extraction reply: \(reason)"
        }
    }
}

extension FactExtraction {
    /// The subject the prompt asks the model to use for the user.
    public static let userSubject = "user"

    /// The most entities and facts kept from one reply; the rest is noise
    /// from a model that ignored the instructions.
    public static let maximumEntities = 40
    public static let maximumFacts = 60

    /// Parses a reply leniently: the JSON object anywhere in the text (a
    /// model may wrap it in prose or a code fence), numbers or strings for
    /// numeric fields, unknown entity types as `.other`. Structured output
    /// is a request, not a guarantee, so everything is validated: blank
    /// names, predicates and objects are dropped, confidences are clamped
    /// to `0...1`, and a subject naming the user in any common way becomes
    /// `nil`.
    ///
    /// - Throws: `FactExtractionError.invalidResponse` when there is no JSON
    ///   object, or it has neither entities nor facts nor a summary.
    public static func parse(_ reply: String) throws(FactExtractionError) -> FactExtraction {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw .invalidResponse("No JSON object in the reply")
        }
        let json = Data(reply[start...end].utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw .invalidResponse("The reply's JSON is not an object")
        }
        let rawEntities = object["entities"] as? [Any]
        let rawFacts = object["facts"] as? [Any]
        let summary = (object["summary"] as? String).map(Self.clean) ?? ""
        guard rawEntities != nil || rawFacts != nil || !summary.isEmpty else {
            throw .invalidResponse("The reply has no entities, facts or summary")
        }

        var entities: [Entity] = []
        for case let raw as [String: Any] in rawEntities ?? [] {
            guard let name = (raw["name"] as? String).map(Self.clean), !name.isEmpty else { continue }
            let type = (raw["type"] as? String).flatMap { MemoryEntityType(rawValue: $0.lowercased()) } ?? .other
            let aliases = (raw["aliases"] as? [Any] ?? []).compactMap { ($0 as? String).map(Self.clean) }
                .filter { !$0.isEmpty }
            let summary = (raw["summary"] as? String).map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
            entities.append(Entity(name: name, type: type, aliases: aliases, summary: summary))
            if entities.count == maximumEntities { break }
        }

        var facts: [Statement] = []
        for case let raw as [String: Any] in rawFacts ?? [] {
            guard let predicate = (raw["predicate"] as? String).map(Self.clean), !predicate.isEmpty,
                let value = Self.text(raw["object"]).map(Self.clean), !value.isEmpty
            else { continue }
            let subject = (raw["subject"] as? String).map(Self.clean)
            facts.append(
                Statement(
                    subject: subject.flatMap { isUser($0) ? nil : $0 },
                    predicate: predicate,
                    object: value,
                    confidence: Self.number(raw["confidence"]).map(Self.clampedConfidence) ?? 1,
                    source: Self.number(raw["source"]).flatMap(Self.lineNumber),
                    replaces: (raw["replaces"] as? [Any] ?? []).compactMap { Self.text($0).map(Self.clean) }
                        .filter { !$0.isEmpty }
                ))
            if facts.count == maximumFacts { break }
        }
        return FactExtraction(entities: entities, facts: facts, summary: summary)
    }

    /// Whether a reply's subject means the user ("user", "I", "me", "the
    /// user"...), or is blank.
    static func isUser(_ subject: String) -> Bool {
        let key = MatchKey(subject).value
        return key.isEmpty || ["user", "the user", "i", "me", "myself", "speaker", "the speaker"].contains(key)
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// A source line number, or `nil` when the value can't be one. The reply
    /// is untrusted and `Int(_:)` traps on an out-of-range `Double` (`1e20`),
    /// so the value is bounded before it is converted.
    static func lineNumber(_ value: Double) -> Int? {
        guard value.isFinite, value >= 1, value <= Double(Int32.max) else { return nil }
        return Int(exactly: value.rounded(.down))
    }

    private static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }
}

/// A comparison key for names, predicates and objects: trimmed, inner
/// whitespace collapsed, case-, diacritic- and width-insensitive, trailing
/// sentence punctuation dropped. "Works at" and "works  at." compare equal.
struct MatchKey: Hashable, Sendable {
    let value: String

    init(_ text: String) {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var collapsed = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = collapsed.last, ".,;:!?".contains(last) {
            collapsed.removeLast()
        }
        value = collapsed.trimmingCharacters(in: .whitespaces)
    }
}
