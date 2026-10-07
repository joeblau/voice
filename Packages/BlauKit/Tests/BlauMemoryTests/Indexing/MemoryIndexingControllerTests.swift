import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import BlauMemory

/// The app-facing controller (#63): one indexer per store generation, an
/// in-memory store left alone, and the background-task entry point.
@Suite("Memory indexing controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MemoryIndexingControllerTests {
    typealias Support = IndexTestSupport

    final class Directory {
        let url: URL
        init() throws { url = try Support.temporaryDirectory() }
        deinit { try? FileManager.default.removeItem(at: url) }
        var location: StoreLocation { StoreLocation(directory: url) }
    }

    static func persistence(_ directory: Directory, override: StoreOverride = .local) -> PersistenceController {
        PersistenceController(
            options: PersistenceOptions(location: directory.location, cloudKitEntitled: false, storeOverride: override),
            accountProvider: nil)
    }

    static func controller(_ persistence: PersistenceController, embedder: Support.HashingEmbedder? = nil)
        -> MemoryIndexingController
    {
        MemoryIndexingController(
            persistence: persistence, embedder: embedder ?? Support.HashingEmbedder(),
            performance: FixedPerformanceLevel(.normal), chunker: Support.chunker,
            configuration: MemoryIndexer.Configuration(debounce: .milliseconds(10), retryDelay: .milliseconds(10)))
    }

    @Test func indexesTheOnDiskStoreAndFollowsItsChanges() async throws {
        let directory = try Directory()
        let persistence = Self.persistence(directory)
        await persistence.start()
        let context = try #require(persistence.stack).container.mainContext
        context.insert(
            MemoryDocument(kind: .note, title: "Pricing", body: "Larderly costs $149.", createdAt: Support.t0))
        try context.save()

        let controller = Self.controller(persistence)
        controller.start()
        #expect(await controller.performBackgroundWork())
        let indexer = try #require(controller.indexer)
        #expect(controller.status?.chunkCount == 1)
        #expect(controller.status?.lastRebuild != nil)
        #expect(!controller.needsBackgroundWork)
        #expect(FileManager.default.fileExists(atPath: directory.location.memoryIndexURL.path(percentEncoded: false)))

        // A save to the store reaches the index without a call.
        context.insert(MemoryDocument(kind: .note, title: "Travel", body: "Osaka in April.", createdAt: Support.t0))
        try context.save()
        let deadline = ContinuousClock.now + .seconds(20)
        while try await indexer.index.keywordSearch("Osaka", limit: 5).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await indexer.index.keywordSearch("Osaka", limit: 5).count == 1)
        controller.stop()
    }

    @Test func anInMemoryStoreHasNoIndex() async throws {
        let directory = try Directory()
        let persistence = Self.persistence(directory, override: .memory)
        let controller = Self.controller(persistence)
        #expect(await controller.performBackgroundWork())
        #expect(controller.indexer == nil)
        #expect(controller.status == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.location.memoryIndexURL.path(percentEncoded: false)))
        controller.stop()
    }

    @Test func aNewStoreGenerationGetsANewIndexerOnTheSameFile() async throws {
        let directory = try Directory()
        let persistence = Self.persistence(directory)
        await persistence.start()
        let controller = Self.controller(persistence)
        #expect(await controller.performBackgroundWork())
        let first = try #require(controller.indexer)

        // What the controller does when the account changes: the same store
        // file, reopened in a new container.
        let stack = try #require(persistence.stack)
        let reopened = PersistenceStack(
            mode: stack.mode, container: try BlauModelContainer.makeLocal(url: stack.location.syncedStoreURL),
            derivedContainer: stack.derivedContainer, location: stack.location)
        await controller.install(reopened, generation: persistence.generation + 1)
        let second = try #require(controller.indexer)
        #expect(second !== first)
        #expect(second.index === first.index)
        controller.stop()
    }

    @Test func rebuildRereadsEverything() async throws {
        let directory = try Directory()
        let persistence = Self.persistence(directory)
        await persistence.start()
        let embedder = Support.HashingEmbedder()
        let controller = Self.controller(persistence, embedder: embedder)
        let context = try #require(persistence.stack).container.mainContext
        context.insert(
            MemoryDocument(kind: .note, title: "Pricing", body: "Larderly costs $149.", createdAt: Support.t0))
        try context.save()
        #expect(await controller.performBackgroundWork())
        let rebuilt = try #require(controller.status?.lastRebuild)

        try await Task.sleep(for: .milliseconds(5))
        controller.rebuild()
        let indexer = try #require(controller.indexer)
        let deadline = ContinuousClock.now + .seconds(20)
        while try await indexer.index.lastRebuild() == rebuilt, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await indexer.index.lastRebuild() != rebuilt)
        // Nothing changed, so nothing was embedded again.
        #expect(embedder.embeddedTexts.count == 1)
        controller.stop()
    }
}
