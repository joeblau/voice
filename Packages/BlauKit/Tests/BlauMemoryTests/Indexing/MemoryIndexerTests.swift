import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

/// The incremental indexer's logic on in-memory sources (#63). The
/// SwiftData path is in `SwiftDataIncrementalIndexingTests`.
@Suite("Memory indexer", .timeLimit(.minutes(2)))
struct MemoryIndexerTests {
    typealias Support = IndexTestSupport
    typealias Fakes = IndexerTestSupport

    /// A trip conversation with a fact from its first utterance, a note, a
    /// collection and an unrelated fact.
    static func reader() -> Fakes.FakeReader {
        let trip = Support.conversation(
            start: Support.t0,
            [
                (.user, "We booked flights to Japan, landing in Tokyo on April 2nd."),
                (.agent, "Two weeks is a good length; book Kyoto hotels soon."),
                (.user, "Remember the ramen place in Osaka with yuzu shio broth?"),
                (.agent, "Menya Kotori near Namba station, it sells out by 2."),
            ])
        let note = Fakes.document(
            title: "Pricing", ["Larderly costs $149 per location per month.", "Enterprise plans start at ten sites."],
            updatedAt: Support.t0.addingTimeInterval(3600))
        let collection = Fakes.document(
            title: "YC interview", [], updatedAt: Support.t0.addingTimeInterval(-3600),
            items: [
                DocumentSnapshot.ItemSnapshot(
                    id: UUID(), ordinal: 0, prompt: "What are you building?", referenceAnswer: "A voice app.",
                    createdAt: Support.t0)
            ])
        let landing = FactSnapshot(
            id: UUID(), statement: "User reserved a window seat", validFrom: Support.t0,
            sourceUtteranceID: trip.utterances[0].id)
        let coffee = FactSnapshot(
            id: UUID(), statement: "User drinks oat milk flat whites", validFrom: Support.t0.addingTimeInterval(-86_400)
        )
        return Fakes.FakeReader(
            Support.FakeSources(conversations: [trip], documents: [note, collection], facts: [landing, coffee]))
    }

    /// `reader()`'s chunks: two exchanges, the note, the collection's title,
    /// its item and two facts.
    static let chunkCount = 2 + 1 + 1 + 1 + 2

    static func texts(_ index: MemoryIndex, matching query: String) async throws -> [String] {
        let hits = try await index.keywordSearch(query, limit: 20)
        return try await index.chunks(withIDs: hits.map(\.chunkID)).map(\.keyText)
    }

    // MARK: - First run

    @Test func aNewIndexIsBuiltByAFullPassThatSkipsHistory() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        feed.enqueue(MemorySourceChanges(conversations: Set(reader.contents.conversations.map(\.id))))
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)

        try await indexer.runUntilIdle()

        // History up to the pass is covered by the pass: it isn't replayed.
        #expect(feed.skips == 1)
        #expect(try await index.needsRebuild == false)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
        let status = await indexer.currentStatus
        #expect(status.activity == .idle)
        #expect(status.rebuild == nil)
        #expect(status.chunkCount == (try await Fakes.referenceFingerprint(reader)).count)
        #expect(status.vectorCount == status.chunkCount)
        #expect(status.lastRebuild == Support.t0)
        #expect(try await index.stateValue(forKey: MemoryIndexer.fullPassKey) == nil)
    }

    @Test func theFullPassGoesNewestFirst() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Fakes.FakeReader()
        let conversations = (0..<5).map { day in
            Support.conversation(
                start: Support.t0.addingTimeInterval(Double(day) * 86_400),
                [(.user, "Day \(day) question"), (.agent, "Day \(day) answer")])
        }
        reader.update { $0.conversations = conversations }
        let indexer = Fakes.indexer(
            index: index, reader: reader,
            configuration: MemoryIndexer.Configuration(debounce: .zero, conversationsPerStep: 2, retryDelay: .zero))

        try await indexer.runUntilIdle()

        let order = reader.conversationReads.filter { !$0.isEmpty }
        let expected = conversations.reversed().map(\.id)
        #expect(order == [Set(expected[0..<2]), Set(expected[2..<4]), Set(expected[4..<5])])
    }

    @Test func anIndexAlreadyBuiltIsOnlyUpdated() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        try await Fakes.indexer(index: index, reader: reader).runUntilIdle()

        let feed = Fakes.ScriptedFeed()
        let embedder = Support.HashingEmbedder()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed, embedder: embedder)
        try await indexer.runUntilIdle()

        #expect(feed.skips == 0)
        #expect(embedder.embeddedTexts.isEmpty)
        // The launch sweep compares every kind but finds nothing to remove.
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    // MARK: - Incremental changes

    @Test func anEditedNoteIsReembeddedOnlyWhereItChanged() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let embedder = Support.HashingEmbedder()
        let indexer = Fakes.indexer(
            index: index, reader: reader, feed: feed, embedder: embedder,
            configuration: MemoryIndexer.Configuration(debounce: .zero, writeBatchSize: 1, retryDelay: .zero))
        try await indexer.runUntilIdle()
        let embeddedBefore = embedder.embeddedTexts.count

        // A long note: each paragraph is its own chunk.
        let noteID = reader.contents.documents[0].id
        let paragraphs = (0..<6).map { "Paragraph \($0) " + String(repeating: "about location pricing ", count: 12) }
        reader.update { $0.documents[0] = Fakes.document(id: noteID, title: "Pricing", paragraphs) }
        feed.enqueue(MemorySourceChanges(documents: [noteID]))
        try await indexer.runUntilIdle()
        let chunks = try await index.chunks(ofSource: noteID, kind: .document)
        #expect(chunks.count > 2)
        #expect(embedder.embeddedTexts.count == embeddedBefore + chunks.count)

        // Edit one paragraph, as another device would.
        var edited = paragraphs
        edited[4] =
            "Paragraph 4 says the Kyoto pilot costs less " + String(repeating: "about location pricing ", count: 10)
        reader.update { $0.documents[0] = Fakes.document(id: noteID, title: "Pricing", edited) }
        feed.enqueue(MemorySourceChanges(documents: [noteID]))
        let before = embedder.embeddedTexts.count
        try await indexer.runUntilIdle()

        let reembedded = embedder.embeddedTexts[before...]
        #expect(reembedded.count == 1)
        #expect(reembedded.first?.contains("Kyoto pilot") == true)
        #expect(try await Self.texts(index, matching: "pilot").count == 1)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
        #expect(feed.commits >= 3)
        let status = await indexer.currentStatus
        #expect(status.lastIndexed == Support.t0)
    }

    @Test func newUtterancesAreIndexedAndKeepEarlierVectors() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let embedder = Support.HashingEmbedder()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed, embedder: embedder)
        try await indexer.runUntilIdle()

        let id = reader.contents.conversations[0].id
        let before = embedder.embeddedTexts.count
        reader.update { contents in
            let start = Support.t0.addingTimeInterval(600)
            contents.conversations[0].utterances += [
                .init(id: UUID(), role: .user, text: "Which station for the Shinkansen to Kyoto?", startedAt: start),
                .init(id: UUID(), role: .agent, text: "Take it from Shin-Osaka.", startedAt: start + 30),
            ]
        }
        feed.enqueue(MemorySourceChanges(conversations: [id]))
        try await indexer.runUntilIdle()

        // Only the new exchange is embedded; the two earlier ones keep theirs.
        #expect(embedder.embeddedTexts.count == before + 1)
        #expect(try await Self.texts(index, matching: "Shinkansen").count == 1)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func deletedSourcesAreSweptAway() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        reader.update { contents in
            contents.conversations = []
            contents.documents.removeAll { $0.title == "YC interview" }
        }
        feed.enqueue(MemorySourceChanges(sweeps: [.conversation, .document, .collectionItem]))
        try await indexer.runUntilIdle()

        #expect(try await index.sourceIDs(kind: .conversation).isEmpty)
        #expect(try await index.sourceIDs(kind: .collectionItem).isEmpty)
        #expect(try await Self.texts(index, matching: "Menya Kotori").isEmpty)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func aChangedSourceThatNoLongerExistsIsRemoved() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        let note = reader.contents.documents[0].id
        reader.update { $0.documents.removeAll { $0.id == note } }
        feed.enqueue(MemorySourceChanges(documents: [note]))
        try await indexer.runUntilIdle()

        #expect(try await index.chunks(ofSource: note, kind: .document).isEmpty)
    }

    @Test func forgettingAFactTakesItOutOfItsExchange() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()
        let conversation = reader.contents.conversations[0].id
        #expect(try await Self.texts(index, matching: "seat").count == 2)  // the fact and its exchange

        // Only a fact sweep: the fact's id is gone, and so is the record
        // that said which exchange it came from.
        reader.update { $0.facts.removeAll { $0.statement.contains("window seat") } }
        feed.enqueue(MemorySourceChanges(sweeps: [.fact]))
        try await indexer.runUntilIdle()

        #expect(try await Self.texts(index, matching: "seat").isEmpty)
        let exchange = try await index.chunks(ofSource: conversation, kind: .conversation)[0].chunk
        #expect(!exchange.keyText.contains("facts:"))
        #expect(try await index.conversations(linkedToFacts: [UUID()]).isEmpty)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func anEditedFactUpdatesItsExchangeKey() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        let fact = reader.contents.facts[0].id
        reader.update { $0.facts[0].statement = "User reserved an aisle seat" }
        // The resolver names the fact; its exchange is found through the
        // index's fact links.
        feed.enqueue(MemorySourceChanges(facts: [fact]))
        try await indexer.runUntilIdle()

        let texts = try await Self.texts(index, matching: "seat")
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.contains("aisle seat") })
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func anInvalidatedFactIsLinkedButLeftOutOfItsExchangeKey() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let conversation = reader.contents.conversations[0]
        let superseded = FactSnapshot(
            id: UUID(), statement: "User reserved an aisle seat", validFrom: Support.t0.addingTimeInterval(-60),
            invalidatedAt: Support.t0, sourceUtteranceID: conversation.utterances[0].id)
        reader.update { $0.facts.append(superseded) }
        let indexer = Fakes.indexer(index: index, reader: reader)
        try await indexer.runUntilIdle()

        let exchange = try await index.chunks(ofSource: conversation.id, kind: .conversation)[0].chunk
        #expect(exchange.keyText.contains("facts: User reserved a window seat\n"))
        #expect(!exchange.keyText.contains("aisle"))
        #expect(try await index.conversations(linkedToFacts: [superseded.id]) == [conversation.id])
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func invalidatingAFactAndUndoingItRekeysItsExchange() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()
        let conversation = reader.contents.conversations[0].id
        let fact = reader.contents.facts[0].id
        func exchangeKey() async throws -> String {
            try await index.chunks(ofSource: conversation, kind: .conversation)[0].chunk.keyText
        }
        #expect(try await exchangeKey().contains("facts: User reserved a window seat"))

        // Invalidated on another device: only the fact is reported; its
        // exchange is found through the fact link.
        reader.update { $0.facts[0].invalidatedAt = Support.t0.addingTimeInterval(86_400) }
        feed.enqueue(MemorySourceChanges(facts: [fact]))
        try await indexer.runUntilIdle()
        #expect(try await !exchangeKey().contains("facts:"))
        let factChunk = try await index.chunks(ofSource: fact, kind: .fact)[0].chunk
        #expect(factChunk.keyText.contains("window seat (until "))
        #expect(try await index.conversations(linkedToFacts: [fact]) == [conversation])
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))

        // The link kept means undoing it finds the exchange again.
        reader.update { $0.facts[0].invalidatedAt = nil }
        feed.enqueue(MemorySourceChanges(facts: [fact]))
        try await indexer.runUntilIdle()
        #expect(try await exchangeKey().contains("facts: User reserved a window seat"))
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    /// v2 (#173): invalidated facts left out of exchange keys, and the
    /// conservative token estimate.
    @Test func theChunkingFingerprintNamesTheChunkingVersion() async throws {
        let indexer = Fakes.indexer(index: try MemoryIndex.inMemory(), reader: Self.reader())
        #expect(MemoryIndexer.chunkingVersion == "v2")
        let fingerprint = await indexer.chunkingFingerprint
        #expect(fingerprint.hasPrefix("v2 max=112 min=56 overlap=1 facts=5 tz="), "\(fingerprint)")
    }

    @Test func aRenamedCollectionRekeysItsItems() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        let collection = reader.contents.documents[1]
        reader.update { $0.documents[1].title = "Demo day prep" }
        feed.enqueue(MemorySourceChanges(documents: [collection.id]))
        try await indexer.runUntilIdle()

        let item = try await index.chunks(ofSource: collection.items[0].id, kind: .collectionItem)
        #expect(item.first?.chunk.keyText.hasPrefix("[Demo day prep]") == true)
    }

    @Test func aLargeImportBecomesAFullPass() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(
            index: index, reader: reader, feed: feed,
            configuration: MemoryIndexer.Configuration(debounce: .zero, incrementalLimit: 2, retryDelay: .zero))
        try await indexer.runUntilIdle()
        let rebuiltAt = try await index.lastRebuild()

        let imported = (0..<3).map { day in
            Support.conversation(
                start: Support.t0.addingTimeInterval(Double(-day) * 86_400),
                [(.user, "Imported question \(day)"), (.agent, "Imported answer \(day)")])
        }
        reader.update { $0.conversations += imported }
        feed.enqueue(MemorySourceChanges(conversations: Set(imported.map(\.id))))
        try await indexer.runUntilIdle()

        #expect(feed.skips == 1)  // only the first build skipped history
        #expect(try await index.lastRebuild() == rebuiltAt)  // the clock didn't move
        #expect(try await Self.texts(index, matching: "Imported").count == 3)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func expiredHistoryRereadsEverything() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        // A change nobody reported, then a reset.
        reader.update { $0.documents[0].body = "Larderly now costs $199 per location." }
        feed.enqueue(MemorySourceChanges(requiresFullPass: true))
        try await indexer.runUntilIdle()

        #expect(try await Self.texts(index, matching: "199").count == 1)
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func aChunkingChangeRebuilds() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        try await Fakes.indexer(index: index, reader: reader).runUntilIdle()
        try await index.setStateValue("v0 an older chunking", forKey: MemoryIndexer.chunkingKey)

        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        try await indexer.runUntilIdle()

        #expect(try await index.stateValue(forKey: MemoryIndexer.chunkingKey) == indexer.chunkingFingerprint)
        #expect(feed.skips == 0)
        #expect(reader.conversationReads.count >= 2)
    }

    @Test func keyDatesStayInThePinnedTimeZoneWhenTheDeviceMoves() async throws {
        let index = try MemoryIndex.inMemory()
        // 23:30 UTC: January 15 in UTC, January 16 in Tokyo.
        let lateEvening = Date(timeIntervalSince1970: 1_768_519_800)
        let conversation = Support.conversation(start: lateEvening, [(.user, "Good night."), (.agent, "Sleep well.")])
        let reader = Fakes.FakeReader(Support.FakeSources(conversations: [conversation]))
        try await Fakes.indexer(index: index, reader: reader).runUntilIdle()
        #expect(try await index.stateValue(forKey: MemoryIndexer.timeZoneKey) == Support.utc.identifier)
        let built = try await Fakes.fingerprint(index)
        let reads = reader.conversationReads.count

        // Relaunched in Tokyo: no full pass, nothing re-chunked or re-embedded.
        let tokyo = MemoryChunker(
            policy: ChunkingPolicy.forSequenceLength(128, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        let embedder = Support.HashingEmbedder()
        let feed = Fakes.ScriptedFeed()
        let indexer = MemoryIndexer(
            index: index, reader: reader, feed: feed, embedder: embedder, chunker: tokyo,
            clock: ManualClock(now: Support.t0),
            configuration: MemoryIndexer.Configuration(debounce: .zero, retryDelay: .zero))
        try await indexer.runUntilIdle()
        #expect(await indexer.chunker.policy.timeZone == Support.utc)
        #expect(reader.conversationReads.count == reads)
        #expect(try await Fakes.fingerprint(index) == built)

        // A change to the conversation re-chunks it in the pinned zone, so
        // its key and vector are kept.
        feed.enqueue(MemorySourceChanges(conversations: [conversation.id]))
        try await indexer.runUntilIdle()
        #expect(reader.conversationReads.count == reads + 1)
        let chunk = try await index.chunks(ofSource: conversation.id, kind: .conversation)[0].chunk
        #expect(chunk.keyText.hasPrefix("[January 15, 2026]\n"))
        #expect(embedder.embeddedTexts.isEmpty)
        #expect(try await Fakes.fingerprint(index) == built)
    }

    @Test func anEmbedderReturningTheWrongCountIsReported() async throws {
        let index = try MemoryIndex.inMemory()
        let indexer = Fakes.indexer(
            index: index, reader: Self.reader(), embedder: MemoryIndexRebuilderTests.ShortEmbedder())
        try await indexer.runUntilIdle()

        let status = await indexer.currentStatus
        #expect(status.vectorsUnavailable?.contains("vectors for") == true)
        #expect(status.chunkCount == Self.chunkCount)
        #expect(status.vectorCount == 0)
        #expect(status.embedding == nil)
    }

    // MARK: - Embedding

    @Test func withoutAModelTheIndexIsKeywordOnlyUntilOneArrives() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let embedder = Support.HashingEmbedder()
        embedder.failure.withLock { $0 = Support.EmbeddingUnavailable() }
        let indexer = Fakes.indexer(
            index: index, reader: reader, feed: feed, embedder: embedder,
            configuration: MemoryIndexer.Configuration(debounce: .zero, embeddingBatchSize: 3, retryDelay: .zero))
        try await indexer.runUntilIdle()

        var status = await indexer.currentStatus
        #expect(status.chunkCount == Self.chunkCount)
        #expect(status.vectorCount == 0)
        #expect(status.vectorsUnavailable != nil)
        #expect(status.embedding == nil)
        #expect(try await Self.texts(index, matching: "Kotori").count == 1)

        // The model is installed; the next signal fills the vectors in,
        // newest content first.
        embedder.failure.withLock { $0 = nil }
        await indexer.signal()
        try await indexer.runUntilIdle()

        status = await indexer.currentStatus
        #expect(status.vectorCount == Self.chunkCount)
        #expect(status.vectorsUnavailable == nil)
        #expect(status.embedding == nil)
        let batches = embedder.batches.withLock { $0 }
        #expect(batches.count == 3)
        #expect(batches[0].first?.contains("Pricing") == true)  // the note, edited an hour after t0
        #expect(try await Fakes.fingerprint(index) == Fakes.referenceFingerprint(reader))
    }

    @Test func aNewModelReembedsEverything() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        try await Fakes.indexer(index: index, reader: reader).runUntilIdle()

        let newModel = Support.HashingEmbedder(version: "hashing-256d-int8@2")
        let indexer = Fakes.indexer(index: index, reader: reader, embedder: newModel)
        try await indexer.runUntilIdle()

        #expect(newModel.embeddedTexts.count == Self.chunkCount)
        let statistics = try await index.statistics(modelVersion: newModel.version)
        #expect(statistics.vectors == Self.chunkCount)
        #expect(statistics.staleVectors == 0)
    }

    @Test func reembedAllRecomputesEveryVector() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let embedder = Support.HashingEmbedder()
        let indexer = Fakes.indexer(index: index, reader: reader, embedder: embedder)
        try await indexer.runUntilIdle()
        #expect(embedder.embeddedTexts.count == Self.chunkCount)

        await indexer.requestFullPass(reembedAll: true)
        try await indexer.runUntilIdle()
        #expect(embedder.embeddedTexts.count == 2 * Self.chunkCount)

        await indexer.requestFullPass()
        try await indexer.runUntilIdle()
        #expect(embedder.embeddedTexts.count == 2 * Self.chunkCount)
    }

    // MARK: - Throttling

    @Test func criticalConditionsHoldIndexingUntilTheyEase() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let level = ManualPerformanceLevel(.minimal)
        let indexer = Fakes.indexer(
            index: index, reader: reader, gate: IndexingGate(performance: level, clock: ManualClock()))
        let run = Task { try await indexer.runUntilIdle() }

        while await indexer.currentStatus.activity != .waiting(.suspended) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await index.statistics().chunks == 0)

        level.set(.normal)
        try await run.value
        #expect(try await index.statistics().chunks == Self.chunkCount)
    }

    // MARK: - Running

    @Test func runFollowsSignalsAndReportsStatus() async throws {
        let index = try MemoryIndex.inMemory()
        let reader = Self.reader()
        let feed = Fakes.ScriptedFeed()
        let indexer = Fakes.indexer(index: index, reader: reader, feed: feed)
        let updates = await indexer.statusUpdates()
        let seen = Mutex<[MemoryIndexingStatus.Activity]>([])
        let watcher = Task {
            for await status in updates { seen.withLock { $0.append(status.activity) } }
        }
        let run = Task { await indexer.run() }

        // `waitUntilIdle` returns once the first build is done.
        while await indexer.currentStatus.activity != .idle { try await Task.sleep(for: .milliseconds(5)) }
        await indexer.waitUntilIdle()
        #expect(try await index.needsRebuild == false)

        let id = reader.contents.documents[0].id
        reader.update { $0.documents[0].body = "Larderly now costs $199 per location." }
        feed.post(MemorySourceChanges(documents: [id]))
        while try await Self.texts(index, matching: "199").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        await indexer.waitUntilIdle()

        run.cancel()
        await run.value
        watcher.cancel()
        let activities = seen.withLock { $0 }
        #expect(activities.contains(.rebuilding))
        #expect(activities.contains(.indexingChanges))
        #expect(activities.last == .idle)
    }
}
