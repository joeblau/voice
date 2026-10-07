import BlauCore
import BlauPersistence
import CoreData
import Foundation
import SwiftData
import Testing

private let cloudKit = SyncMode.cloudKit(containerIdentifier: BlauCloud.containerIdentifier)

@MainActor
private func makeController(
    _ temporary: TemporaryDirectory,
    provider: FakeAccountStatusProvider?,
    entitled: Bool = true,
    storeOverride: StoreOverride? = nil,
    recorder: OpenRecorder = OpenRecorder(),
    clock: ManualClock = ManualClock(now: syncT0),
    notificationCenter: NotificationCenter = NotificationCenter()
) -> PersistenceController {
    PersistenceController(
        options: PersistenceOptions(
            location: temporary.location, cloudKitEntitled: entitled, storeOverride: storeOverride),
        accountProvider: provider,
        bootstrap: .hermetic(recorder: recorder),
        clock: clock,
        notificationCenter: notificationCenter
    )
}

@MainActor
private func insertConversation(_ controller: PersistenceController) throws -> UUID {
    let context = try #require(controller.stack).container.mainContext
    let conversation = Conversation(startedAt: syncT0)
    context.insert(conversation)
    try context.save()
    return conversation.id
}

@MainActor
private func conversationIDs(_ controller: PersistenceController) throws -> Set<UUID> {
    let container = try #require(controller.stack).container
    return Set(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).map(\.id))
}

@Suite("PersistenceController")
@MainActor
struct PersistenceControllerTests {
    @Test func opensWithCloudKitWhenSignedIn() async throws {
        let temporary = try TemporaryDirectory()
        let recorder = OpenRecorder()
        let controller = makeController(temporary, provider: FakeAccountStatusProvider(.available), recorder: recorder)
        #expect(controller.syncState == .checking)

        await controller.start()
        #expect(controller.stack?.mode == cloudKit)
        #expect(controller.accountStatus == .available)
        #expect(controller.generation == 1)
        #expect(controller.syncState == .upToDate(lastSync: nil))
        #expect(recorder.containerIdentifiers == ["iCloud.com.joeblau.blau"])
    }

    @Test func worksSignedOutOfICloud() async throws {
        let temporary = try TemporaryDirectory()
        let recorder = OpenRecorder()
        let controller = makeController(temporary, provider: FakeAccountStatusProvider(.noAccount), recorder: recorder)
        await controller.start()

        #expect(controller.stack?.mode == .localOnly(.account(.noAccount)))
        #expect(controller.syncState == .off(.signedOut))
        #expect(recorder.containerIdentifiers == [nil])
        let id = try insertConversation(controller)

        // Data written signed out survives a relaunch.
        let relaunched = makeController(temporary, provider: FakeAccountStatusProvider(.noAccount))
        await relaunched.start()
        #expect(try conversationIDs(relaunched) == [id])
    }

    @Test func startIsIdempotent() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider)
        async let first: Void = controller.start()
        async let second: Void = controller.start()
        _ = await (first, second)
        await controller.start()
        #expect(controller.generation == 1)
        #expect(provider.calls == 1)
    }

    @Test func signingInSwitchesToCloudKitAndKeepsLocalData() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.noAccount)
        let recorder = OpenRecorder()
        let controller = makeController(temporary, provider: provider, recorder: recorder)
        await controller.start()
        let id = try insertConversation(controller)

        provider.set(.available)
        await controller.refresh()
        #expect(controller.stack?.mode == cloudKit)
        #expect(controller.generation == 2)
        #expect(try conversationIDs(controller) == [id])
        #expect(recorder.containerIdentifiers == [nil, "iCloud.com.joeblau.blau"])
    }

    @Test func signingOutFallsBackToLocalOnlyWithoutLosingData() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider)
        await controller.start()
        let id = try insertConversation(controller)

        provider.set(.noAccount)
        await controller.refresh()
        #expect(controller.stack?.mode == .localOnly(.account(.noAccount)))
        #expect(controller.syncState == .off(.signedOut))
        #expect(try conversationIDs(controller) == [id])
    }

    @Test func unsavedMainContextEditsSurviveTheSwitch() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider)
        await controller.start()
        let context = try #require(controller.stack).container.mainContext
        context.autosaveEnabled = false
        let conversation = Conversation(startedAt: syncT0)
        context.insert(conversation)
        let id = conversation.id

        provider.set(.noAccount)
        await controller.refresh()
        #expect(try conversationIDs(controller) == [id])
    }

    @Test func anUnchangedAccountKeepsTheStack() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.noAccount)
        let controller = makeController(temporary, provider: provider)
        await controller.start()
        provider.set(.restricted)
        await controller.refresh()
        #expect(controller.generation == 1)
        #expect(controller.accountStatus == .restricted)
        #expect(controller.syncState == .off(.restricted))
    }

    @Test func aFailedStatusQueryKeepsCloudKit() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let recorder = OpenRecorder()
        let controller = makeController(temporary, provider: provider, recorder: recorder)
        await controller.start()
        let id = try insertConversation(controller)

        // An XPC or network error is not a sign-out.
        provider.fail()
        await controller.refresh()
        #expect(controller.generation == 1)
        #expect(controller.stack?.mode == cloudKit)
        #expect(controller.accountStatus == .couldNotDetermine)
        #expect(controller.syncState == .upToDate(lastSync: nil))
        #expect(recorder.containerIdentifiers == ["iCloud.com.joeblau.blau"])

        // The next definite answer still decides.
        provider.set(.available)
        await controller.refresh()
        #expect(controller.generation == 1)
        #expect(controller.accountStatus == .available)
        provider.set(.noAccount)
        await controller.refresh()
        #expect(controller.generation == 2)
        #expect(controller.stack?.mode == .localOnly(.account(.noAccount)))
        #expect(try conversationIDs(controller) == [id])
    }

    @Test(.timeLimit(.minutes(1))) func aTimedOutStatusQueryKeepsCloudKit() async throws {
        let temporary = try TemporaryDirectory()
        let clock = ManualClock(now: syncT0)
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider, clock: clock)
        await controller.start()

        // cloudd takes longer than the refresh deadline.
        provider.stall()
        async let refreshed: Void = controller.refresh()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(10))
        await refreshed
        #expect(controller.generation == 1)
        #expect(controller.stack?.mode == cloudKit)
        #expect(controller.accountStatus == .couldNotDetermine)
        provider.unstall()
    }

    @Test func anUndeterminedStatusStillLeavesLocalOnlyAlone() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.noAccount)
        let controller = makeController(temporary, provider: provider)
        await controller.start()
        provider.fail()
        await controller.refresh()
        #expect(controller.generation == 1)
        #expect(controller.stack?.mode == .localOnly(.account(.noAccount)))
        #expect(controller.syncState == .off(.unknown))
    }

    @Test func aCloudKitFailureIsNotRetriedUntilRelaunch() async throws {
        let temporary = try TemporaryDirectory()
        let recorder = OpenRecorder()
        let controller = PersistenceController(
            options: PersistenceOptions(location: temporary.location, cloudKitEntitled: true),
            accountProvider: FakeAccountStatusProvider(.available),
            bootstrap: .hermetic(recorder: recorder, failCloudKit: true),
            clock: ManualClock(now: syncT0),
            notificationCenter: NotificationCenter()
        )
        await controller.start()
        guard case .localOnly(.cloudKitFailed) = controller.stack?.mode else {
            Issue.record("Expected a CloudKit failure fallback, got \(String(describing: controller.stack?.mode))")
            return
        }
        await controller.refresh()
        await controller.refresh()
        #expect(controller.generation == 1)
        #expect(recorder.containerIdentifiers == ["iCloud.com.joeblau.blau", nil])
    }

    @Test func anUnentitledBuildNeverAsksCloudKit() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider, entitled: false)
        await controller.start()
        await controller.refresh()
        #expect(provider.calls == 0)
        #expect(controller.stack?.mode == .localOnly(.notEntitled))
        #expect(controller.accountStatus == nil)
    }

    @Test func theMemoryOverrideIsNotPersistent() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.available)
        let controller = makeController(temporary, provider: provider, storeOverride: .memory)
        await controller.start()
        #expect(provider.calls == 0)
        #expect(controller.stack?.mode == .inMemory(.requested))
        #expect(controller.syncState == .notSaved(storeFailed: false))
    }

    @Test func publishesStoreChanges() async throws {
        let temporary = try TemporaryDirectory()
        let controller = makeController(temporary, provider: FakeAccountStatusProvider(.available))
        await controller.start()
        let changes = controller.storeChanges()

        // Simulate a CloudKit import: another context writes as the mirroring
        // delegate, then the store posts a remote change.
        let importer = ModelContext(try #require(controller.stack).container)
        importer.author = "NSCloudKitMirroringDelegate.import"
        importer.insert(Conversation(startedAt: syncT0))
        try importer.save()
        await controller.processHistory()

        var iterator = changes.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.importedTransactionCount == 1)
        #expect(received.changes(to: Conversation.self).inserted.count == 1)
        #expect(controller.lastChanges == received)
        #expect(controller.lastChangesAt == syncT0)
    }

    @Test(.timeLimit(.minutes(1))) func runFollowsAccountChangesAndRemoteChanges() async throws {
        let temporary = try TemporaryDirectory()
        let provider = FakeAccountStatusProvider(.noAccount)
        let center = NotificationCenter()
        let controller = makeController(temporary, provider: provider, notificationCenter: center)
        let running = Task { await controller.run() }
        defer { running.cancel() }
        await controller.start()
        let changes = controller.storeChanges()

        provider.set(.available)
        provider.postAccountChange()
        while controller.stack?.mode != cloudKit {
            await Task.yield()
        }
        #expect(controller.generation == 2)

        let writer = ModelContext(try #require(controller.stack).container)
        writer.author = "NSCloudKitMirroringDelegate.import"
        writer.insert(Conversation(startedAt: syncT0))
        try writer.save()
        center.post(
            name: .NSPersistentStoreRemoteChange, object: nil,
            userInfo: ["storeURL": temporary.location.syncedStoreURL])

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next()?.includesRemoteChanges == true)
    }
}
