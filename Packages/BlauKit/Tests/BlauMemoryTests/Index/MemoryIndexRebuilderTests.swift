import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Memory index rebuilder")
struct MemoryIndexRebuilderTests {
    typealias Support = IndexTestSupport

    static func sources() -> Support.FakeSources {
        let topic = ConversationSnapshot.TopicSnapshot(id: UUID(), title: "Japan trip")
        let trip = Support.conversation(
            topic: topic,
            [
                (.user, "We booked flights to Japan, landing in Tokyo on April 2nd."),
                (.agent, "Two weeks is a good length; book Kyoto hotels soon."),
                (.user, "Remember the ramen place in Osaka with yuzu shio broth?"),
                (.agent, "Menya Kotori near Namba station, it sells out by 2."),
            ])
        let collection = DocumentSnapshot(
            id: UUID(), kind: .collection, title: "YC interview", body: "", updatedAt: Support.t0,
            items: [
                DocumentSnapshot.ItemSnapshot(
                    id: UUID(), ordinal: 0, prompt: "What are you building?", referenceAnswer: "A voice app.",
                    createdAt: Support.t0),
                DocumentSnapshot.ItemSnapshot(id: UUID(), ordinal: 1, prompt: "Why now?", createdAt: Support.t0),
            ])
        let note = DocumentSnapshot(
            id: UUID(), kind: .note, title: "Pricing", body: "Larderly costs $149 per location per month.",
            updatedAt: Support.t0)
        let fact = FactSnapshot(
            id: UUID(), statement: "User lands in Tokyo on April 2", validFrom: Support.t0,
            sourceUtteranceID: trip.utterances[0].id)
        return Support.FakeSources(conversations: [trip], documents: [collection, note], facts: [fact])
    }

    static func rebuilder(
        index: MemoryIndex, sources: any MemorySourceProvider, embedder: (any MemoryChunkEmbedding)?
    ) -> MemoryIndexRebuilder {
        MemoryIndexRebuilder(
            index: index, sources: sources, chunker: Support.chunker, embedder: embedder,
            clock: ManualClock(now: Support.t0), conversationBatchSize: 1, writeBatchSize: 3)
    }

    @Test func rebuildIndexesEverySourceWithVectors() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        let sources = Self.sources()
        let report = try await Self.rebuilder(index: index, sources: sources, embedder: embedder).rebuild()

        #expect(report.sources == [.conversation: 1, .document: 2, .collectionItem: 2, .fact: 1])
        // 2 exchanges, the note, the body-less collection (its title), 2 items, 1 fact.
        #expect(report.chunks == 2 + 1 + 1 + 2 + 1)
        #expect(report.embedded == report.chunks)
        #expect(report.reusedVectors == 0)
        #expect(report.modelVersion == embedder.version)
        #expect(report.embeddingFailure == nil)
        #expect(try await index.needsRebuild == false)
        #expect(try await index.lastRebuild() == Support.t0)

        let statistics = try await index.statistics(modelVersion: embedder.version)
        #expect(statistics.chunks == 7)
        #expect(statistics.vectors == 7)

        // The fact augments the exchange it came from.
        let trip = try await sources.conversations(sources.conversationIDs())[0]
        let exchange = try await index.chunks(ofSource: trip.id, kind: .conversation)[0].chunk
        #expect(exchange.keyText.hasPrefix("[January 15, 2026] [Japan trip] facts: User lands in Tokyo on April 2\n"))

        let hits = try await index.keywordSearch("ramen Osaka", limit: 3)
        let found = try await index.chunks(withIDs: hits.map(\.chunkID))
        #expect(found.first?.text.contains("Menya Kotori") == true)
        let vectorHits = try await index.vectorSearch(embedder.embed("location per month pricing"), limit: 1)
        #expect(try await index.chunks(withIDs: vectorHits.map(\.chunkID)).first?.text.contains("$149") == true)
    }

    @Test func aSecondRebuildReusesEveryVectorAndOnlyEmbedsWhatChanged() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        let sources = Self.sources()
        let rebuilder = Self.rebuilder(index: index, sources: sources, embedder: embedder)
        try await rebuilder.rebuild()
        let before = embedder.embeddedTexts.count

        let unchanged = try await rebuilder.rebuild()
        #expect(unchanged.embedded == 0)
        #expect(unchanged.reusedVectors == unchanged.chunks)
        #expect(embedder.embeddedTexts.count == before)

        // Edit the note, delete a collection item, add a fact.
        sources.update { contents in
            contents.documents[1].body = "Larderly now costs $199 per location per month."
            contents.documents[0].items.removeLast()
            contents.facts.append(FactSnapshot(id: UUID(), statement: "User likes ramen", validFrom: Support.t0))
        }
        let changed = try await rebuilder.rebuild()
        #expect(changed.embedded == 2)
        #expect(embedder.embeddedTexts.suffix(2).contains { $0.contains("$199") })
        #expect(changed.removedSources == 1)
        #expect(try await index.statistics().chunksByKind[.collectionItem] == 1)
        #expect(try await index.keywordSearch("199", limit: 1).count == 1)
        #expect(try await index.keywordSearch("149", limit: 1).isEmpty)

        // A forced rebuild embeds everything again.
        let forced = try await rebuilder.rebuild(reembedAll: true)
        #expect(forced.embedded == forced.chunks)
    }

    @Test func aNewModelVersionReembedsEverything() async throws {
        let index = try MemoryIndex.inMemory()
        let sources = Self.sources()
        try await Self.rebuilder(index: index, sources: sources, embedder: Support.HashingEmbedder()).rebuild()
        let newer = Support.HashingEmbedder(version: "hashing-256d-int8@2")
        let report = try await Self.rebuilder(index: index, sources: sources, embedder: newer).rebuild()
        #expect(report.embedded == report.chunks)
        #expect(try await index.statistics(modelVersion: newer.version).vectors == report.chunks)
    }

    @Test func withoutAModelTheIndexIsKeywordOnlyUntilVectorsAreFilledIn() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        embedder.failure.withLock { $0 = Support.EmbeddingUnavailable() }
        let rebuilder = Self.rebuilder(index: index, sources: Self.sources(), embedder: embedder)
        let report = try await rebuilder.rebuild()
        #expect(report.modelVersion == nil)
        #expect(report.embeddingFailure != nil)
        #expect(report.embedded == 0)
        #expect(try await index.keywordSearch("Kyoto hotels", limit: 1).count == 1)
        #expect(try await index.needsRebuild == false)

        embedder.failure.withLock { $0 = nil }
        let filled = try await rebuilder.embedMissingVectors(batchSize: 4)
        #expect(filled == report.chunks)
        #expect(try await index.statistics(modelVersion: embedder.version).vectors == report.chunks)
        #expect(try await rebuilder.embedMissingVectors() == 0)

        let noEmbedder = Self.rebuilder(index: index, sources: Self.sources(), embedder: nil)
        #expect(try await noEmbedder.embedMissingVectors() == 0)
    }

    @Test func aFailureMidRebuildFallsBackToKeywordsWithoutLosingTheIndex() async throws {
        final class FlakyEmbedder: MemoryChunkEmbedding {
            let base = IndexTestSupport.HashingEmbedder()
            func currentModelVersion() async throws -> String { base.version }
            func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
                throw IndexTestSupport.EmbeddingUnavailable()
            }
        }
        let index = try MemoryIndex.inMemory()
        let report = try await Self.rebuilder(index: index, sources: Self.sources(), embedder: FlakyEmbedder())
            .rebuild()
        #expect(report.embeddingFailure != nil)
        #expect(report.modelVersion == nil)
        #expect(try await index.statistics().chunks == report.chunks)
    }

    @Test func cancellationKeepsTheWorkDoneAndLeavesTheIndexMarkedForRebuild() async throws {
        let index = try MemoryIndex.inMemory()
        let sources = Self.sources()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.rebuilder(index: index, sources: sources, embedder: Support.HashingEmbedder())
                .rebuild()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await index.needsRebuild)
    }
}

/// The acceptance criterion "Index fully rebuildable from SwiftData": the
/// index is built from a real (in-memory) SwiftData store, deleted, and
/// rebuilt to the same chunks, the same vectors and the same search results.
@Suite("Memory index rebuilt from SwiftData")
struct SwiftDataRebuildTests {
    typealias Support = IndexTestSupport

    @MainActor
    static func populate(_ container: ModelContainer) throws -> (conversation: UUID, document: UUID) {
        let context = container.mainContext
        let conversation = Conversation(startedAt: Support.t0, endedAt: Support.t0.addingTimeInterval(600))
        context.insert(conversation)
        let topic = Topic(
            conversation: conversation, startedAt: Support.t0, title: "Fundraising", titleIsProvisional: false)
        context.insert(topic)
        let turns: [(UtteranceRole, String)] = [
            (.user, "We closed the seed round with Sequoia leading."),
            (.agent, "Congratulations! How much did you raise?"),
            (.user, "Two million dollars at a twelve million cap."),
            (.agent, "That gives you about eighteen months of runway."),
        ]
        var firstUtterance: UUID?
        for (index, turn) in turns.enumerated() {
            let utterance = StoredUtterance(
                conversation: conversation, topic: topic, role: turn.0, text: turn.1,
                startedAt: Support.t0.addingTimeInterval(Double(index) * 20), isFinal: true,
                source: turn.0 == .user ? .parakeet : .grok)
            context.insert(utterance)
            firstUtterance = firstUtterance ?? utterance.id
        }
        // A streaming partial is never indexed.
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "unfinished partial",
                startedAt: Support.t0.addingTimeInterval(90),
                isFinal: false, source: .parakeet))

        let document = MemoryDocument(
            kind: .company, title: "Larderly",
            body:
                "# Product\nInventory and food-cost app for independent restaurants.\n\n# Pricing\n$149 per location.",
            createdAt: Support.t0)
        context.insert(document)
        let collection = MemoryDocument(kind: .collection, title: "YC interview", createdAt: Support.t0)
        context.insert(collection)
        context.insert(
            CollectionItem(
                document: collection, ordinal: 0, prompt: "What are you building?",
                referenceAnswer: "Inventory software restaurants love.", createdAt: Support.t0))

        let acme = MemoryEntity(name: "Sequoia", type: .organization, createdAt: Support.t0)
        context.insert(acme)
        context.insert(
            Fact(
                subject: acme, predicate: "led", objectText: "the seed round", sourceUtteranceID: firstUtterance,
                validFrom: Support.t0, origin: .extracted))
        context.insert(Fact(predicate: "lives in", objectText: "Austin", validFrom: Support.t0, origin: .user))
        try context.save()
        return (conversation.id, document.id)
    }

    /// Every chunk in the index, comparable across rebuilds.
    static func snapshot(of index: MemoryIndex, sources: SwiftDataMemorySources) async throws -> [MemoryChunk] {
        var chunks: [MemoryChunk] = []
        for kind in MemorySourceKind.allCases {
            for sourceID in try await index.sourceIDs(kind: kind).sorted(by: { $0.uuidString < $1.uuidString }) {
                chunks += try await index.chunks(ofSource: sourceID, kind: kind).map(\.chunk)
            }
        }
        return chunks
    }

    @Test func theIndexIsFullyRebuildableFromSwiftData() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let ids = try await Self.populate(container)
        let sources = SwiftDataMemorySources(container: container)
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = StoreLocation(directory: directory).memoryIndexURL
        let embedder = Support.HashingEmbedder()
        let query = embedder.embed("how much did we raise in the seed round")

        // Build.
        let first:
            (
                chunks: [MemoryChunk], keyword: [MemoryIndexHit], vector: [MemoryIndexHit],
                report: MemoryIndexRebuilder.Report
            )
        do {
            let index = try MemoryIndex.open(at: url)
            #expect(try await index.needsRebuild)
            let report = try await MemoryIndexRebuilder(
                index: index, sources: sources, chunker: Support.chunker, embedder: embedder
            ).rebuild()
            first = (
                try await Self.snapshot(of: index, sources: sources),
                try await index.keywordSearch("seed round Sequoia", limit: 5),
                try await index.vectorSearch(query, limit: 5), report
            )
        }
        #expect(first.report.sources == [.conversation: 1, .document: 2, .collectionItem: 1, .fact: 2])
        #expect(first.chunks.count == first.report.chunks)
        #expect(!first.chunks.contains { $0.keyText.contains("unfinished partial") })
        let exchanges = first.chunks.filter { $0.sourceKind == .conversation }
        #expect(exchanges.count == 2)
        #expect(exchanges[0].keyText.hasPrefix("[January 15, 2026] [Fundraising] facts: Sequoia led the seed round\n"))
        #expect(exchanges.allSatisfy { $0.conversationID == ids.conversation })
        // Both short sections of the company page fit in one chunk.
        #expect(
            first.chunks.filter { $0.sourceID == ids.document }.map(\.keyText) == [
                "[Larderly] [Product]\n# Product\nInventory and food-cost app for independent restaurants.\n\n"
                    + "# Pricing\n$149 per location."
            ])
        #expect(first.chunks.contains { $0.sourceKind == .fact && $0.text == "User lives in Austin" })
        #expect(!first.keyword.isEmpty)
        #expect(!first.vector.isEmpty)

        // Delete the index entirely and rebuild it from SwiftData.
        try MemoryIndex.removeFiles(at: url)
        let rebuilt = try MemoryIndex.open(at: url)
        #expect(try await rebuilt.needsRebuild)
        let report = try await MemoryIndexRebuilder(
            index: rebuilt, sources: sources, chunker: Support.chunker, embedder: embedder
        ).rebuild()
        #expect(report.chunks == first.report.chunks)
        #expect(report.embedded == first.report.embedded)
        #expect(try await Self.snapshot(of: rebuilt, sources: sources) == first.chunks)
        #expect(try await rebuilt.keywordSearch("seed round Sequoia", limit: 5) == first.keyword)
        #expect(try await rebuilt.vectorSearch(query, limit: 5) == first.vector)
        #expect(try await rebuilt.statistics(modelVersion: embedder.version).vectors == report.chunks)

        // Deleting from SwiftData removes it from the index on the next rebuild.
        try await MainActor.run {
            let context = container.mainContext
            let document = try context.fetch(FetchDescriptor<MemoryDocument>()).first { $0.id == ids.document }
            context.delete(try #require(document))
            try context.save()
        }
        let afterDelete = try await MemoryIndexRebuilder(
            index: rebuilt, sources: sources, chunker: Support.chunker, embedder: embedder
        ).rebuild()
        #expect(afterDelete.removedSources == 1)
        #expect(afterDelete.embedded == 0)
        #expect(try await rebuilt.sourceIDs(kind: .document).contains(ids.document) == false)
    }

    @Test func duplicateRecordsFromTwoDevicesAreMergedOnRead() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let conversationID = UUID()
        let shared = UUID()
        try await MainActor.run {
            let context = container.mainContext
            let a = Conversation(id: conversationID, startedAt: Support.t0)
            let b = Conversation(id: conversationID, startedAt: Support.t0.addingTimeInterval(-5))
            context.insert(a)
            context.insert(b)
            context.insert(
                StoredUtterance(
                    id: shared, conversation: a, role: .user, text: "Same utterance.", startedAt: Support.t0,
                    isFinal: true, source: .parakeet))
            context.insert(
                StoredUtterance(
                    id: shared, conversation: b, role: .user, text: "Same utterance.", startedAt: Support.t0,
                    isFinal: true, source: .parakeet))
            context.insert(
                StoredUtterance(
                    conversation: b, role: .agent, text: "Reply from the other device.",
                    startedAt: Support.t0.addingTimeInterval(5),
                    isFinal: true, source: .grok))
            let documentID = UUID()
            context.insert(
                MemoryDocument(id: documentID, kind: .note, title: "Old", body: "old text", createdAt: Support.t0))
            context.insert(
                MemoryDocument(
                    id: documentID, kind: .note, title: "New", body: "new text", createdAt: Support.t0,
                    updatedAt: Support.t0.addingTimeInterval(60)))
            let factID = UUID()
            context.insert(
                Fact(id: factID, predicate: "uses", objectText: "Linear", validFrom: Support.t0, origin: .user))
            context.insert(
                Fact(
                    id: factID, predicate: "uses", objectText: "Linear", validFrom: Support.t0,
                    invalidatedAt: Support.t0.addingTimeInterval(100), origin: .user))
            try context.save()
        }
        let sources = SwiftDataMemorySources(container: container)
        #expect(try await sources.conversationIDs() == [conversationID])
        let conversation = try #require(try await sources.conversations([conversationID]).first)
        #expect(conversation.utterances.count == 2)
        #expect(conversation.startedAt == Support.t0.addingTimeInterval(-5))
        #expect(
            MemoryChunker.exchanges(in: conversation).map(\.text) == [
                "User: Same utterance.\nBlau: Reply from the other device."
            ])
        let documents = try await sources.documents()
        #expect(documents.map(\.title) == ["New"])
        let facts = try await sources.facts()
        #expect(facts.count == 1)
        #expect(facts[0].invalidatedAt == Support.t0.addingTimeInterval(100))
        #expect(facts[0].statement == "User uses Linear")
    }
}
