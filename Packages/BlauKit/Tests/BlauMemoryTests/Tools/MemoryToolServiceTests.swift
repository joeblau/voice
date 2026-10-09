import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

/// The memory tools' backend (#68) over a real in-memory SwiftData store and
/// an in-memory index built from it.
@Suite("Memory tool service")
struct MemoryToolServiceTests {
    typealias Support = IndexTestSupport

    static let now = Support.t0.addingTimeInterval(30 * 86_400)

    struct QueryEmbedder: MemoryQueryEmbedding {
        let embedder: Support.HashingEmbedder

        func embedQuery(_ text: String) async throws -> TextEmbedding {
            embedder.embed(text)
        }
    }

    /// A populated store, its index and the service over both.
    struct Harness {
        let container: ModelContainer
        let index: MemoryIndex
        let embedder = Support.HashingEmbedder()
        let clock = ManualClock(now: MemoryToolServiceTests.now)
        let ids: Ids

        struct Ids {
            var conversation: UUID
            var company: UUID
            var note: UUID
            var item: UUID
            var lives: UUID
            var alex: UUID
            var alexJob: UUID
            var alexOldJob: UUID
        }

        init(indexed: Bool = true) async throws {
            container = try BlauModelContainer.makeInMemory()
            ids = try await Self.populate(container)
            index = try MemoryIndex.inMemory()
            if indexed {
                try await MemoryIndexRebuilder(
                    index: index, sources: SwiftDataMemorySources(container: container), chunker: Support.chunker,
                    embedder: embedder
                ).rebuild()
            }
        }

        func service(withIndex: Bool = true) -> MemoryToolService {
            MemoryToolService(
                MemoryToolService.Context(container: container, index: withIndex ? index : nil),
                embedder: QueryEmbedder(embedder: embedder), chunkEmbedder: embedder, chunker: Support.chunker,
                clock: clock)
        }

        @MainActor
        static func populate(_ container: ModelContainer) throws -> Ids {
            let context = container.mainContext
            let t0 = Support.t0
            let conversation = Conversation(startedAt: t0, endedAt: t0.addingTimeInterval(600))
            context.insert(conversation)
            let topic = Topic(
                conversation: conversation, startedAt: t0, title: "Fundraising", titleIsProvisional: false)
            context.insert(topic)
            for (index, turn) in [
                (UtteranceRole.user, "We closed the seed round with Sequoia leading."),
                (.agent, "Congratulations! How much did you raise?"),
            ].enumerated() {
                context.insert(
                    StoredUtterance(
                        conversation: conversation, topic: topic, role: turn.0, text: turn.1,
                        startedAt: t0.addingTimeInterval(Double(index) * 20), isFinal: true,
                        source: turn.0 == .user ? .parakeet : .grok))
            }
            let company = MemoryDocument(
                kind: .company, title: "Larderly",
                body: "Inventory and food-cost app for independent restaurants. Pricing is $149 per location.",
                createdAt: t0)
            context.insert(company)
            let note = MemoryDocument(
                kind: .note, title: "Pricing ideas", body: "Try annual pricing with two months free.", createdAt: t0)
            context.insert(note)
            let collection = MemoryDocument(kind: .collection, title: "YC interview", createdAt: t0)
            context.insert(collection)
            let item = CollectionItem(
                document: collection, ordinal: 0, prompt: "What are you building?",
                referenceAnswer: "Inventory software restaurants love.", createdAt: t0)
            context.insert(item)

            let lives = Fact(predicate: "lives in", objectText: "Austin", validFrom: t0, origin: .user)
            context.insert(lives)
            let alex = MemoryEntity(name: "Alex Moreno", type: .person, aliases: ["Alex"], createdAt: t0)
            context.insert(alex)
            let oldJob = Fact(
                subject: alex, predicate: "worked at", objectText: "Stripe", validFrom: t0.addingTimeInterval(-86_400),
                invalidatedAt: t0, origin: .extracted)
            context.insert(oldJob)
            let job = Fact(
                subject: alex, predicate: "designs gardens at", objectText: "Field Office", validFrom: t0,
                origin: .extracted)
            context.insert(job)
            try context.save()
            return Ids(
                conversation: conversation.id, company: company.id, note: note.id, item: item.id, lives: lives.id,
                alex: alex.id, alexJob: job.id, alexOldJob: oldJob.id)
        }
    }

    // MARK: - Search

    @Test func hitsCarryTheirSourceAndDate() async throws {
        let harness = try await Harness()
        let service = harness.service()

        let fundraising = try await service.search(MemoryToolQuery(text: "seed round Sequoia"))
        let exchange = try #require(fundraising.hits.first { $0.kind == .conversation })
        #expect(exchange.id == harness.ids.conversation)
        #expect(exchange.source == "Conversation · Fundraising")
        #expect(exchange.date == Support.t0)
        #expect(fundraising.usedVectors)

        let company = try await service.search(MemoryToolQuery(text: "restaurants inventory"))
        let document = try #require(company.hits.first { $0.kind == .company })
        #expect(document.id == harness.ids.company)
        #expect(document.source == "Company · Larderly")
        #expect(document.text.contains("independent restaurants"))
        let item = try #require(company.hits.first { $0.kind == .collection })
        #expect(item.id == harness.ids.item)
        #expect(item.source == "Collection · YC interview")

        let lives = try await service.search(MemoryToolQuery(text: "lives in Austin", kinds: [.fact]))
        let fact = try #require(lives.hits.first)
        #expect(fact.id == harness.ids.lives)
        #expect(fact.kind == .fact)
        #expect(fact.text == "User lives in Austin")
        #expect(fact.source == "Fact · told by the user")
        #expect(fact.isUserStated)
        #expect(fact.validUntil == nil)
        #expect(lives.hits.allSatisfy { $0.kind == .fact })
    }

    @Test func narrowsKnowledgeBaseDocumentsByKind() async throws {
        let harness = try await Harness()
        let service = harness.service()
        let all = try await service.search(MemoryToolQuery(text: "pricing", kinds: [.company, .note]))
        #expect(Set(all.hits.map(\.id)) == [harness.ids.company, harness.ids.note])

        let notes = try await service.search(MemoryToolQuery(text: "pricing", kinds: [.note]))
        #expect(notes.hits.map(\.id) == [harness.ids.note])
        #expect(notes.hits.first?.source == "Note · Pricing ideas")

        let none = try await service.search(MemoryToolQuery(text: "pricing", kinds: []))
        #expect(none.hits.isEmpty)
    }

    /// The acceptance criterion's question: the company document answers it
    /// even when the question shares no word with it (no embedding model on
    /// a fresh install) and even before the index exists.
    @Test(arguments: [true, false])
    func whatDoesMyCompanyDoIsAnsweredFromTheKnowledgeBase(withIndex: Bool) async throws {
        let harness = try await Harness(indexed: withIndex)
        let result = try await harness.service(withIndex: withIndex).search(
            MemoryToolQuery(text: "what does my company do", kinds: [.company]))
        let hit = try #require(result.hits.first)
        #expect(result.hits.count == 1)
        #expect(hit.id == harness.ids.company)
        #expect(hit.kind == .company)
        #expect(hit.source == "Company · Larderly")
        #expect(hit.text.hasPrefix("Inventory and food-cost app for independent restaurants."))
    }

    @Test func withoutAnIndexOnlyTheKnowledgeBaseCanBeRead() async throws {
        let harness = try await Harness(indexed: false)
        await #expect(throws: MemoryToolFailure.self) {
            try await harness.service(withIndex: false).search(MemoryToolQuery(text: "seed round"))
        }
        await #expect(throws: MemoryToolFailure.rejected("The query is empty.")) {
            try await harness.service().search(MemoryToolQuery(text: "  "))
        }
        let closed = MemoryToolService(context: { nil }, embedder: nil)
        await #expect(throws: MemoryToolFailure.self) {
            try await closed.search(MemoryToolQuery(text: "seed round"))
        }
    }

    // MARK: - Remember and forget

    @Test func rememberStoresAUserFactThatIsSearchableAtOnce() async throws {
        let harness = try await Harness()
        let service = harness.service()
        let fact = try await service.remember("  The user's sister Maya lives in Lisbon. ", about: nil)
        #expect(fact.statement == "The user's sister Maya lives in Lisbon.")
        #expect(fact.isUserStated)
        #expect(fact.subject == nil)
        #expect(fact.validFrom == Self.now)

        // In the store, as a sentence fact the user told.
        let factID = fact.id
        let stored = try ModelContext(harness.container).fetch(
            FetchDescriptor<Fact>(predicate: #Predicate { $0.id == factID }))
        #expect(stored.count == 1)
        #expect(stored.first?.origin == .user)
        #expect(stored.first?.predicate == "")

        // In the index without waiting for the indexer.
        let result = try await service.search(MemoryToolQuery(text: "Maya Lisbon", kinds: [.fact]))
        #expect(result.hits.first?.id == fact.id)

        // Saying it again keeps one fact.
        let again = try await service.remember("the user's sister Maya   lives in Lisbon.", about: "me")
        #expect(again.id == fact.id)
        await #expect(throws: MemoryToolFailure.self) { try await service.remember("  ", about: nil) }
    }

    @Test func aRememberedFactIsChunkedInTheIndexersPinnedTimeZone() async throws {
        let harness = try await Harness()
        let indexer = MemoryIndexer(
            index: harness.index, reader: SwiftDataMemorySources(container: harness.container),
            feed: IndexerTestSupport.ScriptedFeed(), embedder: harness.embedder, chunker: Support.chunker,
            clock: ManualClock(now: Self.now))
        try await indexer.runUntilIdle()  // pins UTC

        // The service's own chunker is in Tokyo, where 23:30 UTC is the next day.
        let tokyo = MemoryChunker(
            policy: ChunkingPolicy.forSequenceLength(128, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        let lateEvening = Date(timeIntervalSince1970: 1_768_519_800)  // 2026-01-15 23:30 UTC
        let service = MemoryToolService(
            MemoryToolService.Context(container: harness.container, index: harness.index, indexer: indexer),
            embedder: QueryEmbedder(embedder: harness.embedder), chunkEmbedder: harness.embedder, chunker: tokyo,
            clock: ManualClock(now: lateEvening))
        let fact = try await service.remember("The user's sister Maya lives in Lisbon.", about: nil)

        let chunk = try await harness.index.chunks(ofSource: fact.id, kind: .fact).first?.chunk
        #expect(chunk?.keyText == "[January 15, 2026] The user's sister Maya lives in Lisbon.")
    }

    @Test func rememberLinksTheEntityItIsAbout() async throws {
        let harness = try await Harness()
        let service = harness.service()
        let birthday = try await service.remember("Alex's birthday is May 3", about: "alex")
        #expect(birthday.subject == "Alex Moreno")
        let priya = try await service.remember("Priya runs the Lisbon office", about: "Priya")
        #expect(priya.subject == "Priya")

        let entities = try await service.entities(named: "Priya", limit: 3)
        #expect(entities.first?.name == "Priya")
        #expect(entities.first?.type == MemoryEntityType.other.rawValue)
        #expect(entities.first?.facts.map(\.id) == [priya.id])
        let alex = try #require(try await service.entities(named: "Alex", limit: 3).first)
        #expect(alex.facts.contains { $0.id == birthday.id })
    }

    @Test func forgetInvalidatesTheFactAndHidesItFromOrdinarySearches() async throws {
        let harness = try await Harness()
        let service = harness.service()
        let fact = try await service.remember("The user is allergic to peanuts", about: nil)
        harness.clock.advance(by: .seconds(3_600))

        let forgotten = try #require(try await service.forget(fact.id))
        #expect(forgotten.invalidatedAt == Self.now.addingTimeInterval(3_600))
        #expect(try await service.fact(fact.id)?.isCurrent == false)

        // Gone from ordinary recall…
        let ordinary = try await service.search(MemoryToolQuery(text: "allergic peanuts"))
        #expect(!ordinary.hits.contains { $0.id == fact.id })
        // …but still history when asked about a time it held.
        let past = try await service.search(
            MemoryToolQuery(text: "allergic peanuts", after: Self.now.addingTimeInterval(-60), kinds: [.fact]))
        let hit = try #require(past.hits.first { $0.id == fact.id })
        #expect(hit.validUntil == Self.now.addingTimeInterval(3_600))

        // Forgetting again keeps the first date.
        harness.clock.advance(by: .seconds(60))
        #expect(try await service.forget(fact.id)?.invalidatedAt == Self.now.addingTimeInterval(3_600))
        #expect(try await service.forget(UUID()) == nil)
        #expect(try await service.fact(UUID()) == nil)
    }

    // MARK: - Entities

    @Test func entitiesMatchByNameOrAliasWithAFactTimeline() async throws {
        let harness = try await Harness()
        let service = harness.service()
        for name in ["Alex", "alex moreno", "Álex", "my friend Alex Moreno"] {
            let entity = try #require(try await service.entities(named: name, limit: 3).first, "\(name)")
            #expect(entity.id == harness.ids.alex)
            #expect(entity.name == "Alex Moreno")
            #expect(entity.type == "person")
            #expect(entity.aliases == ["Alex"])
            // Oldest first, including the job that ended.
            #expect(entity.facts.map(\.id) == [harness.ids.alexOldJob, harness.ids.alexJob])
            #expect(entity.facts.first?.invalidatedAt == Support.t0)
            #expect(entity.facts.last?.statement == "Alex Moreno designs gardens at Field Office")
        }
        #expect(try await service.entities(named: "Sequoia Capital", limit: 3).isEmpty)
        await #expect(throws: MemoryToolFailure.self) { try await service.entities(named: " ", limit: 3) }
    }

    @Test func matchScoresPreferTheWholeName() {
        let alexMoreno = KeywordQuery.words(in: "Alex Moreno")
        #expect(MemoryToolService.matchScore(name: "Alex Moreno", query: alexMoreno) == 3)
        #expect(MemoryToolService.matchScore(name: "Alex Moreno", query: ["alex"]) == 2)
        #expect(MemoryToolService.matchScore(name: "Alex", query: ["my", "friend", "alex"]) == 1)
        #expect(MemoryToolService.matchScore(name: "Alex", query: ["sequoia"]) == 0)
        // A common word as a name is never found inside a longer query.
        #expect(MemoryToolService.matchScore(name: "It", query: ["is", "it", "here"]) == 0)
    }

    // MARK: - MemoryService

    @Test func servesBlauCoresMemoryService() async throws {
        let harness = try await Harness()
        let hits = try await harness.service().search("seed round Sequoia", limit: 3)
        #expect(!hits.isEmpty)
        #expect(hits.count <= 3)
        #expect(hits.first?.id == harness.ids.conversation)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score > $1.score })
    }
}
