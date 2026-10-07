import BlauPersistence
import Foundation

/// A LongMemEval-style memory evaluation set (#70): a user's conversations
/// over several months, knowledge-base documents, entities and
/// validity-dated facts, and questions about them with reference answers
/// and the records that answer them.
///
/// A dataset is a directory: `manifest.json` (name, consent, the "now" the
/// questions are asked at) and any number of other `*.json` files, each
/// holding some of `entities`, `sessions`, `documents`, `facts` and
/// `questions`, merged in file-name order. Blau's own set is in
/// `Tests/BlauMemoryTests/Fixtures/MemoryEval`; the format is in
/// docs/memory-eval.md.
///
/// Evidence ids name what a question is answered by: a turn of a session
/// (one exchange in the index), a document, a collection item or a fact.
/// They share one namespace.
public struct MemoryEvalDataset: Hashable, Sendable {
    /// LongMemEval's question abilities, as #70 groups them.
    public enum QuestionType: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
        /// One fact the user said, Blau said, or a document holds.
        case singleFact = "single-fact"
        /// Needs the time of what was said: "last week", "when did I",
        /// "how many days between".
        case temporal
        /// A later record replaces an earlier one; the answer is the latest.
        case knowledgeUpdate = "knowledge-update"
        /// Two records joined through an entity ("my partner" → Alex →
        /// Alex's job).
        case multiHop = "multi-hop"
        /// Memory doesn't hold the answer; the right reply says so.
        case abstention

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public struct Manifest: Codable, Hashable, Sendable {
        public var name: String
        public var version: Int?
        public var description: String?
        /// Who agreed to what, or that the set is synthetic. Required.
        public var consent: String
        /// What to call the user in prompts (facts about the user say
        /// "User", as `Fact.statement()` does).
        public var userName: String?
        /// When the questions are asked: relative dates ("last week")
        /// resolve against it and current facts are those valid at it.
        public var now: Date
        /// The time zone of "today" and of dates in chunk keys.
        public var timeZone: String
        /// The first day of a week, 1 = Sunday.
        public var firstWeekday: Int?
    }

    public struct Entity: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var aliases: [String]
        /// A `MemoryEntityType` raw value.
        public var type: String?

        public init(id: String, name: String, aliases: [String] = [], type: String? = nil) {
            self.id = id
            self.name = name
            self.aliases = aliases
            self.type = type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            type = try container.decodeIfPresent(String.self, forKey: .type)
        }
    }

    /// One exchange: what the user said and Blau's reply.
    public struct Turn: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var user: String
        public var assistant: String

        public init(id: String, user: String, assistant: String) {
            self.id = id
            self.user = user
            self.assistant = assistant
        }
    }

    /// One conversation. Turns are two minutes apart from `startedAt`.
    public struct Session: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var startedAt: Date
        /// The topic's title, if the conversation has one.
        public var topic: String?
        public var turns: [Turn]

        public init(id: String, startedAt: Date, topic: String? = nil, turns: [Turn]) {
            self.id = id
            self.startedAt = startedAt
            self.topic = topic
            self.turns = turns
        }
    }

    /// A collection item: a prompt to practice and its reference answer.
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var prompt: String
        public var answer: String?

        public init(id: String, prompt: String, answer: String? = nil) {
            self.id = id
            self.prompt = prompt
            self.answer = answer
        }
    }

    /// A knowledge-base document; a `collection` holds `items`.
    public struct Document: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: DocumentKind
        public var title: String
        public var body: String
        public var updatedAt: Date
        public var items: [Item]

        public init(id: String, kind: DocumentKind, title: String, body: String, updatedAt: Date, items: [Item] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
            self.updatedAt = updatedAt
            self.items = items
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = try container.decode(DocumentKind.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        }
    }

    /// A fact as the extraction pipeline (#66) stores it: subject,
    /// predicate, object, and when it held.
    public struct Fact: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// An entity id; `nil` for a fact about the user.
        public var subject: String?
        public var predicate: String
        public var object: String
        public var validFrom: Date
        public var invalidatedAt: Date?
        /// The turn it was extracted from, which puts it in that exchange's
        /// key text.
        public var source: String?

        public init(
            id: String, subject: String? = nil, predicate: String, object: String, validFrom: Date,
            invalidatedAt: Date? = nil, source: String? = nil
        ) {
            self.id = id
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.validFrom = validFrom
            self.invalidatedAt = invalidatedAt
            self.source = source
        }
    }

    /// One piece of evidence a question needs, satisfied by any of
    /// `alternatives` (written `"a|b"` in JSON): the same fact said in a
    /// conversation and stored as a fact, for example.
    public struct Evidence: Codable, Hashable, Sendable, CustomStringConvertible {
        public var alternatives: [String]

        public init(_ alternatives: [String]) {
            self.alternatives = alternatives
        }

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            alternatives = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }

        public var description: String { alternatives.joined(separator: "|") }
    }

    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var type: QuestionType
        public var question: String
        /// The reference answer; for an abstention question, why memory
        /// can't answer it.
        public var answer: String
        /// Every piece of evidence the answer needs; empty for abstention.
        public var evidence: [Evidence]
        /// For a knowledge update: the superseded records, which should rank
        /// below the current evidence.
        public var stale: [String]

        public init(
            id: String, type: QuestionType, question: String, answer: String, evidence: [Evidence] = [],
            stale: [String] = []
        ) {
            self.id = id
            self.type = type
            self.question = question
            self.answer = answer
            self.evidence = evidence
            self.stale = stale
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(QuestionType.self, forKey: .type)
            question = try container.decode(String.self, forKey: .question)
            answer = try container.decode(String.self, forKey: .answer)
            evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
            stale = try container.decodeIfPresent([String].self, forKey: .stale) ?? []
        }
    }

    public enum LoadError: Error, Hashable, Sendable, CustomStringConvertible {
        case missingManifest(String)
        case missingConsent
        case unknownTimeZone(String)
        case duplicateID(String)
        case emptySession(String)
        case emptyText(String)
        case unknownSubject(fact: String, entity: String)
        case unknownSource(fact: String, turn: String)
        case invalidValidity(fact: String)
        case datedAfterNow(String)
        case noEvidence(question: String)
        case abstentionWithEvidence(question: String)
        case unknownEvidence(question: String, id: String)
        case staleOutsideKnowledgeUpdate(question: String)
        case staleIsEvidence(question: String, id: String)

        public var description: String {
            switch self {
            case .missingManifest(let path): "No manifest.json in \(path)"
            case .missingConsent: "The manifest has no consent statement"
            case .unknownTimeZone(let id): "Unknown time zone \(id)"
            case .duplicateID(let id): "Id \(id) appears more than once"
            case .emptySession(let id): "Session \(id) has no turns"
            case .emptyText(let id): "\(id) has blank text"
            case .unknownSubject(let fact, let entity): "Fact \(fact) is about unknown entity \(entity)"
            case .unknownSource(let fact, let turn): "Fact \(fact) cites unknown turn \(turn)"
            case .invalidValidity(let fact): "Fact \(fact) is invalidated before it became valid"
            case .datedAfterNow(let id): "\(id) is dated after the dataset's now"
            case .noEvidence(let question): "Question \(question) lists no evidence"
            case .abstentionWithEvidence(let question): "Abstention question \(question) lists evidence"
            case .unknownEvidence(let question, let id): "Question \(question) cites unknown evidence \(id)"
            case .staleOutsideKnowledgeUpdate(let question):
                "Question \(question) lists stale records but isn't a knowledge update"
            case .staleIsEvidence(let question, let id): "Question \(question) lists \(id) as evidence and as stale"
            }
        }
    }

    public var manifest: Manifest
    public private(set) var entities: [Entity]
    public private(set) var sessions: [Session]
    public private(set) var documents: [Document]
    public private(set) var facts: [Fact]
    public private(set) var questions: [Question]

    public var name: String { manifest.name }
    public var now: Date { manifest.now }
    public var userName: String { manifest.userName ?? "the user" }
    /// The manifest's time zone (validated on init).
    public var timeZone: TimeZone { TimeZone(identifier: manifest.timeZone) ?? .gmt }

    /// Validates ids, references, dates and evidence.
    public init(
        manifest: Manifest, entities: [Entity] = [], sessions: [Session] = [], documents: [Document] = [],
        facts: [Fact] = [], questions: [Question] = []
    ) throws(LoadError) {
        guard !manifest.consent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .missingConsent
        }
        guard TimeZone(identifier: manifest.timeZone) != nil else { throw .unknownTimeZone(manifest.timeZone) }
        func blank(_ text: String) -> Bool { text.allSatisfy(\.isWhitespace) }

        var entityIDs = Set<String>()
        for entity in entities {
            guard entityIDs.insert(entity.id).inserted else { throw .duplicateID(entity.id) }
            if blank(entity.name) { throw .emptyText(entity.id) }
        }
        var evidenceIDs = Set<String>()
        func register(_ id: String, date: Date) throws(LoadError) {
            guard evidenceIDs.insert(id).inserted else { throw .duplicateID(id) }
            guard date <= manifest.now else { throw .datedAfterNow(id) }
        }
        var sessionIDs = Set<String>()
        var turnIDs = Set<String>()
        for session in sessions {
            guard sessionIDs.insert(session.id).inserted else { throw .duplicateID(session.id) }
            guard !session.turns.isEmpty else { throw .emptySession(session.id) }
            for (index, turn) in session.turns.enumerated() {
                try register(turn.id, date: Self.startOfTurn(index, in: session))
                if blank(turn.user) || blank(turn.assistant) { throw .emptyText(turn.id) }
                turnIDs.insert(turn.id)
            }
        }
        for document in documents {
            try register(document.id, date: document.updatedAt)
            if blank(document.title) { throw .emptyText(document.id) }
            for item in document.items {
                try register(item.id, date: document.updatedAt)
                if blank(item.prompt) { throw .emptyText(item.id) }
            }
        }
        for fact in facts {
            try register(fact.id, date: fact.validFrom)
            if blank(fact.predicate) && blank(fact.object) { throw .emptyText(fact.id) }
            if let subject = fact.subject, !entityIDs.contains(subject) {
                throw .unknownSubject(fact: fact.id, entity: subject)
            }
            if let source = fact.source, !turnIDs.contains(source) {
                throw .unknownSource(fact: fact.id, turn: source)
            }
            if let end = fact.invalidatedAt, end <= fact.validFrom { throw .invalidValidity(fact: fact.id) }
        }
        var questionIDs = Set<String>()
        for question in questions {
            guard questionIDs.insert(question.id).inserted else { throw .duplicateID(question.id) }
            if blank(question.question) || blank(question.answer) { throw .emptyText(question.id) }
            let cited = question.evidence.flatMap(\.alternatives)
            if question.type == .abstention {
                guard cited.isEmpty else { throw .abstentionWithEvidence(question: question.id) }
            } else {
                guard !question.evidence.isEmpty, question.evidence.allSatisfy({ !$0.alternatives.isEmpty }) else {
                    throw .noEvidence(question: question.id)
                }
            }
            for id in cited + question.stale where !evidenceIDs.contains(id) {
                throw .unknownEvidence(question: question.id, id: id)
            }
            if !question.stale.isEmpty {
                guard question.type == .knowledgeUpdate else {
                    throw .staleOutsideKnowledgeUpdate(question: question.id)
                }
                if let both = question.stale.first(where: Set(cited).contains) {
                    throw .staleIsEvidence(question: question.id, id: both)
                }
            }
        }

        self.manifest = manifest
        self.entities = entities
        self.sessions = sessions
        self.documents = documents
        self.facts = facts
        self.questions = questions
    }

    /// When turn `index` of `session` starts: two minutes per turn.
    public static func startOfTurn(_ index: Int, in session: Session) -> Date {
        session.startedAt.addingTimeInterval(Double(index) * 120)
    }

    /// The questions of `types` (all for `nil`), in dataset order.
    public func questions(ofTypes types: Set<QuestionType>?) -> [Question] {
        guard let types else { return questions }
        return questions.filter { types.contains($0.type) }
    }

    /// The set with only some questions; the corpus stays whole.
    public func limited(toTypes types: Set<QuestionType>?, ids: Set<String>? = nil, first: Int? = nil)
        -> MemoryEvalDataset
    {
        var copy = self
        copy.questions = questions(ofTypes: types).filter { ids?.contains($0.id) ?? true }
        if let first { copy.questions = Array(copy.questions.prefix(max(0, first))) }
        return copy
    }

    // MARK: - Loading

    /// Loads `manifest.json` and every other `*.json` file in `directory`.
    public static func load(directory: URL) throws -> MemoryEvalDataset {
        let manifestURL = directory.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw LoadError.missingManifest(directory.path(percentEncoded: false))
        }
        let decoder = Self.decoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var part = Part()
        for file in files {
            let next = try decoder.decode(Part.self, from: Data(contentsOf: file))
            part.entities = (part.entities ?? []) + (next.entities ?? [])
            part.sessions = (part.sessions ?? []) + (next.sessions ?? [])
            part.documents = (part.documents ?? []) + (next.documents ?? [])
            part.facts = (part.facts ?? []) + (next.facts ?? [])
            part.questions = (part.questions ?? []) + (next.questions ?? [])
        }
        return try MemoryEvalDataset(
            manifest: manifest, entities: part.entities ?? [],
            sessions: (part.sessions ?? []).sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) },
            documents: part.documents ?? [], facts: part.facts ?? [], questions: part.questions ?? [])
    }

    /// Dates are ISO 8601 (`2026-09-15T19:00:00Z`) or a calendar day
    /// (`2026-09-15`, read as noon UTC).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO 8601 date or yyyy-MM-dd, got \(text)")
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let day = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
        return (try? Date(text, strategy: day))?.addingTimeInterval(12 * 3600)
    }

    struct Part: Decodable {
        var entities: [Entity]?
        var sessions: [Session]?
        var documents: [Document]?
        var facts: [Fact]?
        var questions: [Question]?
    }
}
