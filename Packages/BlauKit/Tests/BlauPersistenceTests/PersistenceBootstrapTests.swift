import BlauPersistence
import Foundation
import SwiftData
import Testing

private let cloudKit = SyncMode.cloudKit(containerIdentifier: BlauCloud.containerIdentifier)

private func options(
    _ location: StoreLocation,
    schemaInitialization: SchemaInitializationPolicy = .never
) -> PersistenceOptions {
    PersistenceOptions(location: location, cloudKitEntitled: true, schemaInitialization: schemaInitialization)
}

private func conversationIDs(in container: ModelContainer) throws -> Set<UUID> {
    Set(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).map(\.id))
}

private func insertConversation(into container: ModelContainer) throws -> UUID {
    let context = ModelContext(container)
    let conversation = Conversation(startedAt: syncT0)
    context.insert(conversation)
    try context.save()
    return conversation.id
}

@Suite("PersistenceBootstrap")
struct PersistenceBootstrapTests {
    @Test func opensCloudKitModeAgainstBlausPrivateDatabase() throws {
        let temporary = try TemporaryDirectory()
        let recorder = OpenRecorder()
        let stack = PersistenceBootstrap.hermetic(recorder: recorder)
            .makeStack(mode: cloudKit, options: options(temporary.location))
        #expect(stack.mode == cloudKit)
        #expect(recorder.containerIdentifiers == ["iCloud.com.joeblau.blau"])
        #expect(stack.syncedStoreURL == temporary.location.syncedStoreURL)
        #expect(FileManager.default.fileExists(atPath: temporary.location.syncedStoreURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: temporary.location.derivedStoreURL.path(percentEncoded: false)))
    }

    @Test func signingOutKeepsEveryConversation() throws {
        let temporary = try TemporaryDirectory()
        let bootstrap = PersistenceBootstrap.hermetic()
        let signedIn = bootstrap.makeStack(mode: cloudKit, options: options(temporary.location))
        let id = try insertConversation(into: signedIn.container)

        let signedOut = bootstrap.makeStack(
            mode: .localOnly(.account(.noAccount)), options: options(temporary.location))
        #expect(signedOut.mode == .localOnly(.account(.noAccount)))
        #expect(try conversationIDs(in: signedOut.container) == [id])

        // Written while signed out, still there after signing back in.
        let offline = try insertConversation(into: signedOut.container)
        let signedInAgain = bootstrap.makeStack(mode: cloudKit, options: options(temporary.location))
        #expect(try conversationIDs(in: signedInAgain.container) == [id, offline])
    }

    @Test func aCloudKitFailureReopensTheSameFileLocalOnly() throws {
        let temporary = try TemporaryDirectory()
        let local = PersistenceBootstrap.hermetic().makeStack(
            mode: .localOnly(.notEntitled), options: options(temporary.location))
        let id = try insertConversation(into: local.container)

        let recorder = OpenRecorder()
        let stack = PersistenceBootstrap.hermetic(recorder: recorder, failCloudKit: true)
            .makeStack(mode: cloudKit, options: options(temporary.location))
        guard case .localOnly(.cloudKitFailed) = stack.mode else {
            Issue.record("Expected a local-only fallback, got \(stack.mode)")
            return
        }
        #expect(recorder.containerIdentifiers == ["iCloud.com.joeblau.blau", nil])
        #expect(try conversationIDs(in: stack.container) == [id])
    }

    @Test func anUnopenableStoreFallsBackToMemoryAndIsLeftOnDisk() throws {
        let temporary = try TemporaryDirectory()
        try temporary.location.prepare()
        let garbage = Data("not a sqlite file".utf8)
        try garbage.write(to: temporary.location.syncedStoreURL)

        let stack = PersistenceBootstrap.hermetic(failLocal: true)
            .makeStack(mode: .localOnly(.notEntitled), options: options(temporary.location))
        guard case .inMemory(.storeFailed) = stack.mode else {
            Issue.record("Expected an in-memory fallback, got \(stack.mode)")
            return
        }
        #expect(stack.syncedStoreURL == nil)
        #expect(try Data(contentsOf: temporary.location.syncedStoreURL) == garbage)
        // The app still works, it just doesn't persist.
        _ = try insertConversation(into: stack.container)
    }

    @Test func memoryModeNeverTouchesTheDisk() throws {
        let temporary = try TemporaryDirectory()
        let location = StoreLocation(directory: temporary.url.appending(path: "Unused"))
        let stack = PersistenceBootstrap.hermetic().makeStack(mode: .inMemory(.requested), options: options(location))
        #expect(stack.mode == .inMemory(.requested))
        #expect(!FileManager.default.fileExists(atPath: location.directory.path(percentEncoded: false)))
        _ = try insertConversation(into: stack.container)
    }

    @Test func aCorruptDerivedStoreIsRecreated() throws {
        let temporary = try TemporaryDirectory()
        try temporary.location.prepare()
        try Data("corrupt".utf8).write(to: temporary.location.derivedStoreURL)

        let container = try DerivedStore.open(at: temporary.location.derivedStoreURL)
        let context = ModelContext(container)
        context.insert(HistoryCursor(consumer: "test", token: nil, updatedAt: syncT0))
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HistoryCursor>()) == 1)
    }
}

@Suite("CloudKit schema initialization")
struct CloudKitSchemaInitializationTests {
    @Test func runsOncePerSchemaShapeInCloudKitMode() throws {
        let temporary = try TemporaryDirectory()
        let initializer = RecordingSchemaInitializer()
        let suite = "blau-tests-\(UUID().uuidString)"
        let bootstrap = PersistenceBootstrap.hermetic(initializer: initializer, defaultsSuite: suite)
        let options = options(temporary.location, schemaInitialization: .whenSchemaChanges)

        _ = bootstrap.makeStack(mode: cloudKit, options: options)
        _ = bootstrap.makeStack(mode: cloudKit, options: options)
        #expect(initializer.containerIdentifiers == ["iCloud.com.joeblau.blau"])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func retriesAfterAFailure() throws {
        let temporary = try TemporaryDirectory()
        let initializer = RecordingSchemaInitializer(shouldFail: true)
        let bootstrap = PersistenceBootstrap.hermetic(initializer: initializer)
        let options = options(temporary.location, schemaInitialization: .whenSchemaChanges)

        let stack = bootstrap.makeStack(mode: cloudKit, options: options)
        _ = bootstrap.makeStack(mode: cloudKit, options: options)
        #expect(initializer.containerIdentifiers.count == 2)
        // A failed initialization never blocks opening the store.
        #expect(stack.mode == cloudKit)
    }

    @Test func alwaysRunsWhenForced() throws {
        let temporary = try TemporaryDirectory()
        let initializer = RecordingSchemaInitializer()
        let bootstrap = PersistenceBootstrap.hermetic(initializer: initializer)
        let options = options(temporary.location, schemaInitialization: .always)
        _ = bootstrap.makeStack(mode: cloudKit, options: options)
        _ = bootstrap.makeStack(mode: cloudKit, options: options)
        #expect(initializer.containerIdentifiers.count == 2)
    }

    @Test(arguments: [SyncMode.localOnly(.account(.noAccount)), .localOnly(.notEntitled), .inMemory(.requested)])
    func neverRunsWithoutCloudKit(mode: SyncMode) throws {
        let temporary = try TemporaryDirectory()
        let initializer = RecordingSchemaInitializer()
        _ = PersistenceBootstrap.hermetic(initializer: initializer)
            .makeStack(mode: mode, options: options(temporary.location, schemaInitialization: .always))
        #expect(initializer.containerIdentifiers.isEmpty)
    }

    @Test func neverRunsInRelease() throws {
        let temporary = try TemporaryDirectory()
        let initializer = RecordingSchemaInitializer()
        _ = PersistenceBootstrap.hermetic(initializer: initializer)
            .makeStack(mode: cloudKit, options: options(temporary.location, schemaInitialization: .never))
        #expect(initializer.containerIdentifiers.isEmpty)
    }

    @Test func theFingerprintIsStableAndTracksTheModel() {
        let current = CloudKitSchemaInitializationGate.fingerprint(of: BlauModelContainer.schema)
        #expect(current == CloudKitSchemaInitializationGate.fingerprint(of: BlauModelContainer.schema))
        #expect(current.count == 64)
        #expect(current != CloudKitSchemaInitializationGate.fingerprint(of: DerivedStore.schema))
    }
}
