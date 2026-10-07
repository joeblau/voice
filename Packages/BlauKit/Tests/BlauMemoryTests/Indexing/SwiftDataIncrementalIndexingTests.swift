import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

/// The incremental indexer on a real SwiftData store (#63): persistent
/// history, the remote-change notification, the change resolver and the
/// store reader together.
///
/// CloudKit can't run in a test, so "another device" is a write with the
/// author CloudKit mirroring gives its imports
/// (`NSCloudKitMirroringDelegate.import`), through its own context on the
/// same container, which is how mirroring writes what it imports. The
/// indexer sees exactly what it would see after a real import: a history
/// transaction and an `NSPersistentStoreRemoteChange` notification.
@Suite("Memory indexer on SwiftData", .serialized, .timeLimit(.minutes(2)))
struct SwiftDataIncrementalIndexingTests {
    typealias Support = IndexTestSupport

    /// A synced store and a derived store on disk (history needs SQLite).
    final class Fixture: Sendable {
        let directory: URL
        let location: StoreLocation
        let container: ModelContainer
        let derived: ModelContainer
        let index: MemoryIndex
        let embedder = Support.HashingEmbedder()

        init() throws {
            directory = try Support.temporaryDirectory()
            location = StoreLocation(directory: directory)
            try location.prepare()
            container = try BlauModelContainer.makeLocal(url: location.syncedStoreURL)
            derived = try DerivedStore.open(at: location.derivedStoreURL)
            index = try MemoryIndex.inMemory()
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func feed() -> SwiftDataMemoryChangeFeed {
            SwiftDataMemoryChangeFeed(
                container: container, cursors: HistoryCursorStore(modelContainer: derived),
                storeURL: location.syncedStoreURL)
        }

        func indexer(
            debounce: Duration = .zero, embedder: (any MemoryChunkEmbedding)? = nil
        ) -> MemoryIndexer {
            MemoryIndexer(
                index: index, reader: SwiftDataMemorySources(container: container), feed: feed(),
                embedder: embedder ?? self.embedder, chunker: Support.chunker, clock: SystemClock(),
                configuration: MemoryIndexer.Configuration(debounce: debounce, retryDelay: .milliseconds(10)))
        }

        /// A context writing as this device.
        func appContext() -> ModelContext {
            let context = ModelContext(container)
            context.author = HistoryAuthor.app
            return context
        }

        /// A context writing as CloudKit mirroring does when it imports
        /// another device's changes.
        func importContext() -> ModelContext {
            let context = ModelContext(container)
            context.author = "\(HistoryAuthor.cloudKitMirroringPrefix).import"
            return context
        }

        func search(_ query: String) async throws -> [MemoryChunk] {
            let hits = try await index.keywordSearch(query, limit: 20)
            return try await index.chunks(withIDs: hits.map(\.chunkID))
        }

        /// The index a from-scratch rebuild of the store gives.
        func reference() async throws -> [String] {
            let fresh = try MemoryIndex.inMemory()
            try await MemoryIndexRebuilder(
                index: fresh, sources: SwiftDataMemorySources(container: container), chunker: Support.chunker,
                embedder: Support.HashingEmbedder()
            ).rebuild()
            return try await IndexerTestSupport.fingerprint(fresh)
        }
    }

    /// Polls until `condition` holds (the run loop works on its own task).
    static func eventually(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Acceptance: an edit from another device becomes searchable

    @Test func aNoteEditedOnAnotherDeviceBecomesSearchable() async throws {
        let fixture = try Fixture()
        let paragraphs = (0..<4).map { "Section \($0) " + String(repeating: "covers the rollout plan ", count: 11) }
        let note = MemoryDocument(
            kind: .note, title: "Larderly launch", body: paragraphs.joined(separator: "\n\n"), createdAt: Support.t0)
        let context = fixture.appContext()
        context.insert(note)
        try context.save()

        let indexer = fixture.indexer(debounce: .milliseconds(20))
        let run = Task { await indexer.run() }
        defer { run.cancel() }
        try await Self.eventually { await indexer.currentStatus.lastRebuild != nil }
        await indexer.waitUntilIdle()
        #expect(try await fixture.search("rollout").count == 4)
        let embeddedBefore = fixture.embedder.embeddedTexts.count

        // Device A edits one section; CloudKit imports it here. Nobody
        // calls the indexer: the store's remote-change notification does.
        let imported = fixture.importContext()
        let copy = try #require(try imported.fetch(FetchDescriptor<MemoryDocument>()).first)
        var edited = paragraphs
        edited[2] = "Section 2 moves the Osaka pilot to June " + String(repeating: "covers the rollout plan ", count: 9)
        #expect(copy.update(body: edited.joined(separator: "\n\n"), at: Support.t0.addingTimeInterval(60)))
        try imported.save()

        try await Self.eventually { try await !fixture.search("Osaka").isEmpty }
        await indexer.waitUntilIdle()
        let hits = try await fixture.search("Osaka pilot")
        #expect(hits.count == 1)
        #expect(hits.first?.sourceID == note.id)
        // Only the edited section was embedded again.
        #expect(fixture.embedder.embeddedTexts.count == embeddedBefore + 1)
        #expect(try await IndexerTestSupport.fingerprint(fixture.index) == fixture.reference())
        let status = await indexer.currentStatus
        #expect(status.lastIndexed != nil)
        #expect(status.vectorCount == status.chunkCount)
    }

    @Test func aConversationRecordedOnAnotherDeviceBecomesSearchable() async throws {
        let fixture = try Fixture()
        let indexer = fixture.indexer(debounce: .milliseconds(20))
        let run = Task { await indexer.run() }
        defer { run.cancel() }
        try await Self.eventually { await indexer.currentStatus.lastRebuild != nil }

        let imported = fixture.importContext()
        let conversation = Conversation(startedAt: Support.t0)
        imported.insert(conversation)
        for (offset, turn) in [
            (UtteranceRole.user, "Where should we eat in Osaka?"), (.agent, "Menya Kotori near Namba."),
        ]
        .enumerated() {
            imported.insert(
                StoredUtterance(
                    conversation: conversation, role: turn.0, text: turn.1,
                    startedAt: Support.t0.addingTimeInterval(Double(offset) * 10), isFinal: true,
                    source: turn.0 == .user ? .parakeet : .grok))
        }
        try imported.save()

        try await Self.eventually { try await !fixture.search("Kotori").isEmpty }
        #expect(try await fixture.search("Kotori").first?.conversationID == conversation.id)
    }

    // MARK: - Every kind of change matches a full rebuild

    @Test func incrementalUpdatesMatchAFullRebuild() async throws {
        let fixture = try Fixture()
        let indexer = fixture.indexer()
        let context = fixture.appContext()

        func check(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try context.save()
            try await indexer.runUntilIdle()
            let actual = try await IndexerTestSupport.fingerprint(fixture.index)
            let expected = try await fixture.reference()
            #expect(actual == expected, "after: \(step)", sourceLocation: sourceLocation)
        }

        // A conversation with a topic and a fact from its first utterance.
        let conversation = Conversation(startedAt: Support.t0)
        context.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: Support.t0)
        context.insert(topic)
        var utterances: [StoredUtterance] = []
        for (offset, text) in [
            "We raised the seed round.", "Congratulations, who led it?", "Sequoia led it.", "Great.",
        ]
        .enumerated() {
            let utterance = StoredUtterance(
                conversation: conversation, topic: topic, role: offset.isMultiple(of: 2) ? .user : .agent, text: text,
                startedAt: Support.t0.addingTimeInterval(Double(offset) * 20), isFinal: true,
                source: offset.isMultiple(of: 2) ? .parakeet : .grok)
            context.insert(utterance)
            utterances.append(utterance)
        }
        let sequoia = MemoryEntity(name: "Sequoia", type: .organization, createdAt: Support.t0)
        context.insert(sequoia)
        let led = Fact(
            subject: sequoia, predicate: "led", objectText: "the seed round", sourceUtteranceID: utterances[2].id,
            validFrom: Support.t0, origin: .extracted)
        context.insert(led)
        let collection = MemoryDocument(kind: .collection, title: "YC interview", createdAt: Support.t0)
        context.insert(collection)
        let item = CollectionItem(
            document: collection, ordinal: 0, prompt: "What are you building?", referenceAnswer: "A voice app.",
            createdAt: Support.t0)
        context.insert(item)
        let second = CollectionItem(document: collection, ordinal: 1, prompt: "Why now?", createdAt: Support.t0)
        context.insert(second)
        let note = MemoryDocument(kind: .note, title: "Pricing", body: "Larderly costs $149.", createdAt: Support.t0)
        context.insert(note)
        try await check("the first build")
        let firstBuild = try #require(try await fixture.index.lastRebuild())

        topic.title = "Fundraising"
        try await check("naming the topic")

        context.insert(
            StoredUtterance(
                conversation: conversation, topic: topic, role: .user, text: "Next we hire two engineers.",
                startedAt: Support.t0.addingTimeInterval(200), isFinal: true, source: .parakeet))
        try await check("a new utterance")

        context.delete(utterances[3])
        try await check("deleting an utterance")

        _ = note.update(body: "Larderly costs $199 per location.", at: Support.t0.addingTimeInterval(300))
        try await check("editing a note")

        _ = collection.update(title: "Demo day", at: Support.t0.addingTimeInterval(400))
        try await check("renaming a collection")

        second.prompt = "Why is now the right time?"
        try await check("editing a collection item")

        context.delete(item)
        try await check("deleting a collection item")

        sequoia.name = "Sequoia Capital"
        try await check("renaming an entity")

        led.invalidate(at: Support.t0.addingTimeInterval(500))
        try await check("invalidating a fact")

        context.delete(led)
        try await check("deleting a fact")
        #expect(try await fixture.search("Sequoia").allSatisfy { $0.sourceKind == .conversation })

        context.delete(note)
        try await check("deleting a note")

        context.delete(collection)
        try await check("deleting a collection")

        context.delete(conversation)
        try await check("deleting a conversation")
        #expect(try await fixture.index.statistics().chunks == 0)
        // Every step after the first build was incremental: no full pass.
        #expect(try await fixture.index.lastRebuild() == firstBuild)
    }

    @Test func aRelaunchReplaysChangesThatWereReadButNotWritten() async throws {
        let fixture = try Fixture()
        try await fixture.indexer().runUntilIdle()

        let context = fixture.appContext()
        context.insert(
            MemoryDocument(kind: .note, title: "Pricing", body: "Larderly costs $149.", createdAt: Support.t0))
        try context.save()

        // A feed that reads the change, but the app dies before the
        // indexer writes it and commits.
        let lost = try await fixture.feed().fetchChanges()
        #expect(lost.documents.count == 1)

        try await fixture.indexer().runUntilIdle()
        #expect(try await fixture.search("Larderly").count == 1)
    }

    // MARK: - Resolver

    @Test func theResolverTracesRecordsToTheirSources() async throws {
        let fixture = try Fixture()
        let tracker = PersistentHistoryTracker(
            consumer: "resolver-test", container: fixture.container,
            cursors: HistoryCursorStore(modelContainer: fixture.derived))
        let resolver = SwiftDataMemoryChangeResolver(container: fixture.container)
        let context = fixture.appContext()

        let conversation = Conversation(startedAt: Support.t0)
        context.insert(conversation)
        let utterance = StoredUtterance(
            conversation: conversation, role: .user, text: "Hi", startedAt: Support.t0, isFinal: true,
            source: .parakeet)
        context.insert(utterance)
        let collection = MemoryDocument(kind: .collection, title: "YC", createdAt: Support.t0)
        context.insert(collection)
        let item = CollectionItem(document: collection, ordinal: 0, prompt: "Why?", createdAt: Support.t0)
        context.insert(item)
        let entity = MemoryEntity(name: "Acme", type: .organization, createdAt: Support.t0)
        context.insert(entity)
        let fact = Fact(
            subject: entity, predicate: "raised", objectText: "$2M", sourceUtteranceID: utterance.id,
            validFrom: Support.t0, origin: .extracted)
        context.insert(fact)
        try context.save()

        let inserted = try resolver.resolve(try await tracker.fetchNewChanges())
        #expect(inserted.conversations == [conversation.id])
        #expect(inserted.documents == [collection.id])
        #expect(inserted.facts == [fact.id])
        #expect(inserted.sweeps.isEmpty)

        // An import touching only the utterance and the entity.
        let imported = fixture.importContext()
        let importedUtterance = try #require(try imported.fetch(FetchDescriptor<StoredUtterance>()).first)
        importedUtterance.text = "Hello"
        let importedEntity = try #require(try imported.fetch(FetchDescriptor<MemoryEntity>()).first)
        importedEntity.name = "Acme Inc"
        try imported.save()
        let edited = try resolver.resolve(try await tracker.fetchNewChanges())
        #expect(edited.importedTransactions == 1)
        #expect(edited.conversations == [conversation.id])
        #expect(edited.facts == [fact.id])

        context.delete(item)
        context.delete(fact)
        try context.save()
        let deleted = try resolver.resolve(try await tracker.fetchNewChanges())
        #expect(deleted.sweeps == [.collectionItem, .fact])
        #expect(deleted.documents == [collection.id])

        context.delete(conversation)
        try context.save()
        let deletedConversation = try resolver.resolve(try await tracker.fetchNewChanges())
        #expect(deletedConversation.sweeps.contains(.conversation))
    }

    @Test func expiredHistoryAsksForAFullPass() throws {
        let fixture = try Fixture()
        let resolved = try SwiftDataMemoryChangeResolver(container: fixture.container)
            .resolve(StoreChangeSet(historyWasReset: true))
        #expect(resolved.requiresFullPass)
    }

    // MARK: - Reader

    @Test func theReaderMatchesTheProvider() async throws {
        let fixture = try Fixture()
        let context = fixture.appContext()
        let conversation = Conversation(startedAt: Support.t0)
        context.insert(conversation)
        let utterance = StoredUtterance(
            conversation: conversation, role: .user, text: "We closed the round", startedAt: Support.t0,
            isFinal: true, source: .parakeet)
        context.insert(utterance)
        // Two facts from the same utterance, and a CloudKit duplicate of one.
        let factID = UUID()
        for copy in 0..<2 {
            context.insert(
                Fact(
                    id: factID, predicate: "closed", objectText: "the round", sourceUtteranceID: utterance.id,
                    validFrom: Support.t0, invalidatedAt: copy == 1 ? Support.t0.addingTimeInterval(9) : nil,
                    origin: .extracted))
        }
        context.insert(
            Fact(
                predicate: "raised", objectText: "$2M", sourceUtteranceID: utterance.id,
                validFrom: Support.t0.addingTimeInterval(-5), origin: .extracted))
        let orphan = CollectionItem(ordinal: 0, prompt: "Loose", createdAt: Support.t0)
        context.insert(orphan)
        try context.save()

        let sources = SwiftDataMemorySources(container: fixture.container)
        let batch = try await sources.read(conversations: [conversation.id, UUID()], documents: [], facts: [factID])
        let provided = try await sources.facts()
        #expect(batch.conversations == (try await sources.conversations([conversation.id])))
        #expect(batch.exchangeFacts == provided)
        #expect(batch.facts == provided.filter { $0.id == factID })
        #expect(batch.facts.first?.invalidatedAt == Support.t0.addingTimeInterval(9))
        #expect(try await sources.sourceIDs(.collectionItem).isEmpty)
        #expect(try await sources.sourceIDs(.fact).count == 2)
        let stamps = try await sources.stamps()
        #expect(stamps.count == 3)
        #expect(stamps.contains(MemorySourceStamp(kind: .conversation, id: conversation.id, date: Support.t0)))
    }
}
