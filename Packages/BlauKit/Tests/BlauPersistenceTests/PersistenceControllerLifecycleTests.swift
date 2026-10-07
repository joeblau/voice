import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

/// `PersistenceController` as the composition root's persistence service:
/// leaving the foreground saves pending UI edits.
@Suite("PersistenceController lifecycle")
@MainActor
struct PersistenceControllerLifecycleTests {
    private func makeController(
        _ temporary: TemporaryDirectory,
        storeOverride: StoreOverride? = .local,
        provider: FakeAccountStatusProvider? = nil,
        backend: RecordingSignpostBackend
    ) -> PersistenceController {
        PersistenceController(
            options: PersistenceOptions(
                location: temporary.location, cloudKitEntitled: provider != nil, storeOverride: storeOverride),
            accountProvider: provider,
            bootstrap: .hermetic(),
            clock: ManualClock(now: syncT0),
            notificationCenter: NotificationCenter(),
            signposter: Signposter(category: .data, backend: backend)
        )
    }

    @Test(arguments: [AppPhase.inactive, .background])
    func leavingTheForegroundSavesPendingEdits(phase: AppPhase) async throws {
        let temporary = try TemporaryDirectory()
        let backend = RecordingSignpostBackend()
        let controller = makeController(temporary, backend: backend)
        await controller.start()
        let context = try #require(controller.stack).container.mainContext
        context.insert(Conversation(startedAt: syncT0, title: "Kept"))
        #expect(context.hasChanges)

        await controller.appPhaseDidChange(AppPhaseTransition(from: .active, to: phase))
        #expect(!context.hasChanges)
        #expect(backend.completedIntervals == ["db.save"])

        // The edit is on disk: a relaunch reads it back.
        let relaunched = makeController(temporary, backend: RecordingSignpostBackend())
        await relaunched.start()
        let container = try #require(relaunched.stack).container
        #expect(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).map(\.title) == ["Kept"])
    }

    @Test func becomingActiveDoesNotSave() async throws {
        let temporary = try TemporaryDirectory()
        let backend = RecordingSignpostBackend()
        let controller = makeController(temporary, storeOverride: .memory, backend: backend)
        await controller.start()
        let context = try #require(controller.stack).container.mainContext
        context.insert(Conversation(startedAt: syncT0))

        await controller.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        #expect(context.hasChanges)
        #expect(backend.records.isEmpty)
    }

    @Test func savingWithNothingPendingOrNoStoreIsANoOp() async throws {
        let temporary = try TemporaryDirectory()
        let backend = RecordingSignpostBackend()
        let controller = makeController(temporary, storeOverride: .memory, backend: backend)
        // Before `start()` there is no store to save.
        try controller.saveMainContext()
        await controller.start()
        try controller.saveMainContext()
        #expect(backend.records.isEmpty)
    }

    /// The save reads the container from the current stack, so after the
    /// iCloud account changes it saves the store that is open now.
    @Test func savesTheStoreOpenAfterASyncModeSwitch() async throws {
        let temporary = try TemporaryDirectory()
        let backend = RecordingSignpostBackend()
        let provider = FakeAccountStatusProvider(.noAccount)
        let controller = makeController(temporary, storeOverride: nil, provider: provider, backend: backend)
        await controller.start()
        let before = try #require(controller.stack).container

        provider.set(.available)
        await controller.refresh()
        let after = try #require(controller.stack).container
        #expect(controller.generation == 2)
        #expect(before !== after)

        after.mainContext.insert(Conversation(startedAt: syncT0))
        await controller.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        #expect(!after.mainContext.hasChanges)
        #expect(backend.completedIntervals == ["db.save"])
    }
}
