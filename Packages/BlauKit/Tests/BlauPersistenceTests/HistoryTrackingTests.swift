import BlauCore
import CoreData
import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

/// A synced store on disk (history needs a SQLite store) plus a derived
/// store for cursors.
private struct HistoryFixture {
    let directory: TemporaryDirectory
    let container: ModelContainer
    let derived: ModelContainer

    init() throws {
        directory = try TemporaryDirectory()
        try directory.location.prepare()
        container = try BlauModelContainer.makeLocal(url: directory.location.syncedStoreURL)
        derived = try DerivedStore.open(at: directory.location.derivedStoreURL)
    }

    func tracker(
        _ consumer: String = "test",
        startPosition: PersistentHistoryTracker.StartPosition = .beginning,
        batchSize: Int = 500
    ) -> PersistentHistoryTracker {
        PersistentHistoryTracker(
            consumer: consumer, container: container, cursors: HistoryCursorStore(modelContainer: derived),
            startPosition: startPosition, clock: ManualClock(now: syncT0), batchSize: batchSize)
    }

    func context(author: String? = HistoryAuthor.app) -> ModelContext {
        let context = ModelContext(container)
        context.author = author
        return context
    }
}

@Suite("PersistentHistoryTracker")
struct PersistentHistoryTrackerTests {
    @Test func reportsInsertsUpdatesAndDeletesPerEntity() async throws {
        let fixture = try HistoryFixture()
        let tracker = fixture.tracker()
        #expect(try await tracker.fetchNewChanges().isEmpty)

        let context = fixture.context()
        let conversation = Conversation(startedAt: syncT0)
        context.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: syncT0)
        context.insert(topic)
        try context.save()

        let inserted = try await tracker.fetchNewChanges()
        #expect(inserted.transactionCount == 1)
        #expect(!inserted.includesRemoteChanges)
        #expect(inserted.changes(to: Conversation.self).inserted == [conversation.persistentModelID])
        #expect(inserted.changes(to: Topic.self).inserted == [topic.persistentModelID])
        #expect(inserted.changes(to: StoredUtterance.self).isEmpty)

        conversation.title = "Renamed"
        try context.save()
        let updated = try await tracker.fetchNewChanges()
        #expect(updated.changes(to: Conversation.self).updated == [conversation.persistentModelID])

        let topicID = topic.persistentModelID
        context.delete(topic)
        try context.save()
        let deleted = try await tracker.fetchNewChanges()
        #expect(deleted.changes(to: Topic.self).deleted == [topicID])

        #expect(try await tracker.fetchNewChanges().isEmpty)
    }

    @Test func foldsSeveralTransactionsIntoNetChanges() async throws {
        let fixture = try HistoryFixture()
        let tracker = fixture.tracker()
        let context = fixture.context()

        let kept = Conversation(startedAt: syncT0)
        let transient = Conversation(startedAt: syncT0)
        context.insert(kept)
        context.insert(transient)
        try context.save()
        kept.title = "Edited after insert"
        context.delete(transient)
        try context.save()

        let changes = try await tracker.fetchNewChanges()
        #expect(changes.transactionCount == 2)
        let conversations = changes.changes(to: Conversation.self)
        #expect(conversations.inserted == [kept.persistentModelID])
        #expect(conversations.updated.isEmpty)
        #expect(conversations.deleted.isEmpty)
    }

    @Test func pagesThroughLongHistories() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        for index in 0..<7 {
            context.insert(Conversation(startedAt: syncT0 + Double(index)))
            try context.save()
        }
        let changes = try await fixture.tracker(batchSize: 3).fetchNewChanges()
        #expect(changes.transactionCount == 7)
        #expect(changes.changes(to: Conversation.self).inserted.count == 7)
    }

    @Test func countsTransactionsImportedFromCloudKit() async throws {
        let fixture = try HistoryFixture()
        let tracker = fixture.tracker()
        let imported = fixture.context(author: "NSCloudKitMirroringDelegate.import")
        imported.insert(Conversation(startedAt: syncT0))
        try imported.save()
        let local = fixture.context()
        local.insert(Conversation(startedAt: syncT0))
        try local.save()

        let changes = try await tracker.fetchNewChanges()
        #expect(changes.transactionCount == 2)
        #expect(changes.importedTransactionCount == 1)
        #expect(changes.includesRemoteChanges)
    }

    @Test func resumesFromTheSavedCursorAfterARelaunch() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()
        #expect(try await fixture.tracker().fetchNewChanges().transactionCount == 1)

        let later = Conversation(startedAt: syncT0 + 60)
        context.insert(later)
        try context.save()

        // A new tracker (as after a relaunch) only sees what's new.
        let changes = try await fixture.tracker().fetchNewChanges()
        #expect(changes.transactionCount == 1)
        #expect(changes.changes(to: Conversation.self).inserted == [later.persistentModelID])
    }

    @Test func consumersHaveIndependentCursors() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()

        #expect(try await fixture.tracker("indexer").fetchNewChanges().transactionCount == 1)
        #expect(try await fixture.tracker("timeline").fetchNewChanges().transactionCount == 1)
        #expect(try await fixture.tracker("indexer").fetchNewChanges().isEmpty)
    }

    @Test func aLatestConsumerSkipsExistingHistory() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()

        let tracker = fixture.tracker(startPosition: .latest)
        #expect(try await tracker.fetchNewChanges().isEmpty)

        context.insert(Conversation(startedAt: syncT0 + 1))
        try context.save()
        #expect(try await tracker.fetchNewChanges().transactionCount == 1)
    }

    @Test func savesCursorsInTheDerivedStore() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()
        _ = try await fixture.tracker("indexer").fetchNewChanges()

        let cursors = HistoryCursorStore(modelContainer: fixture.derived)
        guard case .after(let data) = try await cursors.position(for: "indexer") else {
            Issue.record("No cursor saved")
            return
        }
        #expect(try JSONDecoder().decode(DefaultHistoryToken.self, from: data) == latestToken(in: fixture))
        #expect(try await cursors.position(for: "unknown") == .unsaved)
    }

    @Test func aLatestConsumerThatStartedOnAnEmptyStoreMissesNothing() async throws {
        let fixture = try HistoryFixture()
        // First launch: no history yet, so the cursor is saved as "beginning".
        #expect(try await fixture.tracker(startPosition: .latest).fetchNewChanges().isEmpty)
        #expect(try await HistoryCursorStore(modelContainer: fixture.derived).position(for: "test") == .beginning)

        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()

        // A new tracker (relaunch, or the store reopened in another sync
        // mode) must still report the write instead of skipping to latest.
        #expect(try await fixture.tracker(startPosition: .latest).fetchNewChanges().transactionCount == 1)
    }

    @Test func anUnreadableCursorStartsOver() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()
        try await HistoryCursorStore(modelContainer: fixture.derived)
            .setToken(Data("garbage".utf8), for: "test", at: syncT0)

        #expect(try await fixture.tracker().fetchNewChanges().transactionCount == 1)
    }

    @Test func anExpiredCursorResetsHistory() async throws {
        let fixture = try HistoryFixture()
        let tracker = fixture.tracker()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()
        #expect(try await tracker.fetchNewChanges().transactionCount == 1)

        // Two more writes, then history up to the latest transaction is
        // purged, taking the tracker's cursor with it.
        context.insert(Conversation(startedAt: syncT0 + 1))
        try context.save()
        context.insert(Conversation(startedAt: syncT0 + 2))
        try context.save()
        let latest = try latestToken(in: fixture)
        try ModelContext(fixture.container).deleteHistory(
            HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token < latest }))

        let reset = try await tracker.fetchNewChanges()
        #expect(reset.historyWasReset)
        #expect(reset.transactionCount == 0)

        // The cursor moved to the latest transaction: reading resumes normally.
        let next = try await tracker.fetchNewChanges()
        #expect(!next.historyWasReset)
        #expect(next.isEmpty)
        context.insert(Conversation(startedAt: syncT0 + 3))
        try context.save()
        #expect(try await tracker.fetchNewChanges().transactionCount == 1)

        // The reset cursor was saved, so a relaunch doesn't reset again.
        #expect(try await fixture.tracker().fetchNewChanges().isEmpty)
    }

    @Test func aDeferredCursorIsOnlySavedWhenTheConsumerSaysSo() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()

        // Read but not handled before the app dies: reported again.
        let tracker = fixture.tracker("indexer")
        #expect(try await tracker.fetchNewChanges(savingCursor: false).transactionCount == 1)
        #expect(try await tracker.fetchNewChanges(savingCursor: false).isEmpty)
        #expect(try await HistoryCursorStore(modelContainer: fixture.derived).position(for: "indexer") == .unsaved)
        let relaunched = fixture.tracker("indexer")
        #expect(try await relaunched.fetchNewChanges(savingCursor: false).transactionCount == 1)

        // Handled, then saved: not reported again.
        try await relaunched.saveCursor()
        #expect(try await fixture.tracker("indexer").fetchNewChanges().isEmpty)
    }

    @Test func skipToLatestMovesPastEverythingWrittenSoFar() async throws {
        let fixture = try HistoryFixture()
        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()

        try await fixture.tracker("indexer").skipToLatest()
        let later = Conversation(startedAt: syncT0 + 1)
        context.insert(later)
        try context.save()

        let changes = try await fixture.tracker("indexer").fetchNewChanges()
        #expect(changes.transactionCount == 1)
        #expect(changes.changes(to: Conversation.self).inserted == [later.persistentModelID])
    }

    @Test func skipToLatestOnAnEmptyStoreMissesNothing() async throws {
        let fixture = try HistoryFixture()
        try await fixture.tracker("indexer").skipToLatest()
        #expect(try await HistoryCursorStore(modelContainer: fixture.derived).position(for: "indexer") == .beginning)

        let context = fixture.context()
        context.insert(Conversation(startedAt: syncT0))
        try context.save()
        #expect(try await fixture.tracker("indexer").fetchNewChanges().transactionCount == 1)
    }

    @Test func recognisesBothHistoryTokenExpiredErrors() {
        #expect(PersistentHistoryTracker.isHistoryTokenExpired(SwiftDataError.historyTokenExpired))
        #expect(
            PersistentHistoryTracker.isHistoryTokenExpired(
                NSError(domain: NSCocoaErrorDomain, code: NSPersistentHistoryTokenExpiredError)))
        #expect(!PersistentHistoryTracker.isHistoryTokenExpired(CocoaError(.fileReadNoSuchFile)))
        #expect(!PersistentHistoryTracker.isHistoryTokenExpired(SwiftDataError.loadIssueModelContainer))
    }

    private func latestToken(in fixture: HistoryFixture) throws -> DefaultHistoryToken {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        descriptor.fetchLimit = 1
        return try #require(try ModelContext(fixture.container).fetchHistory(descriptor).first?.token)
    }
}

@Suite("Store change notifications")
struct StoreChangeNotificationTests {
    @Test func remoteChangesForTheSyncedStoreAreSignalled() async throws {
        let center = NotificationCenter()
        let storeURL = URL(filePath: "/data/Blau/Blau.store")
        let changes = RemoteChangeMonitor(storeURL: storeURL, notificationCenter: center).changes()

        center.post(name: .NSPersistentStoreRemoteChange, object: nil, userInfo: ["storeURL": storeURL])
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func otherStoresAreIgnored() {
        let storeURL = URL(filePath: "/data/Blau/Blau.store")
        #expect(!RemoteChangeMonitor.matches(URL(filePath: "/data/Blau/Derived/BlauDerived.store"), storeURL: storeURL))
        #expect(RemoteChangeMonitor.matches(URL(filePath: "/data/Blau/./Blau.store"), storeURL: storeURL))
        #expect(RemoteChangeMonitor.matches(nil, storeURL: storeURL))
    }
}
