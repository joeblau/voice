import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

/// The knowledge base UI's edits (#65) re-index on their own: every write
/// `KnowledgeBaseStore` makes reaches the running incremental indexer (#63)
/// through the store's history and remote-change notification, with nobody
/// calling it, and the index ends up exactly as a from-scratch rebuild.
///
/// The same path carries edits CloudKit imports from the user's other
/// devices (`SwiftDataIncrementalIndexingTests`).
@Suite("Knowledge base edits re-index", .serialized, .timeLimit(.minutes(2)))
struct KnowledgeBaseIndexingTests {
    typealias Support = IndexTestSupport

    final class Fixture: Sendable {
        let directory: URL
        let location: StoreLocation
        let container: ModelContainer
        let derived: ModelContainer
        let index: MemoryIndex
        let store: KnowledgeBaseStore

        init() throws {
            directory = try Support.temporaryDirectory()
            location = StoreLocation(directory: directory)
            try location.prepare()
            container = try BlauModelContainer.makeLocal(url: location.syncedStoreURL)
            derived = try DerivedStore.open(at: location.derivedStoreURL)
            index = try MemoryIndex.inMemory()
            store = KnowledgeBaseStore(modelContainer: container)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func indexer() -> MemoryIndexer {
            MemoryIndexer(
                index: index, reader: SwiftDataMemorySources(container: container),
                feed: SwiftDataMemoryChangeFeed(
                    container: container, cursors: HistoryCursorStore(modelContainer: derived),
                    storeURL: location.syncedStoreURL),
                embedder: Support.HashingEmbedder(), chunker: Support.chunker, clock: SystemClock(),
                configuration: MemoryIndexer.Configuration(debounce: .milliseconds(20), retryDelay: .milliseconds(10)))
        }

        func search(_ query: String) async throws -> [MemoryChunk] {
            let hits = try await index.keywordSearch(query, limit: 50)
            return try await index.chunks(withIDs: hits.map(\.chunkID))
        }

        func reference() async throws -> [String] {
            let fresh = try MemoryIndex.inMemory()
            try await MemoryIndexRebuilder(
                index: fresh, sources: SwiftDataMemorySources(container: container), chunker: Support.chunker,
                embedder: Support.HashingEmbedder()
            ).rebuild()
            return try await IndexerTestSupport.fingerprint(fresh)
        }
    }

    @Test func notesCompanyAndCollectionEditsBecomeSearchable() async throws {
        let fixture = try Fixture()
        let indexer = fixture.indexer()
        let run = Task { await indexer.run() }
        defer { run.cancel() }
        try await SwiftDataIncrementalIndexingTests.eventually { await indexer.currentStatus.lastRebuild != nil }

        // A note, then an edit to it.
        let noteID = UUID()
        _ = try await fixture.store.saveDocument(
            noteID, kind: .note, title: "Pricing", body: "Annual billing gets two months free.")
        try await SwiftDataIncrementalIndexingTests.eventually { try await !fixture.search("billing").isEmpty }
        #expect(try await fixture.search("billing").map(\.sourceID) == [noteID])

        _ = try await fixture.store.saveDocument(
            noteID, kind: .note, title: "Pricing", body: "Annual invoicing gets two months free.")
        try await SwiftDataIncrementalIndexingTests.eventually { try await !fixture.search("invoicing").isEmpty }
        #expect(try await fixture.search("billing").isEmpty)

        // The company page, keyed by its name and headings (short fields
        // share a chunk; see MemoryChunker).
        var company = CompanyProfile(name: "Larderly")
        company[.oneLiner] = "Inventory and food-cost app for independent restaurants."
        company[.traction] = "Forty paying kitchens."
        _ = try await fixture.store.saveDocument(UUID(), kind: .company, title: company.name, body: company.markdown)
        try await SwiftDataIncrementalIndexingTests.eventually { try await !fixture.search("kitchens").isEmpty }
        let traction = try #require(try await fixture.search("kitchens").first)
        #expect(traction.keyText.hasPrefix("[Larderly] ["))
        #expect(traction.keyText.contains("Traction"))

        // A collection made by pasting thirty questions.
        let collectionID = UUID()
        _ = try await fixture.store.saveDocument(
            collectionID, kind: .collection, title: "YC interview questions", body: "")
        let added = try await fixture.store.addItems(
            CollectionImport(parsing: ycInterviewPaste).items, to: collectionID
        ).addedIDs
        #expect(added.count == 30)
        try await SwiftDataIncrementalIndexingTests.eventually { try await fixture.search("cofounders").count == 1 }
        let question = try #require(try await fixture.search("cofounders").first)
        #expect(question.sourceKind == .collectionItem)
        #expect(question.keyText.hasPrefix("[YC interview questions]"))
        await indexer.waitUntilIdle()
        #expect(try await fixture.index.sourceIDs(kind: .collectionItem).count == 30)

        // Renaming the collection re-keys its items; editing and deleting
        // items follow.
        _ = try await fixture.store.saveDocument(collectionID, kind: .collection, title: "Demo Day prep", body: "")
        try await fixture.store.updateItem(
            added[0], prompt: "What is Zanzibar building?", referenceAnswer: "Food costs.")
        try await fixture.store.deleteItems([added[1]])
        try await SwiftDataIncrementalIndexingTests.eventually {
            let renamed = try await fixture.search("cofounders").first?.keyText.hasPrefix("[Demo Day prep]") == true
            let remaining = try await fixture.index.sourceIDs(kind: .collectionItem).count
            let edited = try await fixture.search("Zanzibar")
            return renamed && remaining == 29 && edited.count == 1
        }

        // Deleting a note removes it.
        try await fixture.store.deleteDocument(noteID)
        try await SwiftDataIncrementalIndexingTests.eventually { try await fixture.search("invoicing").isEmpty }

        await indexer.waitUntilIdle()
        #expect(try await IndexerTestSupport.fingerprint(fixture.index) == fixture.reference())
    }
}

/// Thirty interview questions, one per line, numbered.
private let ycInterviewPaste = (1...30).map { number in
    switch number {
    case 13: "13. How did your cofounders meet?"
    default: "\(number). Interview question number \(number)?"
    }
}.joined(separator: "\n")
