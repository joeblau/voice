import BlauCore
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauPersistence

@Suite("Practice store")
struct PracticeStoreTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Fixture {
        let container: ModelContainer
        let knowledge: KnowledgeBaseStore
        let store: PracticeStore

        init(container: ModelContainer? = nil) throws {
            self.container = try container ?? BlauModelContainer.makeInMemory()
            knowledge = KnowledgeBaseStore(
                modelContainer: self.container, clock: ManualClock(now: PracticeStoreTests.t0))
            store = PracticeStore(modelContainer: self.container)
        }

        /// A collection with `prompts`, each with an answer "Answer n".
        func collection(_ title: String, prompts: [String]) async throws -> UUID {
            let id = UUID()
            _ = try await knowledge.saveDocument(id, kind: .collection, title: title, body: "")
            _ = try await knowledge.addItems(
                prompts.enumerated().map { .init(prompt: $1, referenceAnswer: "Answer \($0 + 1)") }, to: id)
            return id
        }

        func storedItems() throws -> [CollectionItem] {
            try ModelContext(container).fetch(FetchDescriptor<CollectionItem>(sortBy: [SortDescriptor(\.ordinal)]))
        }
    }

    @Test func listsCollectionsByTitleWithTheirPracticeRecord() async throws {
        let fixture = try Fixture()
        let yc = try await fixture.collection(
            "YC interview questions", prompts: ["What are you building?", "Why now?"])
        _ = try await fixture.collection("Board prep", prompts: ["What's the burn?"])
        _ = try await fixture.knowledge.saveDocument(UUID(), kind: .note, title: "A note", body: "Not a collection.")

        var collections = try await fixture.store.practiceCollections()
        #expect(collections.map(\.title) == ["Board prep", "YC interview questions"])
        #expect(collections[1].itemCount == 2)
        #expect(collections[1].practicedCount == 0)
        #expect(collections[1].averageScore == nil)

        let items = try await fixture.store.practiceItems(inCollection: yc)
        _ = try await fixture.store.recordPractice(itemID: items[0].id, score: 0.8, at: Self.t0)
        _ = try await fixture.store.recordPractice(itemID: items[1].id, score: 0.4, at: Self.t0.addingTimeInterval(60))
        collections = try await fixture.store.practiceCollections()
        let record = try #require(collections.first { $0.id == yc })
        #expect(record.practicedCount == 2)
        #expect(abs((record.averageScore ?? 0) - 0.6) < 1e-9)
        #expect(record.lastPracticedAt == Self.t0.addingTimeInterval(60))
    }

    @Test func itemsComeInCollectionOrderWithReferenceAnswers() async throws {
        let fixture = try Fixture()
        let id = try await fixture.collection("YC", prompts: ["A?", "B?", "C?"])
        let items = try await fixture.store.practiceItems(inCollection: id)
        #expect(items.map(\.prompt) == ["A?", "B?", "C?"])
        #expect(items.map(\.referenceAnswer) == ["Answer 1", "Answer 2", "Answer 3"])
        #expect(items.allSatisfy { $0.collectionID == id && !$0.isPracticed })
        #expect(try await fixture.store.practiceItems(inCollection: UUID()).isEmpty)
    }

    @Test func recordingAnAttemptWritesTheSyncedPracticeRecord() async throws {
        let fixture = try Fixture()
        let id = try await fixture.collection("YC", prompts: ["Why now?"])
        let itemID = try #require(try await fixture.store.practiceItems(inCollection: id).first?.id)

        let first = try #require(try await fixture.store.recordPractice(itemID: itemID, score: 0.5, at: Self.t0))
        #expect(first.practiceCount == 1)
        #expect(first.score == 0.5)
        #expect(first.lastPracticedAt == Self.t0)

        // An unscored attempt counts but keeps the score; scores are clamped.
        let later = Self.t0.addingTimeInterval(3_600)
        let unscored = try #require(try await fixture.store.recordPractice(itemID: itemID, score: nil, at: later))
        #expect(unscored.practiceCount == 2)
        #expect(unscored.score == 0.5)
        _ = try await fixture.store.recordPractice(itemID: itemID, score: 1.7, at: later)

        let stored = try #require(try fixture.storedItems().first)
        #expect(stored.practiceCount == 3)
        #expect(stored.score == 1)
        #expect(stored.lastPracticedAt == later)
        #expect(try await fixture.store.recordPractice(itemID: UUID(), score: 1, at: later) == nil)
    }

    @Test func cloudKitCopiesAreReadOnceAndAllWritten() async throws {
        let fixture = try Fixture()
        let id = try await fixture.collection("YC", prompts: ["Why now?"])
        let context = ModelContext(fixture.container)
        let original = try #require(try context.fetch(FetchDescriptor<CollectionItem>()).first)
        // CloudKit mirrored the item twice: same id, one copy behind.
        let copy = CollectionItem(
            id: original.id, document: original.document, ordinal: 0, prompt: original.prompt, createdAt: Self.t0)
        context.insert(copy)
        original.recordPractice(at: Self.t0, score: 0.3)
        try context.save()

        #expect(try await fixture.store.practiceItems(inCollection: id).count == 1)
        #expect(try await fixture.store.practiceCollections().first?.itemCount == 1)
        _ = try await fixture.store.recordPractice(itemID: original.id, score: 0.9, at: Self.t0.addingTimeInterval(60))
        let stored = try fixture.storedItems()
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.practiceCount == 2 && $0.score == 0.9 })
    }

    /// The practice record syncs through iCloud: each attempt is one save
    /// on the synced store, a persistent-history transaction by the app
    /// that updates the collection item, which is what CloudKit mirroring
    /// exports to the user's other devices (and the memory indexer reads).
    @Test func eachAttemptIsOneHistoryTransactionOnTheSyncedStore() async throws {
        let directory = try TemporaryDirectory()
        try directory.location.prepare()
        let container = try BlauModelContainer.makeLocal(url: directory.location.syncedStoreURL)
        let fixture = try Fixture(container: container)
        let id = try await fixture.collection("YC", prompts: ["What are you building?", "Why now?"])
        let tracker = PersistentHistoryTracker(
            consumer: "practice-test", container: container,
            cursors: HistoryCursorStore(modelContainer: try DerivedStore.open(at: directory.location.derivedStoreURL)),
            startPosition: .latest, clock: ManualClock(now: Self.t0))
        _ = try await tracker.fetchNewChanges()

        let items = try await fixture.store.practiceItems(inCollection: id)
        _ = try await fixture.store.recordPractice(itemID: items[1].id, score: 0.7, at: Self.t0)
        let changes = try await tracker.fetchNewChanges()
        #expect(changes.transactionCount == 1)
        #expect(changes.changes(to: CollectionItem.self).updated.count == 1)
        #expect(changes.changes(to: MemoryDocument.self).isEmpty)

        // A fresh container on the same file (a relaunch, or what an
        // export reads) sees the attempt.
        let reopened = try BlauModelContainer.makeLocal(url: directory.location.syncedStoreURL)
        let stored = try ModelContext(reopened).fetch(FetchDescriptor<CollectionItem>())
            .first { $0.id == items[1].id }
        #expect(stored?.practiceCount == 1)
        #expect(stored?.score == 0.7)
    }

    @Test func theDeferredStoreFollowsTheOpenContainer() async throws {
        let first = try Fixture()
        let second = try Fixture()
        let a = try await first.collection("First", prompts: ["A?"])
        _ = try await second.collection("Second", prompts: ["B?"])
        let current = CurrentContainer(first.container)
        let deferred = DeferredPracticeStore { current.get() }

        #expect(try await deferred.practiceCollections().map(\.title) == ["First"])
        #expect(try await deferred.practiceItems(inCollection: a).count == 1)
        current.set(second.container)
        #expect(try await deferred.practiceCollections().map(\.title) == ["Second"])
        current.set(nil)
        await #expect(throws: MemoryToolFailure.self) { try await deferred.practiceCollections() }
    }
}

/// A mutable container slot for the deferred store's provider.
private final class CurrentContainer: Sendable {
    private let value: Mutex<ModelContainer?>

    init(_ value: ModelContainer?) {
        self.value = Mutex(value)
    }

    func get() -> ModelContainer? { value.withLock { $0 } }
    func set(_ container: ModelContainer?) { value.withLock { $0 = container } }
}
