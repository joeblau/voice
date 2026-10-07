import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Observation
import os

/// Runs the incremental indexer (#63) for the app's current stores, and
/// publishes its status for Settings.
///
/// The synced store's container is replaced when the iCloud account
/// changes (`PersistenceController.generation`), and models, contexts and
/// history identifiers of the old container are invalid afterwards, so the
/// controller builds a new `MemoryIndexer` for every generation. The index
/// file itself (`StoreLocation.memoryIndexURL`) is opened once and shared:
/// both sync modes use the same store file. An in-memory store (previews,
/// tests, a store that failed to open) gets no index.
@MainActor
@Observable
public final class MemoryIndexingController {
    /// The indexer's status, or `nil` while there is no index (not started,
    /// or the store is in memory).
    public private(set) var status: MemoryIndexingStatus?

    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let embedder: (any MemoryChunkEmbedding)?
    @ObservationIgnored private let performance: (any PerformanceLevelProviding)?
    @ObservationIgnored private let chunker: MemoryChunker
    @ObservationIgnored private let configuration: MemoryIndexer.Configuration
    @ObservationIgnored private let openIndex: @Sendable (URL) throws -> MemoryIndex
    @ObservationIgnored private var indexes: [URL: MemoryIndex] = [:]
    @ObservationIgnored private var follower: Task<Void, Never>?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var statusFollower: Task<Void, Never>?
    @ObservationIgnored private var installedGeneration: Int?
    /// The newest generation an install started for; an older install
    /// that finishes opening the file later gives way to it.
    @ObservationIgnored private var requestedGeneration: Int?
    @ObservationIgnored private var installWaiters: [CheckedContinuation<Void, Never>] = []

    /// The indexer for the current stores, if any.
    @ObservationIgnored public private(set) var indexer: MemoryIndexer?

    /// The current store and index for Grok's memory tools (#68), or `nil`
    /// until the stores are open. An in-memory store (or an index file that
    /// couldn't be opened) gets a context with no index: the tools then read
    /// the knowledge base and facts from the store alone. Replaced with
    /// every store generation.
    @ObservationIgnored public private(set) var toolContext: MemoryToolService.Context?

    /// - Parameters:
    ///   - embedder: The shared text embedding service (#60). Without a
    ///     model the index is built for keyword search and embedded later.
    ///   - performance: The thermal and power policy (#75) indexing defers
    ///     to, through an `IndexingGate`.
    ///   - openIndex: Opens the index file; tests pass an in-memory index.
    public init(
        persistence: PersistenceController,
        embedder: (any MemoryChunkEmbedding)?,
        performance: (any PerformanceLevelProviding)?,
        chunker: MemoryChunker = MemoryChunker(),
        configuration: MemoryIndexer.Configuration = MemoryIndexer.Configuration(),
        openIndex: @escaping @Sendable (URL) throws -> MemoryIndex = { try MemoryIndex.open(at: $0) }
    ) {
        self.persistence = persistence
        self.embedder = embedder
        self.performance = performance
        self.chunker = chunker
        self.configuration = configuration
        self.openIndex = openIndex
    }

    /// Follows the persistence controller's stores and indexes them. Safe to
    /// call more than once.
    public func start() {
        guard follower == nil else { return }
        let persistence = persistence
        follower = Task { [weak self] in
            for await generation in Observations({ persistence.generation }) {
                guard let self else { return }
                await self.install(persistence.stack, generation: generation)
            }
        }
    }

    /// Stops indexing (the work done so far is kept and resumed later).
    public func stop() {
        follower?.cancel()
        follower = nil
        uninstall()
        installedGeneration = nil
        let waiters = installWaiters
        installWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// The store may have changed, or the embedding model may have been
    /// installed: check now. Called when the app becomes active.
    public func refresh() {
        guard let indexer else { return }
        Task { await indexer.signal() }
    }

    /// Re-reads every source (Settings → Rebuild Index).
    public func rebuild() {
        guard let indexer else { return }
        Task { await indexer.requestFullPass() }
    }

    /// A rebuild or embedding backlog is waiting: worth a background
    /// processing task.
    public var needsBackgroundWork: Bool { status?.hasPendingWork ?? false }

    /// Opens the stores if needed and waits until the indexer has nothing
    /// left to do, or the calling task is cancelled (the background task
    /// expired). The work is done by the indexer's own task, so it simply
    /// stops where it is when the process is suspended, and resumes from
    /// its checkpoint.
    ///
    /// - Returns: Whether everything is done.
    public func performBackgroundWork() async -> Bool {
        start()
        await persistence.start()
        await waitUntilInstalled()
        guard let indexer else { return true }
        await indexer.waitUntilIdle()
        let remaining = await indexer.currentStatus
        // The status stream delivers on its own task; don't let a caller
        // read a stale one.
        if self.indexer === indexer { status = remaining }
        return !Task.isCancelled && !remaining.hasPendingWork
    }

    // MARK: - Installing an indexer per store generation

    private func waitUntilInstalled() async {
        guard installedGeneration != persistence.generation || persistence.stack == nil else { return }
        await withCheckedContinuation { installWaiters.append($0) }
    }

    func install(_ stack: PersistenceStack?, generation: Int) async {
        guard let stack else { return }
        guard installedGeneration != generation else { return }
        requestedGeneration = generation
        uninstall()
        defer {
            if installedGeneration == generation {
                let waiters = installWaiters
                installWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        guard stack.mode.isPersistent else {
            installedGeneration = generation
            status = nil
            toolContext = MemoryToolService.Context(container: stack.container, index: nil)
            return
        }

        let url = stack.location.memoryIndexURL
        let index: MemoryIndex
        do {
            if let open = indexes[url] {
                index = open
            } else {
                let openIndex = openIndex
                index = try await Task.detached(priority: .utility) { try openIndex(url) }.value
                indexes[url] = index
            }
        } catch {
            Log.memory.error("Memory index unavailable: \(String(describing: error), privacy: .public)")
            installedGeneration = generation
            status = nil
            toolContext = MemoryToolService.Context(container: stack.container, index: nil)
            return
        }
        // The stores may have been replaced while the file opened.
        guard requestedGeneration == generation, installedGeneration != generation else { return }

        let indexer = MemoryIndexer(
            index: index,
            reader: SwiftDataMemorySources(container: stack.container),
            feed: SwiftDataMemoryChangeFeed(
                container: stack.container, cursors: HistoryCursorStore(modelContainer: stack.derivedContainer),
                storeURL: stack.syncedStoreURL),
            embedder: embedder,
            chunker: chunker,
            gate: performance.map { IndexingGate(performance: $0) },
            configuration: configuration)
        self.indexer = indexer
        toolContext = MemoryToolService.Context(container: stack.container, index: index, indexer: indexer)
        installedGeneration = generation
        status = MemoryIndexingStatus()
        runner = Task.detached(priority: .utility) { await indexer.run() }
        statusFollower = Task { [weak self] in
            for await status in await indexer.statusUpdates() {
                guard let self, self.indexer === indexer else { return }
                self.status = status
            }
        }
        Log.memory.notice("Memory indexer started for store generation \(generation, privacy: .public)")
    }

    private func uninstall() {
        runner?.cancel()
        statusFollower?.cancel()
        runner = nil
        statusFollower = nil
        indexer = nil
        toolContext = nil
        status = nil
    }
}
