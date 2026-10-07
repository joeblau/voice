import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// A memory backend answering from tables, recording every request.
final class FakeMemoryBackend: MemoryToolBackend {
    struct State {
        var queries: [MemoryToolQuery] = []
        var remembered: [(text: String, about: String?)] = []
        var forgotten: [UUID] = []
        var facts: [UUID: MemoryToolFact] = [:]
    }

    let searchResult: MemoryToolSearchResult
    let entities: [MemoryToolEntity]
    let failure: MemoryToolFailure?
    let state = Mutex(State())
    let now: Date

    init(
        searchResult: MemoryToolSearchResult = MemoryToolSearchResult(), entities: [MemoryToolEntity] = [],
        facts: [MemoryToolFact] = [], failure: MemoryToolFailure? = nil, now: Date = MemoryToolsTests.now
    ) {
        self.searchResult = searchResult
        self.entities = entities
        self.failure = failure
        self.now = now
        state.withLock { $0.facts = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) }) }
    }

    var queries: [MemoryToolQuery] { state.withLock { $0.queries } }
    var forgotten: [UUID] { state.withLock { $0.forgotten } }

    func search(_ query: MemoryToolQuery) async throws -> MemoryToolSearchResult {
        state.withLock { $0.queries.append(query) }
        if let failure { throw failure }
        return searchResult
    }

    func entities(named name: String, limit: Int) async throws -> [MemoryToolEntity] {
        if let failure { throw failure }
        return Array(entities.prefix(limit))
    }

    func remember(_ statement: String, about subject: String?) async throws -> MemoryToolFact {
        if let failure { throw failure }
        let fact = MemoryToolFact(
            id: UUID(), statement: statement, subject: subject, validFrom: now, isUserStated: true)
        state.withLock {
            $0.remembered.append((statement, subject))
            $0.facts[fact.id] = fact
        }
        return fact
    }

    func fact(_ id: UUID) async throws -> MemoryToolFact? {
        state.withLock { $0.facts[id] }
    }

    func forget(_ id: UUID) async throws -> MemoryToolFact? {
        state.withLock { state in
            guard var fact = state.facts[id] else { return nil }
            fact.invalidatedAt = fact.invalidatedAt ?? now
            state.facts[id] = fact
            state.forgotten.append(id)
            return fact
        }
    }
}

@Suite("Memory tools")
struct MemoryToolsTests {
    /// 2026-10-08 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_460_800)
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static func settings(clock: ManualClock = ManualClock(now: now), tokens: Int = 1_500) -> MemoryToolSettings {
        MemoryToolSettings(timeZone: { berlin }, maximumOutputTokens: tokens, clock: clock)
    }

    static func json(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    static func call(_ tool: some RealtimeFunctionTool, _ arguments: String, chain: Int? = nil) async throws -> String {
        guard let chain else { return try await tool.call(Data(arguments.utf8)) }
        return try await RealtimeToolCallContext.$current.withValue(RealtimeToolCallContext(callID: "c", chain: chain))
        {
            try await tool.call(Data(arguments.utf8))
        }
    }

    // MARK: - Registration

    @Test func allFourRegisterWithValidSchemas() throws {
        var registry = RealtimeToolRegistry()
        try registry.register(contentsOf: MemoryTools.all(backend: FakeMemoryBackend()))
        #expect(registry.names == ["search_memory", "get_entity", "remember", "forget"])
        #expect(MemoryTools.names == registry.names)
        for definition in registry.definitions {
            guard case .function(_, let description, let parameters) = definition else {
                Issue.record("not a function tool")
                continue
            }
            #expect(!(description ?? "").isEmpty)
            guard case .object(let schema)? = parameters else {
                Issue.record("parameters aren't an object")
                continue
            }
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
        }
        #expect(SearchMemoryTool.timeout == .seconds(5))
    }

    // MARK: - search_memory

    @Test func searchMapsItsArguments() async throws {
        let backend = FakeMemoryBackend()
        let tool = SearchMemoryTool(backend: backend, settings: Self.settings())
        _ = try await Self.call(tool, #"{"query":" what does my company do ","kinds":["company"]}"#)
        _ = try await Self.call(tool, #"{"query":"q","kinds":["facts","knowledge_base"],"limit":40}"#)
        _ = try await Self.call(tool, #"{"query":"q","after":"2026-03-01","before":"2026-04-01","limit":0}"#)
        // One day as both bounds: that whole day.
        _ = try await Self.call(tool, #"{"query":"q","after":"2026-03-14","before":"2026-03-14"}"#)
        _ = try await Self.call(tool, #"{"query":"q","after":"2026-03-14T09:30:00Z"}"#)

        let queries = backend.queries
        #expect(queries[0] == MemoryToolQuery(text: "what does my company do", kinds: [.company], limit: 8))
        #expect(queries[1].kinds == [.fact, .company, .profile, .note, .collection])
        #expect(queries[1].limit == 10)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.berlin
        let march1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let april1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        #expect(queries[2].after == march1)
        #expect(queries[2].before == april1)
        #expect(queries[2].limit == 1)
        let march14 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))
        #expect(queries[3].after == march14)
        #expect(queries[3].before == march14.addingTimeInterval(86_400))
        #expect(queries[4].after == Date(timeIntervalSince1970: 1_773_480_600))
        #expect(queries.allSatisfy { $0.kinds == nil || !$0.kinds!.isEmpty })
    }

    @Test(arguments: [
        #"{"query":"  "}"#,
        #"{"query":"q","after":"last week"}"#,
        #"{"query":"q","before":"2026-13-01"}"#,
        #"{"query":"q","after":"2026-05-01","before":"2026-04-01"}"#,
        #"{"query":"q","kinds":["emails"]}"#,
        #"{"text":"q"}"#,
    ])
    func searchRejectsBadArguments(arguments: String) async throws {
        let backend = FakeMemoryBackend()
        let tool = SearchMemoryTool(backend: backend, settings: Self.settings())
        await #expect(throws: RealtimeToolError.self) { try await Self.call(tool, arguments) }
        #expect(backend.queries.isEmpty)
    }

    @Test func searchOutputHasSourcesDatesAndFactIDs() async throws {
        let factID = UUID()
        let hits = [
            MemoryToolHit(
                id: UUID(), kind: .company, text: "Larderly makes inventory software\nfor restaurants.",
                date: Self.now, source: "Company · Larderly"),
            MemoryToolHit(
                id: UUID(), kind: .conversation, text: "We closed the seed round.", date: Self.now,
                source: "Conversation · Fundraising"),
            MemoryToolHit(
                id: factID, kind: .fact, text: "User lives in Austin", date: Self.now.addingTimeInterval(-86_400 * 30),
                source: "Fact · told by the user", validUntil: Self.now, isUserStated: true),
        ]
        let tool = SearchMemoryTool(
            backend: FakeMemoryBackend(searchResult: MemoryToolSearchResult(hits: hits, usedVectors: true)),
            settings: Self.settings())
        let output = try await Self.call(tool, #"{"query":"company"}"#)
        #expect(
            output == """
                {"results":[{"date":"2026-10-08","kind":"company","source":"Company · Larderly",\
                "text":"Larderly makes inventory software for restaurants."},{"date":"2026-10-08 14:00",\
                "kind":"conversation","source":"Conversation · Fundraising","text":"We closed the seed round."},\
                {"date":"2026-09-08","id":"\(factID.uuidString)","kind":"fact","source":"Fact · told by the user",\
                "text":"User lives in Austin","until":"2026-10-08"}]}
                """)

        let empty = SearchMemoryTool(backend: FakeMemoryBackend(), settings: Self.settings())
        let nothing = try Self.json(try await Self.call(empty, #"{"query":"q"}"#))
        #expect((nothing["results"] as? [Any])?.isEmpty == true)
        #expect(nothing["message"] as? String == "Nothing in memory matches that.")
        #expect(nothing["note"] as? String != nil)
    }

    @Test func searchOutputStaysWithinTheTokenBudget() async throws {
        let long = String(repeating: "restaurant inventory pricing traction ", count: 40)
        let hits = (0..<10).map { index in
            MemoryToolHit(id: UUID(), kind: .note, text: "\(index) \(long)", date: Self.now, source: "Note · \(index)")
        }
        let backend = FakeMemoryBackend(searchResult: MemoryToolSearchResult(hits: hits, usedVectors: true))
        let settings = Self.settings()
        let output = try await Self.call(SearchMemoryTool(backend: backend, settings: settings), #"{"query":"q"}"#)
        #expect(MemoryToolSettings.approximateTokens(output) <= 1_500)
        let object = try Self.json(output)
        let results = try #require(object["results"] as? [[String: Any]])
        let omitted = object["omitted"] as? Int ?? 0
        #expect(results.count + omitted == 10)
        #expect(results.count >= 5)
        #expect(omitted > 0)
        // Best first: the kept ones are the first ones.
        #expect(results.map { $0["source"] as? String } == (0..<results.count).map { "Note · \($0)" })
        // Each result's text is capped.
        #expect(results.allSatisfy { (($0["text"] as? String)?.count ?? 0) <= settings.maximumResultCharacters })

        // A tiny budget still gives valid JSON.
        let tiny = try await Self.call(
            SearchMemoryTool(backend: backend, settings: Self.settings(tokens: 120)), #"{"query":"q"}"#)
        let tinyObject = try Self.json(tiny)
        #expect(MemoryToolSettings.approximateTokens(tiny) <= 120)
        #expect(
            ((tinyObject["results"] as? [Any])?.count ?? 0) + (tinyObject["omitted"] as? Int ?? 0) == 10)
    }

    @Test func backendFailuresReachTheModelAsMessages() async throws {
        let backend = FakeMemoryBackend(failure: .unavailable("Memory search isn't ready yet. Try again in a moment."))
        await #expect(throws: RealtimeToolError.failed("Memory search isn't ready yet. Try again in a moment.")) {
            try await Self.call(SearchMemoryTool(backend: backend), #"{"query":"q"}"#)
        }
        await #expect(throws: RealtimeToolError.failed("Memory search isn't ready yet. Try again in a moment.")) {
            try await Self.call(GetEntityTool(backend: backend), #"{"name":"Alex"}"#)
        }
    }

    // MARK: - get_entity

    @Test func getEntityReturnsATimeline() async throws {
        let entity = MemoryToolEntity(
            id: UUID(), name: "Alex Moreno", type: "person", aliases: ["Alex"], summary: "A friend",
            facts: [
                MemoryToolFact(
                    id: UUID(), statement: "Alex Moreno worked at Stripe", subject: "Alex Moreno",
                    validFrom: Self.now.addingTimeInterval(-86_400 * 400),
                    invalidatedAt: Self.now.addingTimeInterval(-86_400 * 100)),
                MemoryToolFact(
                    id: UUID(), statement: "Alex Moreno designs gardens", subject: "Alex Moreno",
                    validFrom: Self.now.addingTimeInterval(-86_400 * 100)),
            ])
        let other = MemoryToolEntity(id: UUID(), name: "Alex Chen")
        let tool = GetEntityTool(backend: FakeMemoryBackend(entities: [entity, other]), settings: Self.settings())
        let object = try Self.json(try await Self.call(tool, #"{"name":"Alex"}"#))
        let described = try #require(object["entity"] as? [String: Any])
        #expect(described["name"] as? String == "Alex Moreno")
        #expect(described["aliases"] as? [String] == ["Alex"])
        let facts = try #require(described["facts"] as? [[String: Any]])
        #expect(facts.map { $0["text"] as? String } == ["Alex Moreno worked at Stripe", "Alex Moreno designs gardens"])
        #expect(facts[0]["until"] as? String == "2026-06-30")
        #expect(facts[1]["until"] == nil)
        #expect(facts[1]["origin"] as? String == "conversation")
        #expect(object["also_matching"] as? [String] == ["Alex Chen"])

        let unknown = try Self.json(
            try await Self.call(GetEntityTool(backend: FakeMemoryBackend()), #"{"name":"Nobody"}"#))
        #expect(unknown["entity"] is NSNull)
        #expect(unknown["message"] != nil)
        await #expect(throws: RealtimeToolError.self) { try await Self.call(tool, #"{"name":" "}"#) }
    }

    @Test func getEntityDropsTheOldestFactsFirstOverBudget() async throws {
        let facts = (0..<80).map { index in
            MemoryToolFact(
                id: UUID(), statement: "Acme fact number \(index) " + String(repeating: "detail ", count: 20),
                subject: "Acme", validFrom: Self.now.addingTimeInterval(Double(index) * 86_400))
        }
        let entity = MemoryToolEntity(id: UUID(), name: "Acme", facts: facts)
        let output = try await Self.call(
            GetEntityTool(backend: FakeMemoryBackend(entities: [entity]), settings: Self.settings()),
            #"{"name":"Acme"}"#)
        #expect(MemoryToolSettings.approximateTokens(output) <= 1_500)
        let described = try #require(try Self.json(output)["entity"] as? [String: Any])
        let kept = try #require(described["facts"] as? [[String: Any]])
        let omitted = try #require(described["earlier_facts_omitted"] as? Int)
        #expect(kept.count + omitted == 80)
        #expect((kept.last?["text"] as? String)?.hasPrefix("Acme fact number 79") == true)
    }

    // MARK: - remember

    @Test func rememberStoresTheSentence() async throws {
        let backend = FakeMemoryBackend()
        let tool = RememberTool(backend: backend, settings: Self.settings())
        let object = try Self.json(
            try await Self.call(tool, #"{"text":"The user's sister Maya lives in Lisbon","about":"  "}"#))
        let remembered = try #require(object["remembered"] as? [String: Any])
        #expect(remembered["text"] as? String == "The user's sister Maya lives in Lisbon")
        #expect(remembered["origin"] as? String == "user")
        #expect(remembered["since"] as? String == "2026-10-08")
        _ = try await Self.call(tool, #"{"text":"Priya runs the Lisbon office","about":"Priya"}"#)
        let calls = backend.state.withLock { $0.remembered }
        #expect(calls.map(\.text) == ["The user's sister Maya lives in Lisbon", "Priya runs the Lisbon office"])
        #expect(calls.map(\.about) == [nil, "Priya"])
        await #expect(throws: RealtimeToolError.self) { try await Self.call(tool, #"{"text":""}"#) }
    }

    // MARK: - forget

    static func forgetHarness(clock: ManualClock = ManualClock(now: now)) -> (ForgetTool, FakeMemoryBackend, UUID) {
        let fact = MemoryToolFact(
            id: UUID(), statement: "The user is allergic to peanuts", validFrom: now, isUserStated: true)
        let backend = FakeMemoryBackend(facts: [fact])
        return (ForgetTool(backend: backend, settings: settings(clock: clock)), backend, fact.id)
    }

    @Test func forgetNeedsASpokenConfirmation() async throws {
        let (tool, backend, id) = Self.forgetHarness()

        // Asked: nothing is forgotten, the fact comes back to be read out.
        let asked = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)"}"#, chain: 1))
        #expect(asked["status"] as? String == "needs_confirmation")
        #expect((asked["fact"] as? [String: Any])?["text"] as? String == "The user is allergic to peanuts")
        #expect(asked["instruction"] != nil)
        #expect(backend.forgotten.isEmpty)

        // Grok can't confirm on its own in the same chain (a follow-up).
        let early = try Self.json(
            try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 1))
        #expect(early["status"] as? String == "needs_confirmation")
        #expect(backend.forgotten.isEmpty)

        // The user said yes: a later chain.
        let done = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 2))
        #expect(done["status"] as? String == "forgotten")
        #expect((done["fact"] as? [String: Any])?["until"] as? String == "2026-10-08")
        #expect(backend.forgotten == [id])

        // Asking again: it's gone already.
        let again = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 3))
        #expect(again["status"] as? String == "already_forgotten")
        #expect(backend.forgotten == [id])
    }

    @Test func forgetWithoutARequestOrAfterItExpiredAsksAgain() async throws {
        let clock = ManualClock(now: Self.now)
        let (tool, backend, id) = Self.forgetHarness(clock: clock)
        // Confirming out of the blue asks first.
        let blind = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 4))
        #expect(blind["status"] as? String == "needs_confirmation")
        // Outside the runner (no chain) nothing is ever confirmed.
        let noChain = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#))
        #expect(noChain["status"] as? String == "needs_confirmation")
        // Asked, then the answer comes too late.
        _ = try await Self.call(tool, #"{"id":"\#(id.uuidString)"}"#, chain: 5)
        clock.advance(by: .seconds(301))
        let late = try Self.json(try await Self.call(tool, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 6))
        #expect(late["status"] as? String == "needs_confirmation")
        #expect(backend.forgotten.isEmpty)
        // A copy of the tool (the registry is a value) shares the requests.
        let copy = tool
        let confirmed = try Self.json(
            try await Self.call(copy, #"{"id":"\#(id.uuidString)","confirm":true}"#, chain: 7))
        #expect(confirmed["status"] as? String == "forgotten")
    }

    @Test func forgetOnlyTakesFactIDs() async throws {
        let (tool, _, _) = Self.forgetHarness()
        await #expect(throws: RealtimeToolError.self) { try await Self.call(tool, #"{"id":"peanuts"}"#, chain: 1) }
        await #expect(
            throws: RealtimeToolError.failed(
                "No fact has that id. Only facts can be forgotten; find one with search_memory or get_entity.")
        ) {
            try await Self.call(tool, #"{"id":"\#(UUID().uuidString)"}"#, chain: 1)
        }
    }

    // MARK: - Dates

    @Test func parsesTheDateFormsGrokSends() throws {
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            MemoryToolText.parseDate("2026-03-14", timeZone: utc)?.date == Date(timeIntervalSince1970: 1_773_446_400))
        #expect(MemoryToolText.parseDate("2026-03-14", timeZone: utc)?.isDay == true)
        #expect(MemoryToolText.parseDate("2026-03", timeZone: utc)?.date == Date(timeIntervalSince1970: 1_772_323_200))
        #expect(
            MemoryToolText.parseDate("2026-03-14T10:00:00+01:00", timeZone: utc)?.date
                == Date(timeIntervalSince1970: 1_773_478_800))
        #expect(
            MemoryToolText.parseDate("2026-03-14T10:00", timeZone: utc)?.date
                == Date(timeIntervalSince1970: 1_773_482_400))
        #expect(MemoryToolText.parseDate("2026-02-30", timeZone: utc) == nil)
        #expect(MemoryToolText.parseDate("yesterday", timeZone: utc) == nil)
        #expect(MemoryToolText.clipped("one two three four", to: 9) == "one two…")
        #expect(MemoryToolText.clipped("a\n  b", to: 10) == "a b")
    }
}
