import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A store directory removed when the test ends.
private final class ScratchDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blau-persistence-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("SwiftDataPersistence")
@MainActor
struct PersistenceServiceTests {
    @Test func inMemoryStoreStartsEmpty() throws {
        let persistence = try SwiftDataPersistence.inMemory()
        #expect(persistence.storeKind == .inMemory)
        #expect(persistence.openFailure == nil)
        #expect(try persistence.modelContainer.mainContext.fetchCount(FetchDescriptor<Conversation>()) == 0)
    }

    @Test func liveStoreOpensOnDiskAndKeepsDataAcrossLaunches() async throws {
        let directory = try ScratchDirectory()
        let url = directory.url.appendingPathComponent("Blau.store")

        let first = SwiftDataPersistence.live(url: url)
        #expect(first.storeKind == .persistent(url: url))
        #expect(first.openFailure == nil)
        first.modelContainer.mainContext.insert(Conversation(startedAt: t0, title: "Kept"))
        try await first.saveMainContext()

        let relaunched = SwiftDataPersistence.live(url: url)
        let titles = try relaunched.modelContainer.mainContext.fetch(FetchDescriptor<Conversation>()).map(\.title)
        #expect(titles == ["Kept"])
    }

    @Test func liveStoreFallsBackToMemoryWhenTheStoreCantBeOpened() throws {
        let directory = try ScratchDirectory()
        // A regular file where the store's directory should be makes the
        // store impossible to create.
        let blocker = directory.url.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let persistence = SwiftDataPersistence.live(url: blocker.appendingPathComponent("Blau.store"))

        #expect(persistence.storeKind == .inMemory)
        #expect(persistence.openFailure != nil)
        #expect(try persistence.modelContainer.mainContext.fetchCount(FetchDescriptor<Conversation>()) == 0)
    }

    @Test(arguments: [AppPhase.inactive, .background])
    func leavingTheForegroundSavesPendingEdits(phase: AppPhase) async throws {
        let backend = RecordingSignpostBackend()
        let persistence = SwiftDataPersistence(
            modelContainer: try BlauModelContainer.makeInMemory(),
            storeKind: .inMemory,
            signposter: Signposter(category: .data, backend: backend)
        )
        let context = persistence.modelContainer.mainContext
        context.insert(Conversation(startedAt: t0))
        #expect(context.hasChanges)

        await persistence.appPhaseDidChange(AppPhaseTransition(from: .active, to: phase))
        #expect(!context.hasChanges)
        #expect(backend.completedIntervals == ["db.save"])

        // Saved changes are visible to a fresh context on the same container.
        #expect(try ModelContext(persistence.modelContainer).fetchCount(FetchDescriptor<Conversation>()) == 1)
    }

    @Test func becomingActiveDoesNotSave() async throws {
        let backend = RecordingSignpostBackend()
        let persistence = SwiftDataPersistence(
            modelContainer: try BlauModelContainer.makeInMemory(),
            storeKind: .inMemory,
            signposter: Signposter(category: .data, backend: backend)
        )
        persistence.modelContainer.mainContext.insert(Conversation(startedAt: t0))
        await persistence.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        #expect(persistence.modelContainer.mainContext.hasChanges)
        #expect(backend.records.isEmpty)
    }

    @Test func savingWithNothingPendingIsANoOp() async throws {
        let backend = RecordingSignpostBackend()
        let persistence = SwiftDataPersistence(
            modelContainer: try BlauModelContainer.makeInMemory(),
            storeKind: .inMemory,
            signposter: Signposter(category: .data, backend: backend)
        )
        try await persistence.saveMainContext()
        #expect(backend.records.isEmpty)
    }
}
