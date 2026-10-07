import BlauCore
import Foundation

/// `search_memory(query, after?, before?, kinds?, limit = 8)`: hybrid search
/// over past conversations, the knowledge base and facts (#68).
///
/// The output lists the hits best first, each with its text, a short
/// source ("Company · Acme", "Conversation · Fundraising") and its date in
/// the user's time zone; facts carry the id `forget` takes, and a fact that
/// no longer holds says since when (`until`). It is kept under
/// ``MemoryToolSettings/maximumOutputTokens``: results that don't fit are
/// shortened, then left out and counted in `omitted`.
///
/// ```json
/// {"results":[{"date":"2026-10-02","kind":"company","source":"Company · Acme",
///   "text":"Acme makes scheduling software for independent restaurants…"}]}
/// ```
public struct SearchMemoryTool: RealtimeTypedFunctionTool {
    public struct Arguments: Decodable, Sendable, Hashable {
        public var query: String
        public var after: String?
        public var before: String?
        public var kinds: [String]?
        public var limit: Int?

        public init(
            query: String, after: String? = nil, before: String? = nil, kinds: [String]? = nil, limit: Int? = nil
        ) {
            self.query = query
            self.after = after
            self.before = before
            self.kinds = kinds
            self.limit = limit
        }
    }

    public static let name = "search_memory"
    public static let description = """
        Search the user's long-term memory: earlier conversations with you, their knowledge base (company, \
        profile, notes, and collections such as interview questions) and facts they told you. Call it before \
        answering whenever the user asks about something they said or wrote down before, their company or work, \
        or an earlier conversation, and the answer isn't already in this conversation. Each result has a source \
        and a date; prefer newer ones.
        """
    public static let parameters: JSONSchema = .object(
        properties: [
            "query": .string(
                description: """
                    What to look for, in plain words, e.g. "what my company does" or "fundraising plans last week". \
                    Time words in it rank memories from that time first.
                    """),
            "after": .string(
                description: """
                    Only memories from this time on: YYYY-MM-DD or an ISO 8601 date-time (user's time zone). Only \
                    for an exact range.
                    """),
            "before": .string(
                description: "Only memories from before this time (exclusive), in the same format as after."),
            "kinds": .array(
                of: .string(enum: MemoryToolKind.allCases.map(\.rawValue)),
                description: """
                    Only these kinds of memory. Use ["company"] for the user's company, product, team or traction, \
                    and ["profile"] for their own background.
                    """),
            "limit": .integer(description: "How many results, 1 to 10. Default 8.", minimum: 1, maximum: 10),
        ],
        required: ["query"],
        additionalProperties: false)
    /// Embedding the query, searching and labelling: well under a second,
    /// with room for a cold embedding model.
    public static let timeout: Duration = .seconds(5)

    public let backend: any MemoryToolBackend
    public let settings: MemoryToolSettings

    public init(backend: any MemoryToolBackend, settings: MemoryToolSettings = MemoryToolSettings()) {
        self.backend = backend
        self.settings = settings
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = try self.query(from: arguments)
        let result = try await MemoryToolText.run { try await backend.search(query) }
        return Self.output(for: result, settings: settings)
    }

    /// The backend query for `arguments`, validated.
    func query(from arguments: Arguments) throws -> MemoryToolQuery {
        let text = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RealtimeToolError.invalidArguments("query is empty") }
        let timeZone = settings.timeZone()
        var after: (date: Date, isDay: Bool)?
        var before: (date: Date, isDay: Bool)?
        if let value = arguments.after?.nonBlank {
            guard let date = MemoryToolText.parseDate(value, timeZone: timeZone) else {
                throw RealtimeToolError.invalidArguments("after must be YYYY-MM-DD or an ISO 8601 date-time")
            }
            after = date
        }
        if let value = arguments.before?.nonBlank {
            guard let date = MemoryToolText.parseDate(value, timeZone: timeZone) else {
                throw RealtimeToolError.invalidArguments("before must be YYYY-MM-DD or an ISO 8601 date-time")
            }
            before = date
        }
        // "On March 14" often arrives as after = before = that day: make it
        // the whole day rather than an empty range.
        if let lower = after, let upper = before, lower.isDay, upper.isDay, upper.date == lower.date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            before = (calendar.date(byAdding: .day, value: 1, to: lower.date) ?? upper.date, true)
        }
        if let lower = after?.date, let upper = before?.date, upper <= lower {
            throw RealtimeToolError.invalidArguments("before must be later than after")
        }
        var kinds: Set<MemoryToolKind>?
        if let names = arguments.kinds, !names.isEmpty {
            var parsed = Set<MemoryToolKind>()
            for name in names {
                guard let kind = Self.kind(named: name) else {
                    let valid = MemoryToolKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw RealtimeToolError.invalidArguments("unknown kind; use \(valid)")
                }
                parsed.formUnion(kind)
            }
            kinds = parsed
        }
        let limit = min(max(arguments.limit ?? settings.defaultSearchLimit, 1), settings.maximumSearchLimit)
        return MemoryToolQuery(text: text, after: after?.date, before: before?.date, kinds: kinds, limit: limit)
    }

    /// A kind name as the model may write it: the schema's names, plurals,
    /// and "document" / "knowledge_base" for every document kind.
    static func kind(named name: String) -> Set<MemoryToolKind>? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_")
        if let kind = MemoryToolKind(rawValue: key) { return [kind] }
        switch key {
        case "conversations", "chat", "chats": return [.conversation]
        case "companies", "company_info": return [.company]
        case "profiles": return [.profile]
        case "notes": return [.note]
        case "collections", "collection_item", "collection_items", "questions": return [.collection]
        case "facts": return [.fact]
        case "document", "documents", "knowledge_base", "knowledge": return MemoryToolKind.documentKinds
        default: return nil
        }
    }

    // MARK: Output

    struct Output: Encodable {
        struct Result: Encodable {
            /// Facts only: what `forget` takes.
            var id: String?
            var kind: String
            var source: String
            var date: String
            var until: String?
            var text: String
        }

        var results: [Result]
        /// Results left out to stay within the budget.
        var omitted: Int?
        var message: String?
        var note: String?
    }

    /// The output for `result`, within the budget.
    static func output(for result: MemoryToolSearchResult, settings: MemoryToolSettings) -> String {
        let timeZone = settings.timeZone()
        let note = result.usedVectors ? nil : "Matched on words only; rephrasing may find more."
        guard !result.hits.isEmpty else {
            return encode(Output(results: [], message: "Nothing in memory matches that.", note: note))
        }
        let results = result.hits.map { hit in
            Output.Result(
                id: hit.kind == .fact ? hit.id.uuidString : nil,
                kind: hit.kind.rawValue,
                source: hit.source,
                date: hit.kind == .conversation
                    ? MemoryToolText.minute(hit.date, timeZone: timeZone)
                    : MemoryToolText.day(hit.date, timeZone: timeZone),
                until: hit.validUntil.map { MemoryToolText.day($0, timeZone: timeZone) },
                text: MemoryToolText.clipped(hit.text, to: settings.maximumResultCharacters))
        }
        return fitted(results, note: note, settings: settings)
    }

    /// As many results as fit the budget, best first: the first one that
    /// doesn't fit is shortened if a useful part of it does, and the rest
    /// are counted in `omitted`.
    static func fitted(_ results: [Output.Result], note: String?, settings: MemoryToolSettings) -> String {
        var kept: [Output.Result] = []
        for (index, result) in results.enumerated() {
            let omitted = results.count - index - 1
            let candidate = Output(results: kept + [result], omitted: omitted > 0 ? omitted : nil, note: note)
            let encoded = encode(candidate)
            if settings.fits(encoded) {
                kept.append(result)
                continue
            }
            // Shorten this one to what is left, if that leaves enough to
            // be worth reading.
            var shortened = result
            var length = result.text.count
            while length > 120 {
                length = length * 3 / 4
                shortened.text = MemoryToolText.clipped(result.text, to: length)
                let output = Output(results: kept + [shortened], omitted: omitted > 0 ? omitted : nil, note: note)
                if settings.fits(encode(output)) {
                    return encode(output)
                }
            }
            return encode(Output(results: kept, omitted: results.count - index, note: note))
        }
        return encode(Output(results: kept, note: note))
    }

    static func encode(_ output: Output) -> String {
        (try? RealtimeToolOutput.json(output)) ?? #"{"results":[]}"#
    }
}

extension String {
    /// `nil` when empty or only whitespace.
    var nonBlank: String? {
        allSatisfy(\.isWhitespace) ? nil : self
    }
}
