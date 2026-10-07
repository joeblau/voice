import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Synchronization

/// A temporary directory removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "blau-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var location: StoreLocation { StoreLocation(directory: url) }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// An account-status provider whose answer the test controls.
final class FakeAccountStatusProvider: CloudAccountStatusProviding {
    private struct State {
        var status: Result<CloudAccountStatus, FakeError>
        var calls = 0
        /// Queries waiting while stalled; `nil` when answering normally.
        var stalledQueries: [CheckedContinuation<Void, Never>]?
    }

    struct FakeError: Error {}

    private let state: Mutex<State>
    private let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    init(_ status: CloudAccountStatus) {
        state = Mutex(State(status: .success(status)))
        (changes, changesContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var calls: Int { state.withLock { $0.calls } }

    func set(_ status: CloudAccountStatus) {
        state.withLock { $0.status = .success(status) }
    }

    func fail() {
        state.withLock { $0.status = .failure(FakeError()) }
    }

    /// Makes later queries hang, ignoring cancellation, like a cold `cloudd`,
    /// until `unstall()`.
    func stall() {
        state.withLock { state in
            if state.stalledQueries == nil { state.stalledQueries = [] }
        }
    }

    /// Lets stalled and future queries answer.
    func unstall() {
        let waiting = state.withLock { state in
            defer { state.stalledQueries = nil }
            return state.stalledQueries ?? []
        }
        for query in waiting {
            query.resume()
        }
    }

    /// Simulates `CKAccountChanged`.
    func postAccountChange() {
        changesContinuation.yield()
    }

    func accountStatus() async throws -> CloudAccountStatus {
        if state.withLock({ $0.stalledQueries != nil }) {
            await withCheckedContinuation { (query: CheckedContinuation<Void, Never>) in
                let answerNow = state.withLock { state in
                    guard state.stalledQueries != nil else { return true }
                    state.stalledQueries?.append(query)
                    return false
                }
                if answerNow { query.resume() }
            }
        }
        return try state.withLock { state in
            state.calls += 1
            return try state.status.get()
        }
    }

    func accountChanges() -> AsyncStream<Void> {
        changes
    }
}

/// A provider that ignores cancellation and only answers when released,
/// like a `CKContainer` waiting on a cold `cloudd`.
final class StuckAccountStatusProvider: CloudAccountStatusProviding {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let released = Mutex(false)

    /// Lets every pending and future query answer `.available`.
    func release() {
        released.withLock { $0 = true }
        for waiter in waiters.withLock({ waiters in
            defer { waiters = [] }
            return waiters
        }) {
            waiter.resume()
        }
    }

    func accountStatus() async throws -> CloudAccountStatus {
        await withCheckedContinuation { continuation in
            let resumeNow = released.withLock { released in
                if !released { waiters.withLock { $0.append(continuation) } }
                return released
            }
            if resumeNow { continuation.resume() }
        }
        return .available
    }

    func accountChanges() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

/// Records schema initializations instead of talking to CloudKit.
final class RecordingSchemaInitializer: CloudKitSchemaInitializing {
    private let calls = Mutex<[String]>([])
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var containerIdentifiers: [String] { calls.withLock { $0 } }

    func initializeSchema(_ schema: Schema, storeURL: URL, containerIdentifier: String) throws {
        calls.withLock { $0.append(containerIdentifier) }
        if shouldFail { throw CloudKitSchemaInitializationError.unconvertibleSchema }
    }
}

/// Records which CloudKit containers stores were opened with.
final class OpenRecorder: Sendable {
    private let opened = Mutex<[String?]>([])

    /// The `cloudKitContainerIdentifier` of every configuration opened, in
    /// order (`nil` for local-only and in-memory).
    var containerIdentifiers: [String?] { opened.withLock { $0 } }

    func record(_ configuration: ModelConfiguration) {
        opened.withLock { $0.append(configuration.cloudKitContainerIdentifier) }
    }
}

enum SyncTestError: Error {
    case injected
}

extension PersistenceBootstrap {
    /// A bootstrap that can run on a Mac without the iCloud entitlement: it
    /// records the requested configuration, then opens the same file with
    /// CloudKit off. `failCloudKit` / `failLocal` inject open failures.
    static func hermetic(
        recorder: OpenRecorder = OpenRecorder(),
        initializer: any CloudKitSchemaInitializing = RecordingSchemaInitializer(),
        defaultsSuite: String = "blau-tests-\(UUID().uuidString)",
        failCloudKit: Bool = false,
        failLocal: Bool = false
    ) -> PersistenceBootstrap {
        PersistenceBootstrap(
            openSyncedStore: { configuration in
                recorder.record(configuration)
                if configuration.cloudKitContainerIdentifier != nil {
                    if failCloudKit { throw SyncTestError.injected }
                } else if !configuration.isStoredInMemoryOnly, failLocal {
                    throw SyncTestError.injected
                }
                let local =
                    configuration.isStoredInMemoryOnly
                    ? configuration
                    : ModelConfiguration(
                        configuration.name, schema: configuration.schema, url: configuration.url,
                        cloudKitDatabase: .none)
                return try BlauModelContainer.make(configurations: [local])
            },
            schemaInitializer: initializer,
            schemaGate: { containerIdentifier in
                CloudKitSchemaInitializationGate(
                    defaults: UserDefaults(suiteName: defaultsSuite)!, containerIdentifier: containerIdentifier)
            }
        )
    }
}

/// A fixed reference date so tests never read the wall clock.
let syncT0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
