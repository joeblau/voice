import BlauCore
import BlauTelemetry
import Foundation
import Observation
import SwiftData
import os

/// Owns Blau's stores for the app's lifetime and keeps them matched to the
/// iCloud account.
///
/// - At launch it reads the account status (with a timeout) and opens the
///   synced store with CloudKit when the account allows it, or local-only
///   when it doesn't. Both use the same file, so no data is lost either way.
/// - When the account changes while running (sign in or out), it saves and
///   reopens the store in the new mode. `generation` increments so views and
///   services holding the old container can pick up the new one.
/// - It follows CloudKit mirroring events (for the Settings status) and reads
///   persistent history whenever the store changes underneath the app
///   (`NSPersistentStoreRemoteChange`, a finished import, or `refresh()` when
///   the app becomes active), publishing a `StoreChangeSet` to subscribers.
/// - It is the composition root's persistence service: leaving the
///   foreground saves pending main-context edits (`AppLifecycleParticipant`),
///   so an edit made in the UI survives the process being suspended or
///   killed.
@MainActor
@Observable
public final class PersistenceController {
    /// The open stores. `nil` until `start()` finishes.
    public private(set) var stack: PersistenceStack?
    /// Increments every time `stack` is replaced.
    public private(set) var generation = 0
    /// The last iCloud account status read, or `nil` if it wasn't needed or
    /// hasn't arrived.
    public private(set) var accountStatus: CloudAccountStatus?
    /// CloudKit mirroring activity since launch.
    public private(set) var activity = CloudSyncActivity()
    /// The most recent non-empty batch of store changes and when it was read.
    public private(set) var lastChanges: StoreChangeSet?
    public private(set) var lastChangesAt: Date?

    public let options: PersistenceOptions

    @ObservationIgnored private let accountProvider: (any CloudAccountStatusProviding)?
    @ObservationIgnored private let bootstrap: PersistenceBootstrap
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let signposter: Signposter
    @ObservationIgnored private var tracker: PersistentHistoryTracker?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<StoreChangeSet>.Continuation] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isTransitioning = false
    @ObservationIgnored private var pendingAccountStatus: CloudAccountStatus?

    /// The history consumer name the controller uses for its own cursor.
    public static let historyConsumer = "sync-status"

    /// - Parameters:
    ///   - accountProvider: Reads the iCloud account. Only consulted when
    ///     `options.needsAccountStatus` (the build is entitled and nothing
    ///     overrides the store), so an unentitled build never touches
    ///     CloudKit.
    public init(
        options: PersistenceOptions,
        accountProvider: (any CloudAccountStatusProviding)?,
        bootstrap: PersistenceBootstrap = .live,
        clock: any BlauClock = .system,
        notificationCenter: NotificationCenter = .default,
        signposter: Signposter = Signposts.data
    ) {
        self.options = options
        self.accountProvider = accountProvider
        self.bootstrap = bootstrap
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.signposter = signposter
    }

    /// The production controller for the running app.
    ///
    /// - Parameter isDebugBuild: Pass `true` only from a DEBUG build; it
    ///   enables `initializeCloudKitSchema()` when the schema changes.
    public static func live(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        isDebugBuild: Bool
    ) -> PersistenceController {
        let options = PersistenceOptions.resolve(
            infoDictionary: bundle.infoDictionary ?? [:],
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            allowsSchemaInitialization: isDebugBuild
        )
        return PersistenceController(
            options: options,
            accountProvider: CloudKitAccountStatusProvider(containerIdentifier: options.containerIdentifier)
        )
    }

    /// The sync state for Settings.
    public var syncState: SyncState {
        SyncState(mode: stack?.mode, accountStatus: accountStatus, activity: activity)
    }

    // MARK: - Lifecycle

    /// Opens the stores. Safe to call more than once; later calls wait for
    /// the first.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.openInitialStack() }
        startTask = task
        await task.value
    }

    /// Opens the stores, then follows account changes, CloudKit events and
    /// remote store changes until the calling task is cancelled.
    public func run() async {
        await start()
        if options.needsAccountStatus, accountStatus == .couldNotDetermine {
            // Launch gave up waiting; ask again without the launch deadline.
            await refreshAccountStatus(timeout: .seconds(30))
        }
        await processHistory()

        let accountChanges = options.needsAccountStatus ? accountProvider?.accountChanges() : nil
        let syncEvents = CloudSyncEvent.events(notificationCenter: notificationCenter)
        let remoteChanges = RemoteChangeMonitor(
            storeURL: options.location.syncedStoreURL, notificationCenter: notificationCenter
        ).changes()

        await withDiscardingTaskGroup { group in
            if let accountChanges {
                group.addTask {
                    for await _ in accountChanges {
                        await self.refreshAccountStatus()
                    }
                }
            }
            group.addTask {
                for await event in syncEvents {
                    await self.record(event)
                }
            }
            group.addTask {
                for await _ in remoteChanges {
                    await self.processHistory()
                }
            }
        }
    }

    /// Re-reads the account status and history. Call when the app becomes
    /// active: account changes made in the Settings app may not post
    /// `CKAccountChanged` to a suspended app.
    public func refresh() async {
        await start()
        if options.needsAccountStatus {
            await refreshAccountStatus()
        }
        await processHistory()
    }

    /// Every non-empty `StoreChangeSet` read from now on.
    public func storeChanges() -> AsyncStream<StoreChangeSet> {
        let (stream, continuation) = AsyncStream.makeStream(of: StoreChangeSet.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: - Account

    private func openInitialStack() async {
        var status: CloudAccountStatus?
        if options.needsAccountStatus, let accountProvider {
            status = await accountProvider.accountStatus(timeout: options.accountStatusTimeout, clock: clock)
            accountStatus = status
        }
        await install(Self.makeStack(bootstrap, mode: options.syncMode(for: status), options: options))
    }

    func refreshAccountStatus(timeout: Duration = .seconds(10)) async {
        guard options.needsAccountStatus, let accountProvider else { return }
        let status = await accountProvider.accountStatus(timeout: timeout, clock: clock)
        await apply(accountStatus: status)
    }

    /// Records `status` and reopens the store if it changes whether CloudKit
    /// can run.
    func apply(accountStatus status: CloudAccountStatus) async {
        accountStatus = status
        guard !isTransitioning else {
            pendingAccountStatus = status
            return
        }
        guard let stack, stack.mode.isPersistent else { return }
        // CloudKit already failed to open this store; retrying on every
        // account refresh would rebuild the UI each time the app becomes
        // active. It is retried on the next launch instead.
        if case .localOnly(.cloudKitFailed) = stack.mode { return }
        // A timed-out or failed status query (a cold `cloudd`, an XPC or
        // network error) is not evidence that the user signed out. Leaving
        // CloudKit on it would stop mirroring and rebuild the UI, then flip
        // back on the next answer. Only a definite `.noAccount`, `.restricted`
        // or `.temporarilyUnavailable` turns sync off.
        if stack.mode.isCloudKit, status == .couldNotDetermine { return }
        let desired = options.syncMode(for: status)
        guard desired.isCloudKit != stack.mode.isCloudKit else { return }

        Log.data.notice(
            "iCloud account is now \(status.rawValue, privacy: .public); reopening the store")
        isTransitioning = true
        // Flush pending edits so nothing is lost when the container is
        // replaced. Writers on other contexts save their own work.
        do {
            try stack.container.mainContext.save()
        } catch {
            Log.data.error(
                "Saving before the sync mode change failed: \(String(describing: error), privacy: .public)")
        }
        await install(Self.makeStack(bootstrap, mode: desired, options: options))
        isTransitioning = false

        if let pending = pendingAccountStatus {
            pendingAccountStatus = nil
            await apply(accountStatus: pending)
        }
    }

    private func install(_ newStack: PersistenceStack) async {
        stack = newStack
        generation += 1
        activity = CloudSyncActivity()
        tracker = PersistentHistoryTracker(
            consumer: Self.historyConsumer,
            container: newStack.container,
            cursors: HistoryCursorStore(modelContainer: newStack.derivedContainer),
            startPosition: .latest,
            clock: clock
        )
        await processHistory()
    }

    /// Opens the stores off the main actor: migrations and CloudKit setup
    /// can take a moment.
    @concurrent
    private nonisolated static func makeStack(
        _ bootstrap: PersistenceBootstrap,
        mode: SyncMode,
        options: PersistenceOptions
    ) async -> PersistenceStack {
        bootstrap.makeStack(mode: mode, options: options)
    }

    // MARK: - Sync activity and history

    func record(_ event: CloudSyncEvent) async {
        activity.record(event)
        if let error = event.error {
            Log.data.error(
                "CloudKit \(event.kind.rawValue, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code) \(error.message, privacy: .public)"
            )
        }
        if event.kind == .import, event.isFinished, event.succeeded {
            await processHistory()
        }
    }

    /// Reads new persistent history and publishes it.
    public func processHistory() async {
        guard let tracker else { return }
        do {
            let changes = try await tracker.fetchNewChanges()
            guard !changes.isEmpty else { return }
            lastChanges = changes
            lastChangesAt = clock.now
            if changes.includesRemoteChanges {
                Log.data.info(
                    "Imported \(changes.importedTransactionCount) transactions from iCloud")
            }
            for continuation in subscribers.values {
                continuation.yield(changes)
            }
        } catch {
            Log.data.error("Reading history failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - App lifecycle

extension PersistenceController: AppLifecycleParticipant {
    /// Saves pending UI edits whenever the app leaves the foreground.
    ///
    /// Becoming active is not handled here: the app calls `refresh()` from
    /// its own task (see `AppEnvironment.handleScenePhase`), so a slow iCloud
    /// account query never holds up the other services' phase changes.
    public nonisolated func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        guard transition.to != .active else { return }
        await saveOnLeavingForeground(transition)
    }

    private func saveOnLeavingForeground(_ transition: AppPhaseTransition) {
        do {
            try saveMainContext()
        } catch {
            Log.data.error(
                "Saving on \(transition.description, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Saves the synced store's main context if it has unsaved changes.
    ///
    /// Reads the container from the current `stack` every time, so a save
    /// after a sync-mode switch goes to the store that is open now. Does
    /// nothing before `start()` has opened the stores.
    public func saveMainContext() throws {
        guard let context = stack?.container.mainContext, context.hasChanges else { return }
        try signposter.withInterval(.dbSave) { try context.save() }
    }
}
