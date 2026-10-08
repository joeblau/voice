import BlauCore
import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

@Suite("Knowledge base store")
struct KnowledgeBaseStoreTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Fixture {
        let container: ModelContainer
        let clock = ManualClock(now: KnowledgeBaseStoreTests.t0)
        let store: KnowledgeBaseStore

        init() throws {
            container = try BlauModelContainer.makeInMemory()
            store = KnowledgeBaseStore(modelContainer: container, clock: clock)
        }

        /// A fresh context, so reads see only what the store saved.
        func documents() throws -> [MemoryDocument] {
            try ModelContext(container).fetch(FetchDescriptor<MemoryDocument>(sortBy: [SortDescriptor(\.createdAt)]))
        }

        func items(of collectionID: UUID) throws -> [CollectionItem] {
            let documents = try ModelContext(container).fetch(
                FetchDescriptor<MemoryDocument>(predicate: #Predicate { $0.id == collectionID }))
            return documents.flatMap(\.orderedCollectionItems)
        }
    }

    // MARK: Documents

    @Test func savingCreatesThenUpdatesADocument() async throws {
        let fixture = try Fixture()
        let id = UUID()
        let created = try await fixture.store.saveDocument(id, kind: .note, title: "Pricing\n", body: "Two tiers.")
        #expect(created == KnowledgeDocumentSave(id: id, changed: true))

        fixture.clock.advance(by: .seconds(60))
        let updated = try await fixture.store.saveDocument(id, kind: .note, title: "Pricing", body: "Three tiers.")
        #expect(updated.changed)

        let document = try #require(try fixture.documents().first)
        #expect(document.id == id)
        #expect(document.kind == .note)
        #expect(document.title == "Pricing")
        #expect(document.body == "Three tiers.")
        #expect(document.createdAt == Self.t0)
        #expect(document.updatedAt == Self.t0.addingTimeInterval(60))
        #expect(document.isContentHashCurrent)
    }

    @Test func savingTheSameTextWritesNothing() async throws {
        let fixture = try Fixture()
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .note, title: "Pricing", body: "Two tiers.")
        fixture.clock.advance(by: .seconds(60))
        let again = try await fixture.store.saveDocument(id, kind: .note, title: "Pricing", body: "Two tiers.")
        #expect(!again.changed)
        #expect(try fixture.documents().first?.updatedAt == Self.t0)
    }

    @Test func anEditorLeftBlankCreatesNothing() async throws {
        let fixture = try Fixture()
        let result = try await fixture.store.saveDocument(UUID(), kind: .note, title: "  ", body: "\n")
        #expect(!result.changed)
        #expect(try fixture.documents().isEmpty)
    }

    @Test func theProfileAndCompanyAreOnePageEach() async throws {
        let fixture = try Fixture()
        let first = UUID()
        _ = try await fixture.store.saveDocument(first, kind: .company, title: "Larderly", body: "## Product\nApp")
        // A second editor that didn't see the first page yet.
        let second = try await fixture.store.saveDocument(UUID(), kind: .company, title: "Larderly", body: "Changed")
        #expect(second.id == first)
        #expect(second.changed)
        // Notes are not singletons.
        _ = try await fixture.store.saveDocument(UUID(), kind: .note, title: "A", body: "")
        _ = try await fixture.store.saveDocument(UUID(), kind: .note, title: "B", body: "")
        let documents = try fixture.documents()
        #expect(documents.filter { $0.kind == .company }.map(\.body) == ["Changed"])
        #expect(documents.filter { $0.kind == .note }.count == 2)
    }

    @Test func everyCloudKitCopyOfADocumentIsUpdatedAndDeleted() async throws {
        let fixture = try Fixture()
        let id = UUID()
        let context = ModelContext(fixture.container)
        for _ in 0..<2 {
            let copy = MemoryDocument(id: id, kind: .collection, title: "YC", createdAt: Self.t0)
            context.insert(copy)
            context.insert(CollectionItem(document: copy, ordinal: 0, prompt: "Why now?", createdAt: Self.t0))
        }
        try context.save()

        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC interview", body: "")
        #expect(try fixture.documents().map(\.title) == ["YC interview", "YC interview"])

        try await fixture.store.deleteDocument(id)
        #expect(try fixture.documents().isEmpty)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<CollectionItem>()) == 0)
    }

    @Test func aCollectionNeedsAName() async throws {
        let fixture = try Fixture()
        await #expect(throws: KnowledgeBaseError.emptyTitle) {
            try await fixture.store.saveDocument(UUID(), kind: .collection, title: " ", body: "About it")
        }
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC", body: "")
        await #expect(throws: KnowledgeBaseError.emptyTitle) {
            try await fixture.store.saveDocument(id, kind: .collection, title: "", body: "")
        }
    }

    // MARK: Collections

    @Test func thirtyPastedQuestionsAreAddedInOneSaveInOrder() async throws {
        let fixture = try Fixture()
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC interview questions", body: "")
        let parsed = CollectionImport(parsing: ycQuestionsPaste)
        let result = try await fixture.store.addItems(parsed.items, to: id)
        #expect(result.addedIDs.count == 30)
        #expect(result.skippedDuplicates == 0)

        let items = try fixture.items(of: id)
        #expect(items.map(\.prompt) == parsed.items.map(\.prompt))
        #expect(items.map(\.ordinal) == Array(0..<30))
        #expect(items.map(\.id) == result.addedIDs)
        #expect(items.allSatisfy { $0.createdAt == Self.t0 && $0.practiceCount == 0 })
    }

    @Test func addingSkipsPromptsTheCollectionHasAndContinuesTheNumbering() async throws {
        let fixture = try Fixture()
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC", body: "")
        _ = try await fixture.store.addItems([.init(prompt: "Why now?"), .init(prompt: "Why you?")], to: id)
        let result = try await fixture.store.addItems(
            [.init(prompt: "why now"), .init(prompt: " "), .init(prompt: "Who else?", referenceAnswer: "  ")], to: id)
        #expect(result.addedIDs.count == 1)
        #expect(result.skippedDuplicates == 1)
        let items = try fixture.items(of: id)
        #expect(items.map(\.prompt) == ["Why now?", "Why you?", "Who else?"])
        #expect(items.map(\.ordinal) == [0, 1, 2])
        #expect(items.last?.referenceAnswer == nil)
    }

    @Test func addingToAMissingCollectionFails() async throws {
        let fixture = try Fixture()
        await #expect(throws: KnowledgeBaseError.documentNotFound) {
            try await fixture.store.addItems([.init(prompt: "Why now?")], to: UUID())
        }
    }

    @Test func itemsAreEditedDeletedAndReordered() async throws {
        let fixture = try Fixture()
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC", body: "")
        let added = try await fixture.store.addItems(
            ["A?", "B?", "C?", "D?"].map { CollectionImport.Item(prompt: $0) }, to: id
        ).addedIDs

        try await fixture.store.updateItem(added[1], prompt: " B, better? ", referenceAnswer: " Because. ")
        await #expect(throws: KnowledgeBaseError.emptyPrompt) {
            try await fixture.store.updateItem(added[1], prompt: "\n", referenceAnswer: nil)
        }
        await #expect(throws: KnowledgeBaseError.itemNotFound) {
            try await fixture.store.updateItem(UUID(), prompt: "X?", referenceAnswer: nil)
        }
        try await fixture.store.deleteItems([added[2]])
        try await fixture.store.reorderItems(in: id, as: [added[3], added[0]])

        let items = try fixture.items(of: id)
        #expect(items.map(\.prompt) == ["D?", "A?", "B, better?"])
        #expect(items.map(\.ordinal) == [0, 1, 2])
        #expect(items.last?.referenceAnswer == "Because.")

        try await fixture.store.updateItem(added[1], prompt: "B, better?", referenceAnswer: "")
        #expect(try fixture.items(of: id).last?.referenceAnswer == nil)
    }

    @Test func practiceRecordsSurviveEdits() async throws {
        let fixture = try Fixture()
        let id = UUID()
        _ = try await fixture.store.saveDocument(id, kind: .collection, title: "YC", body: "")
        let itemID = try #require(try await fixture.store.addItems([.init(prompt: "Why now?")], to: id).addedIDs.first)
        let context = ModelContext(fixture.container)
        let item = try #require(try context.fetch(FetchDescriptor<CollectionItem>()).first)
        item.recordPractice(at: Self.t0, score: 0.8)
        try context.save()

        try await fixture.store.updateItem(itemID, prompt: "Why now, exactly?", referenceAnswer: nil)
        try await fixture.store.reorderItems(in: id, as: [itemID])
        let stored = try #require(try fixture.items(of: id).first)
        #expect(stored.practiceCount == 1)
        #expect(stored.score == 0.8)
    }

    // MARK: Deferred

    @Test func theDeferredStoreFollowsTheOpenContainer() async throws {
        let first = try BlauModelContainer.makeInMemory()
        let second = try BlauModelContainer.makeInMemory()
        let current = Locked<ModelContainer?>(nil)
        let store = DeferredKnowledgeBaseStore { current.value }

        await #expect(throws: DeferredKnowledgeBaseStore.StoreUnavailableError.self) {
            try await store.saveDocument(UUID(), kind: .note, title: "A", body: "")
        }
        current.value = first
        _ = try await store.saveDocument(UUID(), kind: .note, title: "A", body: "")
        current.value = second
        _ = try await store.saveDocument(UUID(), kind: .note, title: "B", body: "")

        #expect(try ModelContext(first).fetch(FetchDescriptor<MemoryDocument>()).map(\.title) == ["A"])
        #expect(try ModelContext(second).fetch(FetchDescriptor<MemoryDocument>()).map(\.title) == ["B"])
    }
}

/// A value shared with a `@Sendable` closure in a test.
final class Locked<Value: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: every access goes through `lock`.
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
