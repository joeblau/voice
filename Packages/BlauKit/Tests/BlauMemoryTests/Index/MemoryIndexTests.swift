import BlauPersistence
import Foundation
import GRDB
import Testing

@testable import BlauMemory

@Suite("Memory index")
struct MemoryIndexTests {
    typealias Support = IndexTestSupport

    static func chunk(
        _ keyText: String, source: UUID = UUID(), kind: MemorySourceKind = .document, ordinal: Int = 0,
        at date: Date = IndexTestSupport.t0
    ) -> MemoryChunk {
        MemoryChunk(
            sourceID: source, sourceKind: kind, ordinal: ordinal, text: keyText, keyText: keyText, createdAt: date)
    }

    static func source(_ chunks: [MemoryChunk]) -> MemoryIndex.SourceChunks {
        MemoryIndex.SourceChunks(kind: chunks[0].sourceKind, sourceID: chunks[0].sourceID, chunks: chunks)
    }

    @Test func chunksRoundTripWithEveryField() async throws {
        let index = try MemoryIndex.inMemory()
        let conversation = UUID()
        let topic = UUID()
        let chunk = MemoryChunk(
            sourceID: conversation, sourceKind: .conversation, ordinal: 2, text: "User: hi",
            keyText: "[date]\nUser: hi",
            createdAt: Support.t0.addingTimeInterval(0.25), topicID: topic, conversationID: conversation)
        let summary = try await index.replace([Self.source([chunk])])
        #expect(summary.inserted == 1)

        #expect(try await index.chunks(withIDs: [chunk.id, UUID()]) == [chunk])
        let stored = try await index.chunks(ofSource: conversation, kind: .conversation)
        #expect(stored.map(\.chunk) == [chunk])
        #expect(stored[0].modelVersion == nil)
        #expect(try await index.sourceIDs(kind: .conversation) == [conversation])
        #expect(try await index.sourceIDs(kind: .document).isEmpty)
    }

    @Test func keywordSearchRanksByBM25WithStemming() async throws {
        let index = try MemoryIndex.inMemory()
        let running = Self.chunk("I started running in March and ran a half marathon in June.")
        let ramen = Self.chunk("Menya Kotori near Namba station serves yuzu shio ramen and sells out by 2.")
        let pricing = Self.chunk("Larderly costs 149 dollars per location per month.")
        try await index.replace([running, ramen, pricing].map { Self.source([$0]) })

        let hits = try await index.keywordSearch("When did I start runs?", limit: 10)
        #expect(hits.first?.chunkID == running.id)  // "start" and "runs" stem to "start" and "run"
        #expect(try await index.keywordSearch("ramen place in Osaka", limit: 10).map(\.chunkID) == [ramen.id])
        #expect(try await index.keywordSearch("how much per location", limit: 10).map(\.chunkID) == [pricing.id])
        #expect(try await index.keywordSearch("Cafe", limit: 10).isEmpty)
        #expect(try await index.keywordSearch("?!", limit: 10).isEmpty)
        #expect(try await index.keywordSearch("ramen", limit: 0).isEmpty)
        #expect(hits.allSatisfy { $0.score > 0 })
    }

    @Test func moreMatchingRareWordsRankHigher() async throws {
        let index = try MemoryIndex.inMemory()
        let both = Self.chunk("The seed round closed with Sequoia leading.")
        let one = Self.chunk("Sequoia called about something else entirely.")
        let filler = (0..<20).map { Self.chunk("Nothing relevant in note \($0) about weather and lunch.") }
        try await index.replace(([both, one] + filler).map { Self.source([$0]) })
        let hits = try await index.keywordSearch("seed round Sequoia", limit: 5)
        #expect(hits.map(\.chunkID) == [both.id, one.id])
        #expect(hits[0].score > hits[1].score)
    }

    @Test func commonWordsOnlyCountWhenNothingRarerIsAsked() async throws {
        let index = try MemoryIndex.inMemory()
        let cutoff = MemoryIndex.commonTermDocuments(chunkCount: 0)
        #expect(cutoff == 256)
        #expect(MemoryIndex.commonTermDocuments(chunkCount: 200_000) == 1_000)
        // "meeting" is in more chunks than the cutoff; "Lisbon" in three.
        let filler = (0..<(cutoff + 20)).map { Self.chunk("Weekly meeting notes number \($0) about planning.") }
        let lisbon = [
            Self.chunk("Offsite meeting in Lisbon with the whole team."),
            Self.chunk("Lisbon hotels are booked."),
            Self.chunk("Flights to Lisbon land at noon."),
        ]
        let both = Self.chunk("Planning meeting agenda for the quarterly offsite review.")
        try await index.replace((filler + lisbon + [both]).map { Self.source([$0]) })

        // The rare word decides which chunks match; the common one is left out.
        let rare = try await index.keywordSearch("meeting in Lisbon", limit: 10)
        #expect(Set(rare.map(\.chunkID)) == Set(lisbon.map(\.id)))

        // Only common words: chunks with all of them.
        let common = try await index.keywordSearch("planning meeting agenda", limit: 10)
        #expect(common.first?.chunkID == both.id)
        let allCommon = try await index.keywordSearch("meeting planning", limit: 400)
        #expect(allCommon.count == filler.count + 1)

        // A word that isn't in the index matches nothing, and is ignored next to one that is.
        #expect(try await index.keywordSearch("zanzibar", limit: 10).isEmpty)
        #expect(try await index.keywordSearch("zanzibar Lisbon", limit: 10).count == 3)
    }

    @Test func keywordSearchTreatsTheQueryAsPlainText() async throws {
        let index = try MemoryIndex.inMemory()
        let chunk = Self.chunk("Rock and roll, near the \"old\" pier: not open.")
        try await index.replace([Self.source([chunk])])
        for query in ["AND", "NEAR(", "\"unbalanced", "old* OR", "pier NOT open", "^rock", "keyText: pier", "-pier"] {
            let hits = try await index.keywordSearch(query, limit: 5)
            #expect(hits.allSatisfy { $0.chunkID == chunk.id }, "\(query)")
        }
        #expect(try await index.keywordSearch("pier NOT open", limit: 5).map(\.chunkID) == [chunk.id])
    }

    @Test func keywordSearchFilters() async throws {
        let index = try MemoryIndex.inMemory()
        let day: TimeInterval = 86_400
        let old = Self.chunk("Budget review for marketing", kind: .document, at: Support.t0)
        let recent = Self.chunk("Budget review again", kind: .fact, at: Support.t0.addingTimeInterval(10 * day))
        try await index.replace([Self.source([old]), Self.source([recent])])
        let facts = try await index.keywordSearch("budget", limit: 10, filter: MemorySearchFilter(kinds: [.fact]))
        #expect(facts.map(\.chunkID) == [recent.id])
        let window = MemorySearchFilter(createdAt: Support.t0..<Support.t0.addingTimeInterval(day))
        #expect(try await index.keywordSearch("budget", limit: 10, filter: window).map(\.chunkID) == [old.id])
        #expect(try await index.keywordSearch("budget", limit: 10, filter: MemorySearchFilter(kinds: [])).isEmpty)
    }

    @Test func filteredSearchesFindCommonWordsWhenTheRareOneIsOutsideTheFilter() async throws {
        let index = try MemoryIndex.inMemory()
        let day: TimeInterval = 86_400
        let cutoff = MemoryIndex.commonTermDocuments(chunkCount: 0)
        // "fundraising" and "update" are common; "Sequoia" is rare, and only
        // in an old document.
        let updates = (0..<(cutoff + 44)).map { Self.chunk("Fundraising update number \($0) for the board.") }
        let sequoia = Self.chunk("Sequoia partner meeting recap.")
        let closed = Self.chunk(
            "Fundraising closed with the new lead.", kind: .fact, at: Support.t0.addingTimeInterval(30 * day))
        try await index.replace((updates + [sequoia, closed]).map { Self.source([$0]) })

        // Unfiltered, the rare word alone decides which chunks match.
        #expect(try await index.keywordSearch("Sequoia fundraising", limit: 10).map(\.chunkID) == [sequoia.id])

        // Filtered to where "Sequoia" isn't, the common word still matches.
        let window = MemorySearchFilter(
            createdAt: Support.t0.addingTimeInterval(29 * day)..<Support.t0.addingTimeInterval(31 * day))
        let facts = MemorySearchFilter(kinds: [.fact])
        for filter in [window, facts] {
            #expect(
                try await index.keywordSearch("fundraising", limit: 10, filter: filter).map(\.chunkID) == [closed.id])
            #expect(
                try await index.keywordSearch("Sequoia fundraising", limit: 10, filter: filter).map(\.chunkID)
                    == [closed.id])
            // Only common words, not all of them in the filtered chunk.
            #expect(
                try await index.keywordSearch("fundraising update", limit: 10, filter: filter).map(\.chunkID)
                    == [closed.id])
            #expect(try await index.keywordSearch("Sequoia zanzibar", limit: 10, filter: filter).isEmpty)
        }

        // When the rare word fills the limit inside the filter, it still decides.
        let documents = MemorySearchFilter(kinds: [.document])
        #expect(
            try await index.keywordSearch("Sequoia fundraising", limit: 1, filter: documents).map(\.chunkID)
                == [sequoia.id])
        // Short of the limit, chunks with the common word follow the rare one.
        let more = try await index.keywordSearch("Sequoia fundraising", limit: 5, filter: documents)
        #expect(more.count == 5)
        #expect(more.first?.chunkID == sequoia.id)
    }

    @Test func replacingASourceKeepsVectorsOfUnchangedChunksOnly() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        let source = UUID()
        let first = [
            Self.chunk("alpha one", source: source, ordinal: 0), Self.chunk("beta two", source: source, ordinal: 1),
        ]
        let vectors = Dictionary(uniqueKeysWithValues: first.map { ($0.id, embedder.embed($0.keyText)) })
        let initial = try await index.replace([Self.source(first)], embeddings: vectors)
        #expect(initial.inserted == 2 && initial.newVectors == 2)

        // Same first chunk, changed second chunk, new third chunk.
        let second = [
            Self.chunk("alpha one", source: source, ordinal: 0), Self.chunk("beta changed", source: source, ordinal: 1),
            Self.chunk("gamma three", source: source, ordinal: 2),
        ]
        let summary = try await index.replace([Self.source(second)])
        #expect(summary.updated == 2)
        #expect(summary.inserted == 1)
        #expect(summary.keptVectors == 1)
        #expect(summary.newVectors == 0)
        let stored = try await index.chunks(ofSource: source, kind: .document)
        #expect(stored.map(\.modelVersion) == [embedder.version, nil, nil])
        #expect(try await index.keywordSearch("changed", limit: 5).map(\.chunkID) == [second[1].id])
        #expect(try await index.keywordSearch("two", limit: 5).isEmpty)  // the FTS row was replaced

        // Shrinking the source removes the extra chunks.
        let removed = try await index.replace([Self.source([second[0]])])
        #expect(removed.removed == 2)
        #expect(try await index.chunks(ofSource: source, kind: .document).map(\.chunk.id) == [second[0].id])
        #expect(try await index.keywordSearch("gamma", limit: 5).isEmpty)
        #expect(try await index.removeSources([source], kind: .document) == 1)
        #expect(try await index.statistics().chunks == 0)
    }

    @Test func vectorSearchUsesTheMatrixAndFollowsWrites() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        let texts = [
            "japan trip cherry blossom kyoto", "seed round sequoia term sheet", "marathon training tempo runs",
        ]
        let chunks = texts.map { Self.chunk($0) }
        try await index.replace(
            chunks.map { Self.source([$0]) },
            embeddings: Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, embedder.embed($0.keyText)) }))

        let query = embedder.embed("kyoto cherry blossom")
        let hits = try await index.vectorSearch(query, limit: 2)
        #expect(hits.first?.chunkID == chunks[0].id)
        #expect(try await index.statistics(modelVersion: embedder.version).matrixRows == 3)

        // A write after the matrix is loaded updates it.
        let added = Self.chunk("kyoto cherry blossom hotels")
        try await index.replace([Self.source([added])], embeddings: [added.id: embedder.embed(added.keyText)])
        #expect(try await index.statistics().matrixRows == 4)
        try await index.removeSources([chunks[0].sourceID], kind: .document)
        let after = try await index.vectorSearch(query, limit: 4)
        #expect(after.first?.chunkID == added.id)
        #expect(!after.contains { $0.chunkID == chunks[0].id })

        // Re-chunking without a vector drops the row from the matrix.
        try await index.replace([Self.source([Self.chunk("totally different text", source: added.sourceID)])])
        #expect(try await index.statistics().matrixRows == 2)

        // Vectors of another model are never compared with the query.
        let other = Support.HashingEmbedder(version: "other@2")
        #expect(try await index.vectorSearch(other.embed("kyoto cherry blossom"), limit: 4).isEmpty)
        #expect(try await index.statistics().matrixModelVersion == "other@2")

        // A zero query finds nothing.
        #expect(try await index.vectorSearch(embedder.embed(""), limit: 4).isEmpty)

        try await index.removeAll()
        #expect(try await index.statistics().chunks == 0)
        #expect(try await index.vectorSearch(query, limit: 4).isEmpty)
    }

    @Test func setEmbeddingsOnlyStoresVectorsForUnchangedKeys() async throws {
        let index = try MemoryIndex.inMemory()
        let embedder = Support.HashingEmbedder()
        let chunks = [Self.chunk("first text"), Self.chunk("second text")]
        try await index.replace(chunks.map { Self.source([$0]) })
        #expect(try await index.chunksNeedingEmbedding(modelVersion: embedder.version, limit: 10).count == 2)
        try await index.loadVectors(modelVersion: embedder.version)

        let stored = try await index.setEmbeddings([
            (chunks[0].id, chunks[0].contentHash, embedder.embed(chunks[0].keyText)),
            (chunks[1].id, "stale-hash", embedder.embed(chunks[1].keyText)),
        ])
        #expect(stored == 1)
        #expect(
            try await index.chunksNeedingEmbedding(modelVersion: embedder.version, limit: 10).map(\.id) == [
                chunks[1].id
            ])
        #expect(try await index.chunksNeedingEmbedding(modelVersion: "newer@3", limit: 10).count == 2)
        #expect(try await index.vectorStates(of: chunks.map(\.id)).keys.sorted() == [chunks[0].id])
        let statistics = try await index.statistics(modelVersion: embedder.version)
        #expect(statistics.vectors == 1)
        #expect(statistics.staleVectors == 0)
        #expect(statistics.matrixRows == 1)
        #expect(statistics.chunksByKind == [.document: 2])
        #expect(try await index.statistics(modelVersion: "newer@3").staleVectors == 1)
    }

    @Test func rebuildBookkeeping() async throws {
        let index = try MemoryIndex.inMemory()
        #expect(try await index.needsRebuild)
        try await index.markRebuilt(at: Support.t0)
        #expect(try await index.lastRebuild() == Support.t0)
        #expect(try await index.needsRebuild == false)
        try await index.removeAll()
        #expect(try await index.needsRebuild)
    }

    // MARK: - On disk

    @Test func theIndexPersistsAcrossOpens() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Derived/\(MemoryIndex.fileName)")
        let embedder = Support.HashingEmbedder()
        let chunk = Self.chunk("persisted chunk about kyoto")
        do {
            let index = try MemoryIndex.open(at: url)
            try await index.replace([Self.source([chunk])], embeddings: [chunk.id: embedder.embed(chunk.keyText)])
            try await index.markRebuilt(at: Support.t0)
        }
        let reopened = try MemoryIndex.open(at: url)
        #expect(try await reopened.needsRebuild == false)
        #expect(try await reopened.keywordSearch("kyoto", limit: 1).map(\.chunkID) == [chunk.id])
        let matrix = try await reopened.loadVectors(modelVersion: embedder.version)
        #expect(matrix.count == 1)
        #expect(try await reopened.vectorSearch(embedder.embed("kyoto"), limit: 1).map(\.chunkID) == [chunk.id])
        let excluded = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)
    }

    @Test func aCorruptFileIsReplacedByAnEmptyIndex() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MemoryIndex.fileName)
        try Data("this is not a database".utf8).write(to: url)
        let index = try MemoryIndex.open(at: url)
        #expect(try await index.needsRebuild)
        #expect(try await index.statistics().chunks == 0)
        try await index.replace([Self.source([Self.chunk("works again")])])
        #expect(try await index.keywordSearch("works", limit: 1).count == 1)
    }

    @Test func anIndexFromAnotherSchemaVersionIsRecreated() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MemoryIndex.fileName)
        do {
            let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE chunk (id TEXT); PRAGMA user_version = 99")
            }
        }
        let index = try MemoryIndex.open(at: url)
        #expect(try await index.needsRebuild)
        try await index.replace([Self.source([Self.chunk("fresh schema")])])
        #expect(try await index.keywordSearch("fresh", limit: 1).count == 1)
        #expect(StoreLocation(directory: directory).memoryIndexURL.lastPathComponent == MemoryIndex.fileName)
        #expect(
            StoreLocation(directory: directory).memoryIndexURL.deletingLastPathComponent().lastPathComponent
                == "Derived")
    }

    @Test func searchesRunWhileWriting() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try MemoryIndex.open(at: directory.appending(path: MemoryIndex.fileName))
        let embedder = Support.HashingEmbedder()
        let query = embedder.embed("word0 word1")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for batch in 0..<20 {
                    let chunks = (0..<25).map { Self.chunk("word\($0) batch\(batch)", ordinal: 0) }
                    try await index.replace(
                        chunks.map { Self.source([$0]) },
                        embeddings: Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, embedder.embed($0.keyText)) })
                    )
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    _ = try await index.keywordSearch("word1", limit: 5)
                    _ = try await index.vectorSearch(query, limit: 5)
                }
            }
            try await group.waitForAll()
        }
        let statistics = try await index.statistics(modelVersion: embedder.version)
        #expect(statistics.chunks == 500)
        #expect(statistics.vectors == 500)
        #expect(statistics.matrixRows == 500)
    }
}
