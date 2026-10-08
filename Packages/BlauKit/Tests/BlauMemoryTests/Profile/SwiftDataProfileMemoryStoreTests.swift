import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: the SwiftData store")
struct SwiftDataProfileMemoryStoreTests {
    typealias Support = ExtractionTestSupport

    @Test func readsTheLatestBlockAndCountsCopies() async throws {
        let fixture = try ProfileFixture()
        #expect(try await fixture.store.profileBlock(key: ProfileBlock.userKey) == nil)
        try fixture.addBlock("Old.", at: Support.t0)
        try fixture.addBlock("New.", at: Support.t0.addingTimeInterval(60))
        let block = try #require(try await fixture.store.profileBlock(key: ProfileBlock.userKey))
        #expect(block.text == "New.")
        #expect(block.copyCount == 2)
        #expect(try await fixture.store.profileBlock(key: "company") == nil)
    }

    @Test func writesCreateUpdateAndRefuseStaleExpectations() async throws {
        let fixture = try ProfileFixture()
        let store = fixture.store
        #expect(
            try await store.writeProfileBlock(key: "user", text: "", expectedText: nil, at: Support.t0) == .unchanged)
        #expect(try fixture.blocks().isEmpty)
        #expect(
            try await store.writeProfileBlock(key: "user", text: "A.", expectedText: nil, at: Support.t0) == .written)
        #expect(
            try await store.writeProfileBlock(key: "user", text: "B.", expectedText: nil, at: Support.t0) == .conflict)
        #expect(
            try await store.writeProfileBlock(key: "user", text: "B.", expectedText: "A.", at: Support.t0) == .written)
        #expect(
            try await store.writeProfileBlock(key: "user", text: "B.", expectedText: "B.", at: Support.t0) == .unchanged
        )
        #expect(try fixture.blocks().map(\.text) == ["B."])
    }

    @Test func mergesCopiesOfFactsAndRanksThem() async throws {
        let fixture = try ProfileFixture()
        let id = UUID()
        let context = ModelContext(fixture.container)
        for _ in 0..<2 {
            context.insert(
                Fact(
                    id: id, predicate: "likes", objectText: "jazz", validFrom: Support.t0, confidence: 0.6,
                    origin: .extracted))
        }
        // A fact forgotten on one device: one copy invalidated, the other
        // not yet. The earliest invalidation wins, so it isn't current.
        let forgotten = UUID()
        for invalidatedAt in [nil, Support.t0.addingTimeInterval(60)] {
            context.insert(
                Fact(
                    id: forgotten, predicate: "likes", objectText: "blues", validFrom: Support.t0,
                    invalidatedAt: invalidatedAt, confidence: 0.9, origin: .extracted))
        }
        try context.save()
        try fixture.addFacts([("Acme", "raised", "a seed round")])
        try fixture.addFacts([(nil, "works at", "Acme")], origin: .user)

        let facts = try await fixture.store.currentFacts(limit: 10)
        #expect(facts.map(\.objectText) == ["Acme", "jazz", "a seed round"])
        #expect(try await fixture.store.currentFacts(limit: 1).count == 1)
        #expect(try await fixture.store.currentFacts(limit: 0).isEmpty)
        // Nor is it pinned into the session's instructions.
        let pinned = await PinnedMemoryProvider(store: fixture.store).pinnedMemory()
        #expect(!pinned.facts.map(\.text).joined().contains("blues"))
        #expect(pinned.facts.map(\.text).joined().contains("jazz"))
    }

    @Test func aFactWithAnInvalidatedCopyIsNotMemory() async throws {
        let fixture = try ProfileFixture()
        let id = UUID()
        let context = ModelContext(fixture.container)
        for invalidatedAt in [Support.t0.addingTimeInterval(60), nil] {
            context.insert(
                Fact(
                    id: id, predicate: "likes", objectText: "jazz", validFrom: Support.t0, invalidatedAt: invalidatedAt,
                    origin: .extracted))
        }
        try context.save()
        #expect(try await fixture.store.currentFacts(limit: 10).isEmpty)
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0) == false)
        try fixture.addFacts([(nil, "works at", "Acme")])
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0))
    }

    @Test func countsFactChangesSinceADate() async throws {
        let fixture = try ProfileFixture()
        let since = Support.t0.addingTimeInterval(3_600)
        try fixture.addFacts([(nil, "likes", "old")], createdAt: Support.t0)
        try fixture.addFacts([(nil, "likes", "new")], createdAt: since.addingTimeInterval(60))
        try fixture.addFacts(
            [(nil, "worked at", "Stripe")], createdAt: Support.t0, invalidatedAt: since.addingTimeInterval(60))
        try fixture.addFacts(
            [(nil, "lived in", "Austin")], createdAt: since.addingTimeInterval(1),
            invalidatedAt: since.addingTimeInterval(2))
        #expect(try await fixture.store.factChangeCount(since: since) == 3)
        #expect(try await fixture.store.factChangeCount(since: since.addingTimeInterval(3_600)) == 0)
    }

    @Test func listsRecentClosedTopicsNewestFirst() async throws {
        let fixture = try ProfileFixture()
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0) == false)
        let older = try await fixture.topics.recordTopic([(.user, "One.", 1)], startingAt: 0)
        let newer = try await fixture.topics.recordTopic([(.user, "Two.", 1)], startingAt: 86_400)
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0))
        // Only topics consolidation would read count.
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0.addingTimeInterval(86_400)))
        #expect(try await fixture.store.hasMemory(topicsSince: Support.t0.addingTimeInterval(2 * 86_400)) == false)

        let topics = try await fixture.store.recentTopics(since: Support.t0, limit: 10)
        #expect(topics.map(\.id) == [newer.topicID, older.topicID])
        #expect(topics.allSatisfy { $0.acceptsSummary })
        #expect(
            try await fixture.store.recentTopics(since: Support.t0.addingTimeInterval(3_600), limit: 10).map(\.id) == [
                newer.topicID
            ])
        #expect(try await fixture.store.recentTopics(since: Support.t0, limit: 1).count == 1)
    }

    @Test func readsTheUsersProfilePagesOnly() async throws {
        let fixture = try ProfileFixture()
        try fixture.addProfileDocument(title: "About me", body: "I'm Joe.")
        let context = ModelContext(fixture.container)
        context.insert(MemoryDocument(kind: .company, title: "Acme", body: "Robots.", createdAt: Support.t0))
        try context.save()
        let pages = try await fixture.store.userProfileDocuments()
        #expect(pages.map(\.body) == ["I'm Joe."])
    }

    @Test func copiesOfAPageResolveToTheNewest() {
        let id = UUID()
        let other = UUID()
        let start = Support.t0
        let merged = UserProfileDocument.merged([
            UserProfileDocument(id: id, title: "Me", body: "Old.", updatedAt: start),
            UserProfileDocument(id: other, title: "Work", body: "Acme.", updatedAt: start),
            UserProfileDocument(id: id, title: "Me", body: "New.", updatedAt: start.addingTimeInterval(60)),
        ])
        #expect(merged.map(\.body) == ["New.", "Acme."])
    }
}
