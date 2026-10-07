import BlauMemory
import Foundation
import Testing

@testable import Blau

/// How the built app wires the memory indexer (#63). The bundle is hosted
/// in the app, so `Bundle.main` is the built Blau.app.
@Suite("Memory indexing wiring")
struct MemoryIndexingWiringTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func theBackgroundTaskIsPermitted() {
        let identifiers = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        #expect(identifiers.contains(MemoryIndexBackgroundTask.identifier))
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("processing"))
        #expect(modes.contains("audio"))
    }

    @MainActor
    @Test func hostedTestsNeverBuildAnIndex() async {
        let environment = AppEnvironment.make(kind: .unitTest)
        await environment.persistence.start()
        #expect(await environment.memoryIndexing.performBackgroundWork())
        #expect(environment.memoryIndexing.status == nil)
        #expect(environment.memoryIndexing.indexer == nil)
        #expect(!environment.memoryIndexing.needsBackgroundWork)
        environment.memoryIndexing.stop()
    }
}

@Suite("Memory index presentation")
struct MemoryIndexPresentationTests {
    private static let rebuilt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func withoutAnIndexItSaysWhy() {
        let presentation = MemoryIndexPresentation(nil)
        #expect(presentation.title == "Not available")
        #expect(!presentation.canRebuild)
        #expect(presentation.job == nil)
        #expect(presentation.indexed == nil)
    }

    @Test func anIdleIndexIsUpToDate() {
        let presentation = MemoryIndexPresentation(
            MemoryIndexingStatus(activity: .idle, chunkCount: 1_234, vectorCount: 1_234, lastRebuild: Self.rebuilt))
        #expect(presentation.title == "Up to date")
        #expect(presentation.indexed == 1_234.formatted())
        #expect(presentation.lastRebuild == Self.rebuilt)
        #expect(presentation.canRebuild)
        #expect(!presentation.isWarning)
        #expect(presentation.detail.contains("never leaves this device"))
    }

    @Test func aRebuildShowsItsProgress() throws {
        let presentation = MemoryIndexPresentation(
            MemoryIndexingStatus(
                activity: .rebuilding, rebuild: MemoryIndexingProgress(completed: 250, total: 1_000), chunkCount: 900))
        #expect(presentation.title == "Rebuilding…")
        let job = try #require(presentation.job)
        #expect(job.fractionCompleted == 0.25)
        #expect(job.count.contains(250.formatted()))
        #expect(job.count.contains(1_000.formatted()))
        #expect(!presentation.canRebuild)
    }

    @Test func embeddingShowsItsProgress() throws {
        let presentation = MemoryIndexPresentation(
            MemoryIndexingStatus(activity: .embedding, embedding: MemoryIndexingProgress(completed: 10, total: 40)))
        #expect(try #require(presentation.job).fractionCompleted == 0.25)
        #expect(presentation.canRebuild)
    }

    @Test func throttlingIsExplained() {
        let paused = MemoryIndexPresentation(
            MemoryIndexingStatus(
                activity: .waiting(.suspended), rebuild: MemoryIndexingProgress(completed: 1, total: 9)))
        #expect(paused.title == "Paused")
        #expect(paused.isWarning)
        #expect(paused.job != nil)
        let deferred = MemoryIndexPresentation(MemoryIndexingStatus(activity: .waiting(.deferred)))
        #expect(deferred.title == "Waiting")
        #expect(deferred.detail.contains("Low Power Mode"))
    }

    @Test func keywordOnlySearchIsExplained() {
        let presentation = MemoryIndexPresentation(
            MemoryIndexingStatus(activity: .idle, chunkCount: 10, vectorsUnavailable: "notInstalled"))
        #expect(presentation.detail.contains("language model"))
    }
}
