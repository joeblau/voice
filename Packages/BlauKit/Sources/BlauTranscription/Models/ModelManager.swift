import BlauCore
import BlauTelemetry
import Foundation
import Observation
import os

/// Owns the on-device models: downloads them, verifies them, warms them up,
/// reports progress and disk usage, and deletes them.
///
/// One instance lives for the app's lifetime (created in the composition
/// root and shared through the SwiftUI environment). Call ``start()`` once
/// at launch. From then on the manager works through the manifest in order,
/// one model at a time:
///
/// 1. **Installed and warmed up on this OS** → ``ModelState/ready`` with no
///    network and no loading. This is the offline-launch path.
/// 2. **Installed, not yet warmed up** (fresh install or OS update) →
///    ``ModelState/preparing``: loaded once with Core ML so the Neural
///    Engine compile happens now rather than on the first sentence.
/// 3. **Missing** → downloaded when the network policy allows (Wi-Fi only by
///    default), resuming partial files and retrying transient failures,
///    with every file checked against its pinned SHA-256; then warmed up.
///
/// Required models come first; the optional second-pass model follows if
/// ``ModelPreferences/downloadsOptionalModels`` is on. Downloads wait (and
/// resume by themselves) while offline or on cellular under the Wi-Fi-only
/// policy.
///
/// Downstream components load models from ``directory(for:)``; see
/// docs/models.md for the FluidAudio call that goes with each model.
@MainActor
@Observable
public final class ModelManager {
    // MARK: Observable state

    /// Every model in the manifest and where it is.
    public private(set) var states: [ModelID: ModelState]

    /// Bytes each model occupies on disk, including partial downloads.
    /// Refreshed after installs and deletes, and by ``refreshDiskUsage()``.
    public private(set) var diskUsage: [ModelID: Int64] = [:]

    /// The latest network status.
    public private(set) var network: NetworkStatus

    /// Whether the model store reads back as excluded from backup. `nil`
    /// until ``start()`` has prepared the store.
    public private(set) var isExcludedFromBackup: Bool?

    /// Whether ``start()`` has read what is installed. Until then every
    /// model reads as ``ModelState/notDownloaded`` and ``setupStatus`` is
    /// ``ModelSetupStatus/Phase/checking``.
    public private(set) var hasCheckedInstalledModels = false

    /// How long each model's last warm-up took.
    public private(set) var warmUpDurations: [ModelID: Duration] = [:]

    /// The user's download settings. Changing them is saved and takes
    /// effect immediately: turning on Wi-Fi only stops a download running
    /// over cellular (it waits for Wi-Fi and resumes from its partial
    /// file), and turning off optional models stops theirs.
    public var preferences: ModelPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferencesStore.save(preferences)
            preferencesChanged(from: oldValue)
        }
    }

    /// Lets this launch download over cellular even under the Wi-Fi-only
    /// policy, without changing the saved preference ("Download now" in
    /// onboarding). Choosing Wi-Fi only in ``preferences`` ends it.
    public private(set) var allowsExpensiveNetworkThisSession = false

    public let manifest: ModelManifest

    // MARK: Dependencies

    private let store: ModelStore
    private let downloader: ModelDownloader
    private let networkMonitor: any NetworkMonitor
    private let warmer: any ModelWarmer
    private let preferencesStore: any ModelPreferencesStore
    private let clock: any BlauClock
    private let systemVersion: String
    private let signposter: Signposter

    // MARK: Work bookkeeping

    private var isStarted = false
    private var worker: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    /// The model the worker is on.
    private var current: ModelID?
    /// Models that went back to waiting after the network said it was
    /// usable; they retry only when the status changes, so a flaky report
    /// can't spin the worker.
    private var blockedUntilNetworkChange: Set<ModelID> = []
    /// Models already deleted and re-downloaded once after failing to load.
    private var repairAttempted: Set<ModelID> = []

    /// - Parameters:
    ///   - manifest: The models to manage. Production uses the pinned
    ///     manifest.
    ///   - store: Where models live on disk.
    ///   - transport: Moves bytes; `URLSession` in production.
    ///   - networkMonitor: Network path status; `NWPathMonitor` in production.
    ///   - warmer: Loads a model once after install; Core ML in production.
    ///   - preferencesStore: Persists ``preferences``.
    ///   - clock: Time for retry backoff and warm-up measurements.
    ///   - retryPolicy: Per-file retry budget.
    ///   - systemVersion: Warm-ups are recorded against this, so an OS
    ///     update (which drops Core ML's compiled cache) triggers a new one.
    ///   - host: The model registry.
    ///   - signposter: Where `model.download` and `model.warmUp` intervals go.
    public init(
        manifest: ModelManifest = .pinned,
        store: ModelStore,
        transport: any ModelTransport = URLSessionModelTransport(),
        networkMonitor: any NetworkMonitor = SystemNetworkMonitor(),
        warmer: any ModelWarmer = CoreMLModelWarmer(),
        preferencesStore: any ModelPreferencesStore = UserDefaultsModelPreferencesStore(),
        clock: any BlauClock = SystemClock(),
        retryPolicy: ModelRetryPolicy = .default,
        systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        host: URL = ModelDescriptor.defaultHost,
        signposter: Signposter = Signposts.asr
    ) {
        self.manifest = manifest
        self.store = store
        self.downloader = ModelDownloader(transport: transport, clock: clock, retryPolicy: retryPolicy, host: host)
        self.networkMonitor = networkMonitor
        self.warmer = warmer
        self.preferencesStore = preferencesStore
        self.clock = clock
        self.systemVersion = systemVersion
        self.signposter = signposter
        self.preferences = preferencesStore.load()
        self.network = networkMonitor.current
        self.states = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, .notDownloaded) })
    }

    // MARK: Queries

    /// The state of `id` (`notDownloaded` for a model not in the manifest).
    public func state(of id: ModelID) -> ModelState {
        states[id] ?? .notDownloaded
    }

    /// Whether every required model is ready.
    public var isReady: Bool {
        manifest.required.allSatisfy { state(of: $0.id) == .ready }
    }

    /// Where `id` is installed, once it is. Load it from here with
    /// FluidAudio (docs/models.md).
    public func directory(for id: ModelID) -> URL? {
        guard let descriptor = manifest[id], state(of: id).isInstalled else { return nil }
        return store.directory(for: descriptor)
    }

    /// Total bytes on disk across all models.
    public var totalDiskUsage: Int64 {
        diskUsage.values.reduce(0, +)
    }

    /// Progress of the required models, for onboarding.
    public var setupStatus: ModelSetupStatus {
        var received: Int64 = 0
        var total: Int64 = 0
        guard hasCheckedInstalledModels else {
            let total = manifest.required.reduce(0) { $0 + $1.totalBytes }
            return ModelSetupStatus(phase: .checking, bytesReceived: 0, totalBytes: total)
        }
        var phases: [ModelSetupStatus.Phase] = []
        for descriptor in manifest.required {
            total += descriptor.totalBytes
            switch state(of: descriptor.id) {
            case .ready:
                received += descriptor.totalBytes
                phases.append(.ready)
            case .preparing:
                received += descriptor.totalBytes
                phases.append(.preparing)
            case .downloading(let bytes, _):
                received += bytes
                phases.append(.downloading)
            case .queued:
                phases.append(.downloading)
            case .waiting(let requirement):
                phases.append(.waiting(for: requirement))
            case .failed(let failure):
                phases.append(.failed(descriptor.id, failure))
            case .notDownloaded:
                phases.append(.needsDownload)
            }
        }
        let phase: ModelSetupStatus.Phase =
            phases.first { if case .failed = $0 { true } else { false } }
            ?? phases.first { $0 == .needsDownload }
            ?? phases.first { if case .waiting = $0 { true } else { false } }
            ?? phases.first { $0 == .downloading }
            ?? phases.first { $0 == .preparing }
            ?? .ready
        return ModelSetupStatus(phase: phase, bytesReceived: received, totalBytes: total)
    }

    // MARK: Lifecycle

    /// Prepares the store, reads what is installed and starts working
    /// through the manifest. Returns once the initial states are known;
    /// downloads and warm-ups continue in the background. Calling it again
    /// does nothing.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        let store = store
        let manifest = manifest

        do {
            isExcludedFromBackup = try await Self.offMain { try store.prepare() }
            if isExcludedFromBackup == false {
                Log.asr.fault("Model store is not excluded from backup")
            }
        } catch {
            isExcludedFromBackup = false
            Log.asr.fault("Couldn't prepare the model store: \(error.localizedDescription, privacy: .public)")
        }

        let installations = await Self.offMain { () -> [ModelID: ModelInstallation] in
            store.removeStaleContent(keeping: manifest)
            var found: [ModelID: ModelInstallation] = [:]
            for descriptor in manifest.models {
                found[descriptor.id] = store.installation(of: descriptor)
            }
            return found
        }

        for descriptor in manifest.models {
            let id = descriptor.id
            if let installation = installations[id] {
                states[id] = installation.warmedUpOn == systemVersion ? .ready : .preparing
            } else if wantsDownload(id) {
                states[id] = .queued
            } else {
                states[id] = .notDownloaded
            }
        }
        hasCheckedInstalledModels = true
        let summary = manifest.models.map { "\($0.id.rawValue)=\(Self.label(state(of: $0.id)))" }
        Log.asr.notice("Model manager started: \(summary.joined(separator: " "), privacy: .public)")

        let updates = networkMonitor.updates()
        networkTask = Task { [weak self] in
            for await status in updates {
                guard let self else { return }
                self.networkChanged(to: status)
            }
        }

        await refreshDiskUsage()
        scheduleWork()
    }

    /// Waits until the manager has nothing left it can do right now (every
    /// model is ready, failed, not wanted, or waiting for the network).
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: User actions

    /// Downloads `id` now (an optional model, a deleted one, or a retry
    /// after a failure). A model that failed to load is deleted and
    /// downloaded again.
    public func download(_ id: ModelID) async {
        guard manifest[id] != nil else { return }
        switch state(of: id) {
        case .failed(.loadFailed):
            await delete(id)
            repairAttempted.remove(id)
        case .notDownloaded, .failed, .waiting:
            break
        case .queued, .downloading, .preparing, .ready:
            return
        }
        blockedUntilNetworkChange.remove(id)
        states[id] = .queued
        scheduleWork()
    }

    /// Downloads over cellular for the rest of this launch, without
    /// changing the saved Wi-Fi-only preference.
    public func allowExpensiveNetworkThisSession() {
        allowsExpensiveNetworkThisSession = true
        blockedUntilNetworkChange.removeAll()
        scheduleWork()
    }

    /// Stops any download or warm-up of `id` and deletes its files. It is
    /// downloaded again on the next launch if it downloads automatically
    /// (required, the text embedding model, or the second pass with
    /// ``ModelPreferences/downloadsOptionalModels`` on), or now with
    /// ``download(_:)``.
    public func delete(_ id: ModelID) async {
        guard manifest[id] != nil else { return }
        await cancelWork(on: id)
        let store = store
        do {
            try await Self.offMain { try store.remove(id) }
            Log.asr.notice("Deleted model \(id.rawValue, privacy: .public)")
        } catch {
            Log.asr.error(
                "Couldn't delete model \(id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        states[id] = .notDownloaded
        warmUpDurations[id] = nil
        await refreshDiskUsage()
        scheduleWork()
    }

    /// Re-measures ``diskUsage``.
    public func refreshDiskUsage() async {
        let store = store
        let ids = manifest.models.map(\.id)
        diskUsage = await Self.offMain {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, store.diskUsage(of: $0)) })
        }
    }

    // MARK: Scheduling

    private enum Work {
        case download(ModelDescriptor)
        case warmUp(ModelDescriptor)
    }

    private func scheduleWork() {
        guard isStarted, worker == nil, nextWork() != nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !Task.isCancelled, let work = nextWork() {
            switch work {
            case .download(let descriptor):
                current = descriptor.id
                await download(descriptor)
            case .warmUp(let descriptor):
                current = descriptor.id
                await warmUp(descriptor)
            }
            current = nil
        }
        worker = nil
    }

    private func nextWork() -> Work? {
        for descriptor in manifest.models {
            switch state(of: descriptor.id) {
            case .queued:
                return .download(descriptor)
            case .waiting where !blockedUntilNetworkChange.contains(descriptor.id) && unmetRequirement == nil:
                return .download(descriptor)
            case .preparing:
                return .warmUp(descriptor)
            default:
                continue
            }
        }
        return nil
    }

    /// Whether `id` downloads without the user asking: required models,
    /// optional ones that don't follow the "Download High-Accuracy Model"
    /// preference (the text embedding model), and the rest while it is on.
    private func wantsDownload(_ id: ModelID) -> Bool {
        id.isRequired || !id.followsOptionalModelsPreference || preferences.downloadsOptionalModels
    }

    private var allowsExpensiveNetwork: Bool {
        preferences.downloadPolicy == .anyNetwork || allowsExpensiveNetworkThisSession
    }

    /// What the network must offer before a download can start, or `nil`
    /// if it can start now.
    private var unmetRequirement: NetworkRequirement? {
        if !network.isReachable { return .connection }
        if !allowsExpensiveNetwork && !network.isUnmetered { return .unmeteredNetwork }
        return nil
    }

    private func networkChanged(to status: NetworkStatus) {
        guard status != network else { return }
        network = status
        Log.asr.info(
            "Network: reachable=\(status.isReachable, privacy: .public) expensive=\(status.isExpensive, privacy: .public) constrained=\(status.isConstrained, privacy: .public)"
        )
        blockedUntilNetworkChange.removeAll()
        scheduleWork()
    }

    private func preferencesChanged(from old: ModelPreferences) {
        var stopped: ModelID?
        if preferences.downloadsOptionalModels != old.downloadsOptionalModels {
            for descriptor in manifest.optional where descriptor.id.followsOptionalModelsPreference {
                switch state(of: descriptor.id) {
                case .notDownloaded where preferences.downloadsOptionalModels:
                    states[descriptor.id] = .queued
                case .queued, .waiting:
                    if !preferences.downloadsOptionalModels { states[descriptor.id] = .notDownloaded }
                case .downloading where !preferences.downloadsOptionalModels:
                    if cancelDownload(of: descriptor.id, then: .notDownloaded) { stopped = descriptor.id }
                default:
                    break
                }
            }
        }
        if preferences.downloadPolicy != old.downloadPolicy {
            // Choosing Wi-Fi only is explicit, so it also ends a "download
            // using cellular data" override for this launch.
            if preferences.downloadPolicy == .wifiOnly {
                allowsExpensiveNetworkThisSession = false
            }
            // A transfer started under the old policy captured permission
            // to use cellular; stop it if that is no longer allowed. Its
            // partial file stays, so it resumes on Wi-Fi.
            if let id = current, id != stopped, case .downloading = state(of: id),
                unmetRequirement == .unmeteredNetwork
            {
                Log.asr.notice("Download of \(id.rawValue, privacy: .public) paused: Wi-Fi only was turned on")
                cancelDownload(of: id, then: .waiting(for: .unmeteredNetwork))
            }
        }
        blockedUntilNetworkChange.removeAll()
        scheduleWork()
    }

    /// Stops the worker if it is on `id`, and waits for it to stop.
    private func cancelWork(on id: ModelID) async {
        guard current == id, let worker else { return }
        worker.cancel()
        await worker.value
    }

    /// Cancels the worker now if it is downloading `id`, then moves the
    /// model to `state` once the worker has stopped. Files already on disk
    /// (including partial ones) are kept. Returns whether it cancelled.
    @discardableResult
    private func cancelDownload(of id: ModelID, then state: ModelState) -> Bool {
        guard current == id, let worker else { return false }
        worker.cancel()
        Task {
            await worker.value
            if case .downloading = self.state(of: id) {
                states[id] = state
            }
            // Schedule in the same step as the state change, so
            // `waitUntilIdle()` never sees a gap with work left to do.
            scheduleWork()
            await refreshDiskUsage()
        }
        return true
    }

    // MARK: Download

    private func download(_ descriptor: ModelDescriptor) async {
        let id = descriptor.id
        if let requirement = unmetRequirement {
            states[id] = .waiting(for: requirement)
            Log.asr.notice(
                "Model \(id.rawValue, privacy: .public) waiting for \(Self.label(.waiting(for: requirement)), privacy: .public)"
            )
            return
        }

        states[id] = .downloading(bytesReceived: 0, totalBytes: descriptor.totalBytes)
        Log.asr.notice(
            "Downloading model \(id.rawValue, privacy: .public) (\(descriptor.totalBytes, privacy: .public) bytes, revision \(descriptor.revision, privacy: .public))"
        )
        let interval = signposter.beginInterval(.modelDownload)
        defer { interval.end() }

        // Progress arrives from URLSession's queue; keep only the newest
        // value and apply it here, in order.
        let (updates, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        let applyProgress = Task { [weak self] in
            for await bytes in updates {
                guard let self, case .downloading = self.state(of: id) else { continue }
                self.states[id] = .downloading(bytesReceived: bytes, totalBytes: descriptor.totalBytes)
            }
        }

        let started = clock.uptime
        do {
            try await downloader.download(
                descriptor, store: store, allowsExpensiveNetwork: allowsExpensiveNetwork
            ) { bytes in
                continuation.yield(bytes)
            }
            continuation.finish()
            await applyProgress.value

            let store = store
            let now = clock.now
            _ = try await Self.offMain { try store.install(descriptor, installedAt: now) }
            let elapsed = clock.uptime - started
            Log.asr.notice(
                "Installed model \(id.rawValue, privacy: .public) in \(Self.milliseconds(elapsed), privacy: .public) ms"
            )
            states[id] = .preparing
            await refreshDiskUsage()
        } catch {
            continuation.finish()
            await applyProgress.value
            handleDownloadFailure(error, for: id)
        }
    }

    private func handleDownloadFailure(_ error: any Error, for id: ModelID) {
        switch error {
        case is CancellationError:
            // Whoever cancelled sets the state.
            Log.asr.notice("Download of \(id.rawValue, privacy: .public) cancelled")
        case ModelDownloadError.offline:
            states[id] = .waiting(for: .connection)
            blockedUntilNetworkChange.insert(id)
            Log.asr.notice("Download of \(id.rawValue, privacy: .public) paused: offline")
        case ModelDownloadError.requiresUnmeteredNetwork:
            states[id] = .waiting(for: .unmeteredNetwork)
            blockedUntilNetworkChange.insert(id)
            Log.asr.notice("Download of \(id.rawValue, privacy: .public) paused: waiting for Wi-Fi")
        case let error as ModelDownloadError:
            states[id] = .failed(.download(error))
            Log.asr.error(
                "Download of \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        default:
            states[id] = .failed(.download(.storage(error.localizedDescription)))
            Log.asr.error(
                "Download of \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Warm-up

    private func warmUp(_ descriptor: ModelDescriptor) async {
        let id = descriptor.id
        let directory = store.directory(for: descriptor)
        let warmer = warmer
        let started = clock.uptime
        do {
            try await signposter.withInterval(.modelWarmUp) {
                try await warmer.warmUp(descriptor, at: directory)
            }
            let elapsed = clock.uptime - started
            warmUpDurations[id] = elapsed
            let store = store
            let systemVersion = systemVersion
            try? await Self.offMain { try store.markWarmedUp(descriptor, systemVersion: systemVersion) }
            states[id] = .ready
            Log.asr.notice(
                "Model \(id.rawValue, privacy: .public) ready; warm-up took \(Self.milliseconds(elapsed), privacy: .public) ms"
            )
        } catch is CancellationError {
            Log.asr.notice("Warm-up of \(id.rawValue, privacy: .public) cancelled")
        } catch {
            Log.asr.error(
                "Model \(id.rawValue, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)"
            )
            await repairOrFail(descriptor, error: error)
        }
    }

    /// A model that won't load is re-hashed. Damaged files are deleted and
    /// downloaded again, once; intact files mean the model can't run here.
    private func repairOrFail(_ descriptor: ModelDescriptor, error: any Error) async {
        let id = descriptor.id
        let store = store
        guard !repairAttempted.contains(id) else {
            states[id] = .failed(.loadFailed(error.localizedDescription))
            return
        }
        repairAttempted.insert(id)
        let corrupt = await Self.offMain { store.corruptFiles(in: descriptor) }
        guard !corrupt.isEmpty else {
            states[id] = .failed(.loadFailed(error.localizedDescription))
            return
        }
        Log.asr.error(
            "Model \(id.rawValue, privacy: .public) has \(corrupt.count, privacy: .public) damaged files; downloading again"
        )
        try? await Self.offMain { try store.remove(id) }
        states[id] = .queued
    }

    // MARK: Helpers

    /// Runs blocking file work off the main actor.
    @concurrent
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async rethrows -> T
    {
        try work()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    private static func label(_ state: ModelState) -> String {
        switch state {
        case .notDownloaded: "notDownloaded"
        case .queued: "queued"
        case .waiting(.connection): "waiting(connection)"
        case .waiting(.unmeteredNetwork): "waiting(wifi)"
        case .downloading: "downloading"
        case .preparing: "preparing"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
