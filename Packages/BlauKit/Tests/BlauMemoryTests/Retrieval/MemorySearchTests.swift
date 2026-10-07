import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Memory search")
struct MemorySearchTests {
    static let day: TimeInterval = 86_400
    /// "Now" in these tests: ten days after `t0`, at noon UTC.
    static let now = IndexTestSupport.t0.addingTimeInterval(10 * day)

    /// An index written through the hashing embedder, and searches over it.
    struct Harness {
        let index: MemoryIndex
        let embedder = IndexTestSupport.HashingEmbedder()

        init() throws {
            index = try MemoryIndex.inMemory()
        }

        @discardableResult
        func add(
            _ text: String, kind: MemorySourceKind = .document, createdAt: Date = IndexTestSupport.t0,
            sourceID: UUID = UUID()
        ) async throws -> MemoryChunk {
            let chunk = MemoryChunk(
                sourceID: sourceID, sourceKind: kind, ordinal: 0, text: text, keyText: text, createdAt: createdAt)
            try await index.replace(
                [MemoryIndex.SourceChunks(kind: kind, sourceID: sourceID, chunks: [chunk])],
                embeddings: [chunk.id: embedder.embed(text)])
            return chunk
        }

        func search(
            vectors: Bool = true, entities: (any MemoryEntityGraphProviding)? = nil,
            reranker: (any MemoryReranker)? = nil, configuration: MemorySearch.Configuration = .default,
            signposter: Signposter = .disabled(.memory)
        ) -> MemorySearch {
            MemorySearch(
                index: index, embedder: vectors ? HashingQueryEmbedder(embedder: embedder) : nil, entities: entities,
                reranker: reranker, configuration: configuration,
                timeParser: TemporalQueryParser(timeZone: IndexTestSupport.utc, firstWeekday: 2),
                clock: ManualClock(now: MemorySearchTests.now), signposter: signposter)
        }
    }

    struct HashingQueryEmbedder: MemoryQueryEmbedding {
        let embedder: IndexTestSupport.HashingEmbedder

        func embedQuery(_ text: String) async throws -> TextEmbedding {
            embedder.embed(text)
        }
    }

    struct FailingQueryEmbedder: MemoryQueryEmbedding {
        func embedQuery(_ text: String) async throws -> TextEmbedding {
            throw TextEmbeddingService.Failure.notInstalled
        }
    }

    // MARK: - Fusion

    @Test func fusesKeywordAndVectorRankings() async throws {
        let harness = try Harness()
        let ramen = try await harness.add("Menya Kotori is the best ramen place in Osaka", kind: .conversation)
        try await harness.add("The seed round closed in March with Sequoia leading")

        let response = try await harness.search().search("ramen in Osaka")
        let first = try #require(response.results.first)
        #expect(first.id == ramen.id)
        #expect(first.signals.isSuperset(of: [.keyword, .vector]))
        #expect(first.sourceKind == .conversation)
        #expect(first.sourceID == ramen.sourceID)
        #expect(first.date == ramen.createdAt)
        #expect(first.snippet == ramen.text)
        #expect(first.score > 0)
        #expect(response.usedVectors)
        #expect(response.vectorFailure == nil)
    }

    @Test func runsOnBM25AloneWithoutAModel() async throws {
        let harness = try Harness()
        let ramen = try await harness.add("Menya Kotori is the best ramen place in Osaka")
        for search in [
            harness.search(vectors: false),
            MemorySearch(
                index: harness.index, embedder: FailingQueryEmbedder(), clock: ManualClock(now: Self.now),
                signposter: .disabled(.memory)),
        ] {
            let response = try await search.search("Kotori ramen")
            #expect(response.results.map(\.id) == [ramen.id])
            #expect(response.results.first?.signals == [.keyword])
            #expect(!response.usedVectors)
            #expect(response.vectorFailure != nil)
        }
    }

    @Test func emptyQueriesAndLimits() async throws {
        let harness = try Harness()
        for index in 0..<60 { try await harness.add("ramen note number \(index)") }
        let search = harness.search()
        #expect(try await search.search("   ").results.isEmpty)
        #expect(try await search.search("ramen", limit: 0).results.isEmpty)
        #expect(try await search.search("ramen", kinds: []).results.isEmpty)
        #expect(try await search.search("ramen", limit: 3).results.count == 3)
        #expect(try await search.search("ramen", limit: 1_000).results.count == search.configuration.maximumLimit)
    }

    @Test func kindsFilterEveryRanking() async throws {
        let harness = try Harness()
        try await harness.add("Alex prefers ramen", kind: .document)
        let fact = try await harness.add("Alex prefers ramen over sushi", kind: .fact)
        let response = try await harness.search().search("ramen", kinds: [.fact])
        #expect(response.results.map(\.id) == [fact.id])
    }

    // MARK: - Time

    @Test func explicitBoundsAreAHardFilter() async throws {
        let harness = try Harness()
        try await harness.add("fundraising plan with the seed round", createdAt: IndexTestSupport.t0)
        let recent = try await harness.add("fundraising plan", createdAt: Self.now.addingTimeInterval(-Self.day))
        let search = harness.search()

        let after = Self.now.addingTimeInterval(-3 * Self.day)
        let response = try await search.search("fundraising plan yesterday", after: after)
        #expect(response.results.map(\.id) == [recent.id])
        #expect(response.timeFilter == after..<Date.distantFuture)
        // Explicit bounds replace what the query says.
        #expect(response.timeExpression == nil)

        let before = try await search.search("fundraising plan", before: after)
        #expect(before.results.count == 1 && before.results.first?.id != recent.id)
        #expect(try await search.search("fundraising", after: Self.now, before: Self.now).results.isEmpty)
    }

    @Test func aRelativeTimeRanksItsRangeFirstButKeepsTheRest() async throws {
        let harness = try Harness()
        let old = try await harness.add(
            "We went over the fundraising plan, the seed round and the investor list", createdAt: IndexTestSupport.t0)
        let recent = try await harness.add(
            "Quick fundraising update", createdAt: Self.now.addingTimeInterval(-Self.day))
        let query = "what did I say about the fundraising seed round investor list yesterday"

        var noBoost = MemorySearch.Configuration()
        noBoost.timeWeight = 0
        let plain = try await harness.search(configuration: noBoost).search(query)
        #expect(plain.results.map(\.id) == [old.id, recent.id])

        let response = try await harness.search().search(query)
        #expect(response.timeExpression?.phrase == "yesterday")
        #expect(response.timeExpression?.anchor == .relative)
        #expect(response.timeFilter == nil)
        #expect(response.results.map(\.id) == [recent.id, old.id])
        #expect(response.results.first?.signals.contains(.time) == true)
        #expect(response.results.last?.signals.contains(.time) == false)
    }

    @Test func namedMonthsDontBoostByDefault() async throws {
        let harness = try Harness()
        let march = Date(timeIntervalSince1970: 1_773_489_600)  // 2026-03-14 12:00 UTC
        try await harness.add("fundraising chat", createdAt: march)
        let response = try await harness.search().search("fundraising in March")
        #expect(response.timeExpression?.anchor == .calendar)
        #expect(response.results.allSatisfy { !$0.signals.contains(.time) })

        var configuration = MemorySearch.Configuration()
        configuration.calendarTimeWeight = 1
        let boosted = try await harness.search(configuration: configuration).search("fundraising in March")
        // "now" is January 2026, so "March" is March 2025: outside.
        #expect(boosted.timeExpression?.range.lowerBound ?? .distantFuture < march)
        #expect(boosted.results.allSatisfy { !$0.signals.contains(.time) })

        configuration.parsesTimeExpressions = false
        #expect(
            try await harness.search(configuration: configuration).search("fundraising in March").timeExpression == nil)
    }

    // MARK: - Entity expansion

    struct Partner {
        let alex = UUID()
        let partnerFact = UUID()
        let jobFact = UUID()
        let oldJobFact = UUID()

        var graph: MemoryEntityGraph {
            let t0 = IndexTestSupport.t0
            return MemoryEntityGraph(
                entities: [.init(id: alex, name: "Alex Moreno", aliases: ["Alex"], type: .person)],
                facts: [
                    .init(id: partnerFact, subjectID: nil, validFrom: t0),
                    .init(id: jobFact, subjectID: alex, validFrom: t0.addingTimeInterval(5 * 86_400)),
                    .init(
                        id: oldJobFact, subjectID: alex, validFrom: t0,
                        invalidatedAt: t0.addingTimeInterval(5 * 86_400)),
                ])
        }

        func populate(_ harness: Harness) async throws {
            let t0 = IndexTestSupport.t0
            try await harness.add("User partner is Alex Moreno", kind: .fact, createdAt: t0, sourceID: partnerFact)
            try await harness.add(
                "Alex Moreno designs gardens at a landscape architecture studio in Emeryville", kind: .fact,
                createdAt: t0.addingTimeInterval(5 * 86_400), sourceID: jobFact)
            try await harness.add(
                "Alex Moreno designs parks at Gensler", kind: .fact, createdAt: t0, sourceID: oldJobFact)
            try await harness.add("Booked the flights to Tokyo for April", kind: .conversation, createdAt: t0)
        }

        func chunkID(_ fact: UUID) -> UUID { MemoryChunk.id(kind: .fact, sourceID: fact, ordinal: 0) }
    }

    /// Multi-hop: "partner" finds the fact naming Alex, and expansion adds
    /// what is currently true about Alex, which shares no word with the
    /// query.
    @Test func expandsTopHitsThroughTheirEntities() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let search = harness.search(vectors: false, entities: partner.graph)

        let response = try await search.search("what is my partner's job")
        let ids = response.results.map(\.id)
        #expect(ids.first == partner.chunkID(partner.partnerFact))
        let job = try #require(response.results.first { $0.id == partner.chunkID(partner.jobFact) })
        #expect(job.signals == [.entity])
        #expect(job.linkedEntityID == partner.alex)
        // The invalidated fact isn't current, so it isn't expanded.
        #expect(!ids.contains(partner.chunkID(partner.oldJobFact)))
        #expect(response.expandedFacts == 1)
        #expect(response.queryEntities.isEmpty)
    }

    @Test func expandsEntitiesTheQueryNames() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let response = try await harness.search(vectors: false, entities: partner.graph).search("how is Alex doing")
        #expect(response.queryEntities == [partner.alex])
        #expect(response.results.contains { $0.id == partner.chunkID(partner.jobFact) && $0.signals.contains(.entity) })
    }

    /// Within explicit bounds, the facts valid then are expanded.
    @Test func expandsFactsValidDuringTheTimeFilter() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let t0 = IndexTestSupport.t0
        let response = try await harness.search(vectors: false, entities: partner.graph)
            .search(
                "what was my partner's job", after: t0.addingTimeInterval(-Self.day),
                before: t0.addingTimeInterval(Self.day))
        let ids = response.results.map(\.id)
        #expect(ids.contains(partner.chunkID(partner.oldJobFact)))
        #expect(!ids.contains(partner.chunkID(partner.jobFact)))
    }

    /// Explicit bounds stay a hard filter for expansion: a fact valid
    /// during the window but dated (`validFrom`) before it isn't added.
    @Test func expansionKeepsToTheExplicitWindow() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let t0 = IndexTestSupport.t0
        let dinner = try await harness.add(
            "Alex Moreno called about dinner", kind: .conversation, createdAt: t0.addingTimeInterval(2 * Self.day))
        let window = t0.addingTimeInterval(Self.day)..<t0.addingTimeInterval(3 * Self.day)
        // The old job fact (from t0, invalidated at t0 + 5 days) overlaps the
        // window, but its chunk is dated t0.
        let oldJob = try #require(partner.graph.facts(about: partner.alex).first { $0.id == partner.oldJobFact })
        #expect(oldJob.isValid(during: window))
        #expect(!window.contains(oldJob.validFrom))

        let response = try await harness.search(vectors: false, entities: partner.graph)
            .search("Alex dinner", after: window.lowerBound, before: window.upperBound)
        #expect(response.queryEntities == [partner.alex])
        #expect(response.results.map(\.id) == [dinner.id])
        #expect(response.results.allSatisfy { window.contains($0.date) })
        #expect(response.expandedFacts == 0)

        // A fact dated inside the window is still expanded.
        let later = t0.addingTimeInterval(4 * Self.day)..<t0.addingTimeInterval(6 * Self.day)
        let inside = try await harness.search(vectors: false, entities: partner.graph)
            .search("how is Alex doing", after: later.lowerBound, before: later.upperBound)
        let job = try #require(inside.results.first { $0.id == partner.chunkID(partner.jobFact) })
        #expect(job.signals.contains(.entity))
        #expect(inside.results.allSatisfy { later.contains($0.date) })
    }

    /// The index's date decides, even when the graph disagrees (a fact
    /// edited since it was indexed).
    @Test func expansionChecksTheIndexedDateAgainstTheWindow() async throws {
        let harness = try Harness()
        let t0 = IndexTestSupport.t0
        let alex = UUID()
        let fact = UUID()
        try await harness.add("Alex Moreno designs parks at Gensler", kind: .fact, createdAt: t0, sourceID: fact)
        let window = t0.addingTimeInterval(Self.day)..<t0.addingTimeInterval(3 * Self.day)
        let graph = MemoryEntityGraph(
            entities: [.init(id: alex, name: "Alex Moreno", aliases: ["Alex"], type: .person)],
            facts: [.init(id: fact, subjectID: alex, validFrom: t0.addingTimeInterval(2 * Self.day))])

        let response = try await harness.search(vectors: false, entities: graph)
            .search("how is Alex doing", after: window.lowerBound, before: window.upperBound)
        #expect(response.queryEntities == [alex])
        #expect(response.results.isEmpty)
        #expect(response.expandedFacts == 0)
    }

    @Test func noExpansionWhenFactsAreFilteredOut() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let response = try await harness.search(vectors: false, entities: partner.graph)
            .search("Alex", kinds: [.conversation, .document])
        #expect(response.expandedFacts == 0)
        #expect(response.results.allSatisfy { $0.sourceKind != .fact })
    }

    struct FailingGraph: MemoryEntityGraphProviding {
        func entityGraph() async throws -> MemoryEntityGraph { throw MemoryEntityGraphTests.LoadFailed() }
    }

    @Test func aGraphFailureOnlyTurnsExpansionOff() async throws {
        let harness = try Harness()
        let partner = Partner()
        try await partner.populate(harness)
        let response = try await harness.search(vectors: false, entities: FailingGraph()).search("partner")
        #expect(response.results.first?.id == partner.chunkID(partner.partnerFact))
        #expect(response.expandedFacts == 0)
    }

    // MARK: - Dedupe, rerank, snippets

    @Test func dedupesIdenticalText() async throws {
        let harness = try Harness()
        // The same note created on two devices.
        try await harness.add("Pricing is 149 dollars per location")
        try await harness.add("Pricing is  149 dollars per location ")
        try await harness.add("Pricing for chains is negotiated")
        let response = try await harness.search().search("pricing per location")
        #expect(response.results.count == 2)
        #expect(Set(response.results.map { MemorySearch.dedupeKey($0.chunk.text) }).count == 2)
    }

    final class ReversingReranker: MemoryReranker {
        let calls = Mutex(0)

        func relevance(of candidates: [MemoryChunk], to query: String) async throws -> [Double] {
            calls.withLock { $0 += 1 }
            return candidates.indices.map(Double.init)
        }
    }

    struct FailingReranker: MemoryReranker {
        struct Failed: Error {}
        func relevance(of candidates: [MemoryChunk], to query: String) async throws -> [Double] { throw Failed() }
    }

    @Test func aRerankerReordersTheHead() async throws {
        let harness = try Harness()
        for text in ["ramen ramen ramen Osaka", "ramen Osaka", "ramen"] { try await harness.add(text) }
        let fused = try await harness.search().search("ramen Osaka").results

        let reranker = ReversingReranker()
        let reranked = try await harness.search(reranker: reranker).search("ramen Osaka").results
        #expect(reranked.map(\.id) == fused.map(\.id).reversed())
        #expect(reranked.allSatisfy { $0.signals.contains(.reranked) && $0.rerankScore != nil })
        #expect(reranker.calls.withLock { $0 } == 1)

        let failed = try await harness.search(reranker: FailingReranker()).search("ramen Osaka").results
        #expect(failed.map(\.id) == fused.map(\.id))
        #expect(failed.allSatisfy { $0.rerankScore == nil })
    }

    @Test func snippetsCutAroundTheFirstMatch() async throws {
        let harness = try Harness()
        let filler = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let chunk = try await harness.add("\(filler) the Sequoia term sheet arrived today. \(filler)")
        let result = try #require(try await harness.search().search("Sequoia term sheet").results.first)
        #expect(result.id == chunk.id)
        #expect(result.snippet.count <= 322)
        #expect(result.snippet.hasPrefix("…") && result.snippet.hasSuffix("…"))
        #expect(result.snippet.contains("Sequoia term sheet"))
    }

    @Test func snippetEdgeCases() {
        #expect(MemorySnippet.make("  short\n text ", terms: [], maximumLength: 20) == "short text")
        let text = "Alpha beta gamma delta epsilon zeta eta theta"
        // No match: the start.
        #expect(MemorySnippet.make(text, terms: ["omega"], maximumLength: 16) == "Alpha beta gamma…")
        // A match near the end uses the room before it.
        #expect(MemorySnippet.make(text, terms: ["theta"], maximumLength: 16) == "…zeta eta theta")
        // Stems: "fundraising" finds "fundraise,".
        #expect(
            MemorySnippet.make(text + " we fundraise, then", terms: ["fundraising"], maximumLength: 20).contains(
                "fundraise"))
    }

    // MARK: - Telemetry and adapter

    @Test func eachSearchIsOneSignpostInterval() async throws {
        let harness = try Harness()
        try await harness.add("ramen in Osaka")
        let recording = RecordingSignpostBackend()
        let search = harness.search(signposter: Signposter(category: .memory, backend: recording))
        _ = try await search.search("ramen")
        _ = try await search.search("   ")
        #expect(recording.completedIntervals == ["memory.search", "memory.search"])
        #expect(recording.openIntervals.isEmpty)
    }

    @Test func memoryServiceReturnsSnippets() async throws {
        let harness = try Harness()
        let ramen = try await harness.add("Menya Kotori is the best ramen place in Osaka")
        let hits = try await MemorySearchService(harness.search()).search("ramen", limit: 5)
        #expect(hits.map(\.id) == [ramen.id])
        #expect(hits.first?.text == ramen.text)
    }
}
