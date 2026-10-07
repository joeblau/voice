import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

@Suite("Fact extraction: the SwiftData fact store")
struct SwiftDataMemoryFactStoreTests {
    typealias Support = ExtractionTestSupport

    private func newFact(
        _ predicate: String, _ object: String, subject: UUID? = nil, at offset: TimeInterval = 0,
        source: UUID? = nil
    ) -> MemoryWritePlan.NewFact {
        MemoryWritePlan.NewFact(
            id: UUID(), subjectID: subject, predicate: predicate, objectText: object, confidence: 0.9,
            sourceUtteranceID: source, validFrom: Support.t0.addingTimeInterval(offset), invalidatedAt: nil)
    }

    @Test func appliesEntitiesFactsAndInvalidationsInOneSave() async throws {
        let fixture = try TopicFixture()
        let acmeID = UUID()
        let source = UUID()
        var first = MemoryWritePlan(recordedAt: Support.t0)
        first.newEntities = [.init(id: acmeID, name: "Acme", type: .organization, aliases: ["Acme Corp"], summary: nil)]
        let stripe = newFact("works at", "Stripe")
        first.newFacts = [stripe, newFact("makes", "anvils", subject: acmeID, source: source)]
        let written = try await fixture.facts.apply(first)
        #expect(written.createdEntityIDs == [acmeID])
        #expect(written.insertedFactIDs.count == 2)

        var second = MemoryWritePlan(recordedAt: Support.t0.addingTimeInterval(100))
        second.invalidations = [.init(factID: stripe.id, date: Support.t0.addingTimeInterval(50))]
        second.newFacts = [newFact("works at", "Acme", at: 50)]
        second.entityUpdates = [.init(id: acmeID, addedAliases: ["ACME", "Acme Inc"], summary: "Makes anvils")]
        let result = try await fixture.facts.apply(second)
        #expect(result.invalidatedFactIDs == [stripe.id])

        let facts = try fixture.storedFacts()
        let old = try #require(facts.first { $0.objectText == "Stripe" })
        let new = try #require(facts.first { $0.objectText == "Acme" })
        #expect(old.invalidatedAt == Support.t0.addingTimeInterval(50))
        #expect(!old.isCurrent)
        #expect(new.isCurrent)
        #expect(new.origin == .extracted)
        #expect(new.createdAt == Support.t0.addingTimeInterval(100))
        let anvils = try #require(facts.first { $0.objectText == "anvils" })
        #expect(anvils.subject?.id == acmeID)
        #expect(anvils.sourceUtteranceID == source)

        let acme = try #require(try fixture.storedEntities().first)
        #expect(acme.aliasNames == ["Acme Corp", "Acme Inc"])
        #expect(acme.summary == "Makes anvils")
        #expect(acme.updatedAt == Support.t0.addingTimeInterval(100))

        let known = try await fixture.facts.currentFacts(about: [acmeID], includingUser: true, limit: 10)
        #expect(Set(known.map(\.objectText)) == ["Acme", "anvils"])
        let userOnly = try await fixture.facts.currentFacts(about: [], includingUser: true, limit: 10)
        #expect(userOnly.map(\.objectText) == ["Acme"])
    }

    @Test func invalidatingTwiceKeepsTheEarlierDateAndReportsOnce() async throws {
        let fixture = try TopicFixture()
        let fact = newFact("lives in", "Paris")
        var plan = MemoryWritePlan(recordedAt: Support.t0)
        plan.newFacts = [fact]
        _ = try await fixture.facts.apply(plan)

        var late = MemoryWritePlan(recordedAt: Support.t0)
        late.invalidations = [.init(factID: fact.id, date: Support.t0.addingTimeInterval(200))]
        #expect(try await fixture.facts.apply(late).invalidatedFactIDs == [fact.id])
        var early = MemoryWritePlan(recordedAt: Support.t0)
        early.invalidations = [.init(factID: fact.id, date: Support.t0.addingTimeInterval(100))]
        #expect(try await fixture.facts.apply(early).invalidatedFactIDs.isEmpty)
        #expect(try fixture.storedFacts().first?.invalidatedAt == Support.t0.addingTimeInterval(100))
    }

    @Test func skipsAFactThatIsAlreadyCurrent() async throws {
        let fixture = try TopicFixture()
        var plan = MemoryWritePlan(recordedAt: Support.t0)
        plan.newFacts = [newFact("likes", "espresso")]
        _ = try await fixture.facts.apply(plan)
        var again = MemoryWritePlan(recordedAt: Support.t0)
        again.newFacts = [newFact("Likes", "Espresso."), newFact("likes", "tea")]
        let result = try await fixture.facts.apply(again)
        #expect(result.skippedDuplicateCount == 1)
        #expect(try fixture.storedFacts().map(\.objectText).sorted() == ["espresso", "tea"])
    }

    @Test func mergingDuplicateEntitiesMovesTheirFactsAndNames() async throws {
        let fixture = try TopicFixture()
        let context = ModelContext(fixture.container)
        let canonical = MemoryEntity(name: "Acme", type: .organization, createdAt: Support.t0)
        let duplicate = MemoryEntity(
            name: "ACME", type: .organization, aliases: ["Acme Robotics"], summary: "Robots",
            createdAt: Support.t0.addingTimeInterval(10))
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(
            Fact(subject: duplicate, predicate: "raised", objectText: "a seed", validFrom: Support.t0, origin: .user))
        try context.save()

        var plan = MemoryWritePlan(recordedAt: Support.t0.addingTimeInterval(500))
        plan.merges = [.init(canonicalID: canonical.id, duplicateIDs: [duplicate.id])]
        plan.newFacts = [newFact("makes", "anvils", subject: duplicate.id)]
        let result = try await fixture.facts.apply(plan)
        #expect(result.mergedEntityCount == 1)

        let entities = try fixture.storedEntities()
        #expect(entities.map(\.id) == [canonical.id])
        #expect(entities[0].aliasNames == ["Acme Robotics"])
        #expect(entities[0].summary == "Robots")
        let facts = try fixture.storedFacts()
        #expect(facts.count == 2)
        #expect(facts.allSatisfy { $0.subject?.id == canonical.id })
    }

    @Test func readsMergeCloudKitCopiesOfOneEntity() async throws {
        let fixture = try TopicFixture()
        let context = ModelContext(fixture.container)
        let id = UUID()
        context.insert(MemoryEntity(id: id, name: "Acme", type: .organization, aliases: ["A1"], createdAt: Support.t0))
        context.insert(
            MemoryEntity(
                id: id, name: "Acme", type: .organization, aliases: ["A2"], summary: "S", createdAt: Support.t0))
        try context.save()
        let entities = try await fixture.facts.entities()
        #expect(entities.count == 1)
        #expect(Set(entities[0].aliases) == ["A1", "A2"])
        #expect(entities[0].summary == "S")
    }

    @Test func deletingAFactRemovesEveryCopy() async throws {
        let fixture = try TopicFixture()
        let context = ModelContext(fixture.container)
        let id = UUID()
        for _ in 0..<2 {
            context.insert(
                Fact(id: id, predicate: "likes", objectText: "tea", validFrom: Support.t0, origin: .extracted))
        }
        context.insert(Fact(predicate: "likes", objectText: "coffee", validFrom: Support.t0, origin: .extracted))
        try context.save()
        try await fixture.facts.deleteFact(id)
        #expect(try fixture.storedFacts().map(\.objectText) == ["coffee"])
        // Deleting an unknown fact is a no-op.
        try await fixture.facts.deleteFact(UUID())
    }

    @Test func aFactWhoseSubjectWasDeletedIsNotWritten() async throws {
        let fixture = try TopicFixture()
        var plan = MemoryWritePlan(recordedAt: Support.t0)
        plan.newFacts = [newFact("makes", "anvils", subject: UUID())]
        let result = try await fixture.facts.apply(plan)
        #expect(result.insertedFactIDs.isEmpty)
        #expect(try fixture.storedFacts().isEmpty)
    }
}
