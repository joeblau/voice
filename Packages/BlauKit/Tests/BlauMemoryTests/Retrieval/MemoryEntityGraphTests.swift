import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Memory entity graph")
struct MemoryEntityGraphTests {
    static let t0 = IndexTestSupport.t0
    static let alex = UUID()
    static let paulGraham = UUID()
    static let paul = UUID()
    static let larderly = UUID()

    static var graph: MemoryEntityGraph {
        MemoryEntityGraph(
            entities: [
                .init(id: alex, name: "Alex Moreno", aliases: ["Alex"], type: .person),
                .init(id: paulGraham, name: "Paul Graham", aliases: ["PG"], type: .person),
                .init(id: paul, name: "Paul", type: .person),
                .init(id: larderly, name: "Lärderly", type: .organization),
                // Names that would link everything are never looked for.
                .init(id: UUID(), name: "It", type: .other),
                .init(id: UUID(), name: "a", type: .other),
            ],
            facts: [
                .init(id: UUID(), subjectID: alex, validFrom: t0),
                .init(id: UUID(), subjectID: nil, validFrom: t0),
                .init(id: UUID(), subjectID: UUID(), validFrom: t0),
            ])
    }

    @Test func findsNamesAndAliasesAsWholeWords() {
        let graph = Self.graph
        #expect(graph.entities(mentionedIn: "Where does Alex's firm sit?") == [Self.alex])
        #expect(graph.entities(mentionedIn: "alex moreno and PG talked") == [Self.alex, Self.paulGraham])
        #expect(graph.entities(mentionedIn: "ALEXANDRA called") == [])
        // Diacritics and case are ignored either way.
        #expect(graph.entities(mentionedIn: "the larderly pricing page") == [Self.larderly])
        #expect(graph.entities(mentionedIn: "Is it ready? A plan.") == [])
    }

    @Test func theLongestNameWins() {
        let graph = Self.graph
        #expect(graph.entities(mentionedIn: "Paul Graham said") == [Self.paulGraham])
        #expect(graph.entities(mentionedIn: "Paul said, then Paul Graham") == [Self.paul, Self.paulGraham])
    }

    @Test func linksFactsToTheirSubject() throws {
        let old = UUID()
        let new = UUID()
        let graph = MemoryEntityGraph(
            entities: [.init(id: Self.alex, name: "Alex")],
            facts: [
                .init(
                    id: old, subjectID: Self.alex, validFrom: Self.t0, invalidatedAt: Self.t0.addingTimeInterval(100)),
                .init(id: new, subjectID: Self.alex, validFrom: Self.t0.addingTimeInterval(100)),
            ])
        #expect(graph.facts(about: Self.alex).map(\.id) == [new, old])
        #expect(graph.subject(ofFact: old) == Self.alex)
        #expect(graph.subject(ofFact: UUID()) == nil)
        let oldFact = try #require(graph.facts(about: Self.alex).last)
        #expect(oldFact.isValid(at: Self.t0))
        #expect(!oldFact.isValid(at: Self.t0.addingTimeInterval(100)))
        #expect(oldFact.isValid(during: Self.t0.addingTimeInterval(50)..<Self.t0.addingTimeInterval(500)))
        #expect(!oldFact.isValid(during: Self.t0.addingTimeInterval(100)..<Self.t0.addingTimeInterval(500)))
        #expect(oldFact.chunkID == MemoryChunk.id(kind: .fact, sourceID: old, ordinal: 0))
    }

    @Test func duplicateEntitiesMerge() {
        let graph = MemoryEntityGraph(
            entities: [.init(id: Self.alex, name: "Alex"), .init(id: Self.alex, name: "Alex", aliases: ["Al M"])],
            facts: [])
        #expect(graph.entities.count == 1)
        #expect(graph.entities(mentionedIn: "Al M") == [Self.alex])
    }

    // MARK: - Cache

    final class CountingLoader: Sendable {
        let loads = Mutex(0)
        let failure = Mutex<(any Error)?>(nil)

        func load() async throws -> MemoryEntityGraph {
            if let error = failure.withLock({ $0 }) { throw error }
            let count = loads.withLock { value in
                value += 1
                return value
            }
            return MemoryEntityGraph(entities: [.init(id: UUID(), name: "Entity \(count)")], facts: [])
        }
    }

    struct LoadFailed: Error {}

    @Test func cacheReloadsAfterInvalidationOrMaximumAge() async throws {
        let loader = CountingLoader()
        let clock = ManualClock()
        let cache = CachedMemoryEntityGraph(maximumAge: .seconds(60), clock: clock) { try await loader.load() }

        _ = try await cache.entityGraph()
        _ = try await cache.entityGraph()
        #expect(loader.loads.withLock { $0 } == 1)

        cache.invalidate()
        _ = try await cache.entityGraph()
        #expect(loader.loads.withLock { $0 } == 2)

        clock.advance(by: .seconds(61))
        _ = try await cache.entityGraph()
        #expect(loader.loads.withLock { $0 } == 3)
    }

    @Test func aFailedLoadIsNotCached() async throws {
        let loader = CountingLoader()
        loader.failure.withLock { $0 = LoadFailed() }
        let cache = CachedMemoryEntityGraph(clock: ManualClock()) { try await loader.load() }
        await #expect(throws: LoadFailed.self) { try await cache.entityGraph() }
        loader.failure.withLock { $0 = nil }
        #expect(try await !cache.entityGraph().isEmpty)
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let loader = CountingLoader()
        let cache = CachedMemoryEntityGraph(clock: ManualClock()) { try await loader.load() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await cache.entityGraph() } }
            try await group.waitForAll()
        }
        #expect(loader.loads.withLock { $0 } == 1)
    }

    // MARK: - SwiftData

    @MainActor
    @Test func readsTheSyncedStore() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = container.mainContext
        let alex = MemoryEntity(name: "Alex Moreno", type: .person, aliases: ["Alex"], createdAt: Self.t0)
        context.insert(alex)
        let job = Fact(
            subject: alex, predicate: "works at", objectText: "Field Office", validFrom: Self.t0, origin: .extracted)
        context.insert(job)
        let user = Fact(predicate: "lives in", objectText: "Oakland", validFrom: Self.t0, origin: .user)
        context.insert(user)
        // The same fact synced from another device, invalidated there.
        let duplicate = Fact(
            id: job.id, subject: alex, predicate: "works at", objectText: "Field Office", validFrom: Self.t0,
            invalidatedAt: Self.t0.addingTimeInterval(3_600), origin: .extracted)
        context.insert(duplicate)
        try context.save()

        let graph = try await SwiftDataMemorySources(container: container).entityGraph()
        #expect(graph.entities[alex.id]?.aliases == ["Alex"])
        #expect(graph.entities(mentionedIn: "what does Alex do") == [alex.id])
        let facts = graph.facts(about: alex.id)
        #expect(facts.map(\.id) == [job.id])
        #expect(facts.first?.invalidatedAt == Self.t0.addingTimeInterval(3_600))
        #expect(graph.subject(ofFact: user.id) == nil)
    }
}
