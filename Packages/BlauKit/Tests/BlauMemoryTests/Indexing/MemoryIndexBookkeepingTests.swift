import BlauCore
import BlauPersistence
import Foundation
import GRDB
import Testing

@testable import BlauMemory

/// What `MemoryIndex` keeps for the incremental indexer (#63): fact links,
/// bookkeeping values and newest-first re-embedding.
@Suite("Memory index bookkeeping")
struct MemoryIndexBookkeepingTests {
    typealias Support = IndexTestSupport

    @Test func factLinksFollowTheirConversation() async throws {
        let index = try MemoryIndex.inMemory()
        let conversation = Support.conversation([(.user, "We raised a seed round"), (.agent, "Congratulations")])
        let chunks = Support.chunker.chunks(for: conversation)
        let first = UUID()
        let second = UUID()

        try await index.replace([
            .init(kind: .conversation, sourceID: conversation.id, chunks: chunks, linkedFactIDs: [first, second])
        ])
        #expect(try await index.conversations(linkedToFacts: [first]) == [conversation.id])
        #expect(try await index.conversations(linkedToFacts: [UUID()]).isEmpty)

        // `nil` keeps them; a new set replaces them.
        try await index.replace([.init(kind: .conversation, sourceID: conversation.id, chunks: chunks)])
        #expect(try await index.conversations(linkedToFacts: [second]) == [conversation.id])
        try await index.replace([
            .init(kind: .conversation, sourceID: conversation.id, chunks: chunks, linkedFactIDs: [second])
        ])
        #expect(try await index.conversations(linkedToFacts: [first]).isEmpty)

        // Removing the conversation forgets them.
        try await index.removeSources([conversation.id], kind: .conversation)
        #expect(try await index.conversations(linkedToFacts: [second]).isEmpty)
    }

    @Test func stateValuesRoundTripAndAreClearedWithTheIndex() async throws {
        let index = try MemoryIndex.inMemory()
        #expect(try await index.stateValue(forKey: "indexer.test") == nil)
        try await index.setStateValue("42", forKey: "indexer.test")
        #expect(try await index.stateValue(forKey: "indexer.test") == "42")
        try await index.setStateValue(nil, forKey: "indexer.test")
        #expect(try await index.stateValue(forKey: "indexer.test") == nil)

        try await index.setStateValue("x", forKey: "indexer.test")
        try await index.markRebuilt(at: Support.t0)
        #expect(try await index.lastRebuild() == Support.t0)
        try await index.removeAll()
        #expect(try await index.stateValue(forKey: "indexer.test") == nil)
    }

    @Test func chunksNeedingEmbeddingCanComeNewestFirst() async throws {
        let index = try MemoryIndex.inMemory()
        let facts = (0..<3).map { day in
            FactSnapshot(
                id: UUID(), statement: "Fact from day \(day)",
                validFrom: Support.t0.addingTimeInterval(Double(day) * 86_400))
        }
        // Written oldest last, so row order and date order differ.
        try await index.replace(
            facts.reversed().map { .init(kind: .fact, sourceID: $0.id, chunks: [Support.chunker.chunk(for: $0)!]) })

        let byRow = try await index.chunksNeedingEmbedding(modelVersion: "m", limit: 3)
        let newest = try await index.chunksNeedingEmbedding(modelVersion: "m", limit: 3, newestFirst: true)
        #expect(byRow.map(\.sourceID) == facts.reversed().map(\.id))
        #expect(
            newest.map(\.sourceID)
                == facts.reversed().map(\.id).sorted { a, b in
                    facts.first { $0.id == a }!.validFrom > facts.first { $0.id == b }!.validFrom
                })
        #expect(newest.first?.sourceID == facts[2].id)
    }

    @Test func aVersionOneIndexIsRecreated() async throws {
        let directory = try Support.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MemoryIndex.fileName)
        do {
            let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE chunk (id TEXT); PRAGMA user_version = 1")
            }
        }
        let index = try MemoryIndex.open(at: url)
        #expect(try await index.needsRebuild)
        #expect(try await index.conversations(linkedToFacts: [UUID()]).isEmpty)
    }
}
