import BlauCore
import BlauTelemetry
import Foundation
import os

/// Keeps the memory index (#62) in step with the synced store (#63): text
/// written on this device or imported by CloudKit from the user's other
/// devices becomes searchable without a rebuild.
///
/// ```swift
/// let indexer = MemoryIndexer(
///     index: index,
///     reader: SwiftDataMemorySources(container: stack.container),
///     feed: SwiftDataMemoryChangeFeed(
///         container: stack.container, cursors: HistoryCursorStore(modelContainer: stack.derivedContainer),
///         storeURL: stack.syncedStoreURL),
///     embedder: textEmbeddings,
///     gate: IndexingGate(performance: performancePolicy))
/// Task(priority: .utility) { await indexer.run() }
/// ```
///
/// **Incremental indexing.** The feed reports the store's persistent history
/// (local saves and CloudKit imports both post
/// `NSPersistentStoreRemoteChange`) traced to the sources whose chunks
/// changed (`SwiftDataMemoryChangeResolver`). Each changed source is read
/// and chunked again; a chunk whose key text hash (`contentHash`) and
/// vector model version are unchanged keeps its vector, so only the
/// chunks that actually changed are embedded. Sources that no longer exist
/// are removed (sweeps compare the index with the store). The history
/// cursor is committed only after the changes are written, so a kill in
/// between replays them.
///
/// **Full pass.** A new index (new device, deleted or recreated file),
/// expired history, a chunking change, or an import too large to apply
/// change by change starts a full pass: every conversation, document and
/// fact, newest first, `conversationsPerStep` conversations at a time. Its
/// checkpoint (the last source written) is saved in the index after every
/// step, so it resumes where it stopped after a relaunch, and search works
/// on what is done while it runs. It ends by removing orphans and
/// recording the rebuild. The app runs it in the foreground and in a
/// `BGProcessingTask` (see docs/memory-indexer.md).
///
/// **Embedding backlog.** Chunks without a vector of the current model
/// (the model was installed or replaced after they were indexed, or
/// embedding failed) are embedded newest first.
///
/// **Throttling.** Every pass and step waits on the `IndexingGate`, which
/// defers work while the device is warm or in Low Power Mode and holds it
/// while critical (#75).
///
/// All work runs one piece at a time on the actor, so a full pass and an
/// incremental change never write the same source concurrently.
public actor MemoryIndexer {
    public struct Configuration: Sendable {
        /// How long `run()` waits after a change signal before reading
        /// history, so a burst of saves is read once.
        public var debounce: Duration
        /// Conversations read per full-pass step (and per read of an
        /// incremental pass).
        public var conversationsPerStep: Int
        /// Documents and facts read per full-pass step.
        public var sourcesPerStep: Int
        /// Chunks gathered before they are embedded and written in one
        /// transaction.
        public var writeBatchSize: Int
        /// Chunks embedded per embedding-backlog step.
        public var embeddingBatchSize: Int
        /// More changed sources than this in one history read start a full
        /// pass instead (a large CloudKit import), which is newest first and
        /// resumable.
        public var incrementalLimit: Int
        /// How long `run()` waits after a failed pass before trying again.
        public var retryDelay: Duration

        public init(
            debounce: Duration = .seconds(5),
            conversationsPerStep: Int = 16,
            sourcesPerStep: Int = 256,
            writeBatchSize: Int = 256,
            embeddingBatchSize: Int = 256,
            incrementalLimit: Int = 500,
            retryDelay: Duration = .seconds(60)
        ) {
            self.debounce = debounce
            self.conversationsPerStep = max(1, conversationsPerStep)
            self.sourcesPerStep = max(1, sourcesPerStep)
            self.writeBatchSize = max(1, writeBatchSize)
            self.embeddingBatchSize = max(1, embeddingBatchSize)
            self.incrementalLimit = max(1, incrementalLimit)
            self.retryDelay = retryDelay
        }
    }

    /// What one `apply(_:)` changed.
    public struct ApplyReport: Hashable, Sendable {
        /// Sources re-chunked or removed, by kind.
        public var sources: [MemorySourceKind: Int] = [:]
        /// Sources removed (deleted from the store).
        public var removedSources = 0
        public var chunksWritten = 0
        /// Vectors computed (chunks whose key text changed, or new ones).
        public var embedded = 0
        /// Chunks that kept their vector.
        public var reusedVectors = 0

        public init() {}
    }

    /// `index_state` key of the full-pass checkpoint.
    static let fullPassKey = "indexer.fullPass"
    /// `index_state` key of the chunking the index was built with.
    static let chunkingKey = "indexer.chunking"
    /// `index_state` key of the time zone key texts spell dates in.
    static let timeZoneKey = "indexer.timeZone"

    public nonisolated let index: MemoryIndex
    public nonisolated let configuration: Configuration
    private let reader: any MemorySourceReader
    private let feed: any MemoryChangeFeed
    private let embedder: (any MemoryChunkEmbedding)?
    /// The chunking every source is cut with. Its time zone is the one
    /// pinned in the index (`timeZoneKey`) once `prepareIfNeeded` ran.
    public private(set) var chunker: MemoryChunker
    private let gate: IndexingGate?
    private let clock: any BlauClock

    private var status = MemoryIndexingStatus()
    private var subscribers: [UUID: AsyncStream<MemoryIndexingStatus>.Continuation] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let wakeups: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    private var prepared = false
    private var isRunning = false
    private var isWorking = false
    private var workWaiters: [CheckedContinuation<Void, Never>] = []
    /// History may hold changes not applied yet (true at launch).
    private var changesPending = true
    /// Compare every kind with the store on the first pass: catches
    /// deletions that never reached history (an account switch purge).
    private var sweepAllPending = true
    private var fullPassRequest: Bool?
    private var fullPass: FullPass?
    private var backlogChecked = false
    private var embeddingBlocked = false

    public init(
        index: MemoryIndex,
        reader: any MemorySourceReader,
        feed: any MemoryChangeFeed,
        embedder: (any MemoryChunkEmbedding)?,
        chunker: MemoryChunker = MemoryChunker(),
        gate: IndexingGate? = nil,
        clock: any BlauClock = SystemClock(),
        configuration: Configuration = Configuration()
    ) {
        self.index = index
        self.reader = reader
        self.feed = feed
        self.embedder = embedder
        self.chunker = chunker
        self.gate = gate
        self.clock = clock
        self.configuration = configuration
        (wakeups, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Driving

    /// Indexes until the calling task is cancelled: everything pending at
    /// launch (a rebuild to resume, history not yet applied), then each
    /// change the feed signals. Call once, from a long-lived task.
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let signals = feed.changeSignals()
        let forwarder = Task { [weak self] in
            for await _ in signals { await self?.signal() }
        }
        defer { forwarder.cancel() }

        var wakeIterator = wakeups.makeAsyncIterator()
        while !Task.isCancelled {
            do {
                try await withWorkLock { try await self.drain() }
            } catch is CancellationError {
                break
            } catch {
                record(error)
                try? await clock.sleep(for: configuration.retryDelay)
                continue
            }
            guard await wakeIterator.next() != nil else { break }
            // A conversation saves every couple of seconds; read the burst
            // once.
            try? await clock.sleep(for: configuration.debounce)
        }
    }

    /// Reads history and does all pending work now, in the calling task,
    /// and returns when none is left. Tests drive the indexer with it
    /// instead of `run()`.
    public func runUntilIdle() async throws {
        changesPending = true
        try await withWorkLock { try await self.drain() }
    }

    /// The store may have changed: read history on the next pass. Also
    /// re-checks the embedding backlog (the model may have been installed).
    public func signal() {
        changesPending = true
        backlogChecked = false
        embeddingBlocked = false
        wake.yield()
    }

    /// Re-reads every source, newest first (Settings → Rebuild). With
    /// `reembedAll`, every vector is recomputed too.
    public func requestFullPass(reembedAll: Bool = false) {
        fullPassRequest = (fullPassRequest ?? false) || reembedAll
        if status.rebuild == nil { update { $0.rebuild = MemoryIndexingProgress(completed: 0, total: 0) } }
        wake.yield()
    }

    /// Returns once nothing is pending: the background task waits on this.
    public func waitUntilIdle() async {
        if isIdle { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isIdle {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeIdleWaiter(id) }
        }
    }

    // MARK: - Status

    /// The current status.
    public var currentStatus: MemoryIndexingStatus { status }

    /// The current status, then every change.
    public func statusUpdates() -> AsyncStream<MemoryIndexingStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MemoryIndexingStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private var isIdle: Bool {
        status.activity == .idle && !changesPending && fullPassRequest == nil && fullPass == nil
    }

    private func update(_ body: (inout MemoryIndexingStatus) -> Void) {
        var next = status
        body(&next)
        guard next != status else { return }
        status = next
        for continuation in subscribers.values { continuation.yield(next) }
    }

    private func setActivity(_ activity: MemoryIndexingStatus.Activity) {
        update { $0.activity = activity }
        if isIdle {
            let waiters = idleWaiters.values
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func resumeIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    private func record(_ error: any Error) {
        Log.memory.error("Memory indexing failed: \(String(describing: error), privacy: .public)")
        update { $0.lastError = String(describing: error) }
        setActivity(.idle)
    }

    // MARK: - Work loop

    /// One piece of work at a time, whoever drives it.
    private func withWorkLock(_ body: () async throws -> Void) async throws {
        if isWorking {
            await withCheckedContinuation { workWaiters.append($0) }
        } else {
            isWorking = true
        }
        defer {
            if workWaiters.isEmpty {
                isWorking = false
            } else {
                workWaiters.removeFirst().resume()
            }
        }
        try await body()
    }

    private func drain() async throws {
        try await prepareIfNeeded()
        while true {
            try Task.checkCancellation()
            if changesPending {
                changesPending = false
                try await processChanges()
            } else if let reembedAll = fullPassRequest {
                fullPassRequest = nil
                try await startFullPass(reembedAll: reembedAll || (fullPass?.state.reembedAll ?? false))
            } else if fullPass != nil {
                try await waitForGate(then: .rebuilding)
                try await fullPassStep()
            } else if try await embeddingBacklogRemains() {
                try await waitForGate(then: .embedding)
                try await embeddingStep()
            } else {
                break
            }
        }
        await refreshCounts()
        setActivity(.idle)
    }

    private func waitForGate(then activity: MemoryIndexingStatus.Activity) async throws {
        if let gate, gate.mode != .immediate {
            setActivity(.waiting(gate.mode))
            try await gate.waitUntilAllowed()
        }
        setActivity(activity)
    }

    /// Resumes a saved full pass, or starts one if the index was never
    /// fully built or was built with another chunking.
    private func prepareIfNeeded() async throws {
        guard !prepared else { return }
        update { $0.activity = .starting }
        try await pinTimeZone()
        let lastRebuild = try await index.lastRebuild()
        update { $0.lastRebuild = lastRebuild }
        if let saved = try await loadFullPassState() {
            fullPass = try await makeFullPass(saved)
            Log.memory.notice(
                "Resuming the memory index rebuild at \(saved.completed, privacy: .public) sources")
        } else if lastRebuild == nil {
            // Every source is read anyway: history up to now is covered.
            try await startFullPass(reembedAll: false, skipHistory: true)
        } else if try await index.stateValue(forKey: Self.chunkingKey) != chunkingFingerprint {
            try await startFullPass(reembedAll: false)
        }
        prepared = true
        await refreshCounts()
    }

    /// Key texts spell dates in one time zone for the life of the index:
    /// the zone pinned in it, or, for an index without one, the chunker's
    /// (the device's at launch), which is pinned from then on. Following
    /// the device's zone instead would re-chunk every source and re-embed
    /// every chunk whose date changes, each time the user travels.
    private func pinTimeZone() async throws {
        if let identifier = try await index.stateValue(forKey: Self.timeZoneKey),
            let zone = TimeZone(identifier: identifier)
        {
            chunker.policy.timeZone = zone
        } else {
            try await index.setStateValue(chunker.policy.timeZone.identifier, forKey: Self.timeZoneKey)
        }
    }

    // MARK: - Incremental changes

    private func processChanges() async throws {
        try await waitForGate(then: .indexingChanges)
        var changes: MemorySourceChanges
        do {
            changes = try await feed.fetchChanges()
            if sweepAllPending {
                changes.sweeps.formUnion(MemorySourceKind.allCases)
                sweepAllPending = false
            }
            if changes.isEmpty {
                // Transactions that touched nothing indexed (a voiceprint,
                // the profile block) still move the cursor.
                try await feed.commit()
                return
            }

            if changes.requiresFullPass || (fullPass == nil && changes.sourceCount > configuration.incrementalLimit) {
                // A full pass reads every source as it is now, so it covers
                // these changes. Expired history restarts a running pass:
                // changes behind its checkpoint are unknown.
                Log.memory.notice(
                    "Store changes need a full pass (\(changes.sourceCount, privacy: .public) sources, history reset: \(changes.requiresFullPass, privacy: .public))"
                )
                try await startFullPass(reembedAll: fullPass?.state.reembedAll ?? false)
                try await feed.commit()
                return
            }

            let report = try await apply(changes)
            try await feed.commit()
            update {
                $0.lastIndexed = clock.now
                $0.lastError = nil
            }
            Log.memory.info(
                """
                Indexed store changes: \(report.sources.values.reduce(0, +), privacy: .public) sources \
                (\(changes.importedTransactions, privacy: .public) imported transactions), \
                \(report.removedSources, privacy: .public) removed, \(report.embedded, privacy: .public) embedded, \
                \(report.reusedVectors, privacy: .public) vectors kept
                """)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The changes were read but not all written, and history won't
            // report them again in this process: verify everything instead.
            if fullPass == nil { fullPassRequest = fullPassRequest ?? false }
            throw error
        }
    }

    /// Re-chunks the changed sources and removes the deleted ones.
    @discardableResult
    public func apply(_ changes: MemorySourceChanges) async throws -> ApplyReport {
        var report = ApplyReport()
        var conversations = changes.conversations
        var removals: [MemoryIndex.SourceChunks] = []

        for kind in MemorySourceKind.allCases where changes.sweeps.contains(kind) {
            let stale = try await index.sourceIDs(kind: kind).subtracting(try await reader.sourceIDs(kind))
            guard !stale.isEmpty else { continue }
            if kind == .fact {
                conversations.formUnion(try await index.conversations(linkedToFacts: stale))
            }
            removals += stale.map { MemoryIndex.SourceChunks(kind: kind, sourceID: $0, chunks: []) }
        }
        // Conversations whose keys listed a changed fact before.
        conversations.formUnion(try await index.conversations(linkedToFacts: changes.facts))

        var writer = Writer(reembedAll: false)
        for removal in removals {
            try await writer.add(removal, report: &report, indexer: self)
        }

        if !changes.facts.isEmpty || !changes.documents.isEmpty {
            let batch = try await reader.read(conversations: [], documents: changes.documents, facts: changes.facts)
            for source in factSources(batch.facts, requested: changes.facts)
                + documentSources(batch.documents, requested: changes.documents)
            {
                try await writer.add(source, report: &report, indexer: self)
            }
        }

        let ordered = conversations.sorted { $0.uuidString < $1.uuidString }
        for start in stride(from: 0, to: ordered.count, by: configuration.conversationsPerStep) {
            try Task.checkCancellation()
            let ids = Set(ordered[start..<min(ordered.count, start + configuration.conversationsPerStep)])
            let batch = try await reader.read(conversations: ids, documents: [], facts: [])
            for source in conversationSources(batch, requested: ids) {
                try await writer.add(source, report: &report, indexer: self)
            }
        }
        try await writer.flush(report: &report, indexer: self)
        return report
    }

    // MARK: - Full pass

    /// The checkpoint saved in the index after every step.
    struct FullPassState: Codable, Equatable {
        var startedAt: Date
        var reembedAll: Bool
        /// Sources written so far.
        var completed: Int
        /// The last source written; everything at or before it in the
        /// pass's order is done.
        var cursor: SourceKey?
    }

    /// A position in the full pass's order: newest first, then by kind,
    /// then by id.
    struct SourceKey: Codable, Comparable, Hashable {
        var date: Date
        var kind: Int
        var id: String

        init(_ stamp: MemorySourceStamp) {
            date = stamp.date
            kind = MemorySourceKind.allCases.firstIndex(of: stamp.kind) ?? 0
            id = stamp.id.uuidString
        }

        /// `a < b` when `a` comes first in the pass: the newer one.
        static func < (lhs: SourceKey, rhs: SourceKey) -> Bool {
            (rhs.date, rhs.kind, rhs.id) < (lhs.date, lhs.kind, lhs.id)
        }
    }

    struct FullPass {
        var state: FullPassState
        /// Sources left, in the pass's order.
        var remaining: [MemorySourceStamp]
        var position = 0
    }

    private func loadFullPassState() async throws -> FullPassState? {
        guard let json = try await index.stateValue(forKey: Self.fullPassKey) else { return nil }
        guard let state = try? JSONDecoder().decode(FullPassState.self, from: Data(json.utf8)) else {
            Log.memory.error("Unreadable memory index rebuild checkpoint; starting over")
            return FullPassState(startedAt: clock.now, reembedAll: false, completed: 0, cursor: nil)
        }
        return state
    }

    private func save(_ state: FullPassState?) async throws {
        let json = try state.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await index.setStateValue(json, forKey: Self.fullPassKey)
    }

    /// Plans the rest of a pass: every source not yet passed, newest first.
    private func makeFullPass(_ state: FullPassState) async throws -> FullPass {
        let stamps = try await reader.stamps()
            .map { (key: SourceKey($0), stamp: $0) }
            .filter { item in state.cursor.map { item.key > $0 } ?? true }
            .sorted { $0.key < $1.key }
        let pass = FullPass(state: state, remaining: stamps.map(\.stamp))
        update {
            $0.rebuild = MemoryIndexingProgress(completed: state.completed, total: state.completed + stamps.count)
        }
        return pass
    }

    /// Starts a full pass from the newest source, replacing any running
    /// one. With `skipHistory`, history up to now is skipped first: the
    /// pass reads every source as it is after that point.
    private func startFullPass(reembedAll: Bool, skipHistory: Bool = false) async throws {
        if skipHistory { try await feed.skipToLatest() }
        let state = FullPassState(startedAt: clock.now, reembedAll: reembedAll, completed: 0, cursor: nil)
        try await save(state)
        fullPass = try await makeFullPass(state)
        Log.memory.notice(
            "Memory index rebuild started: \(self.fullPass?.remaining.count ?? 0, privacy: .public) sources")
    }

    private func fullPassStep() async throws {
        guard var pass = fullPass else { return }
        var conversations: [UUID] = []
        var documents: [UUID] = []
        var facts: [UUID] = []
        var last: MemorySourceStamp?
        while pass.position < pass.remaining.count, conversations.count < configuration.conversationsPerStep,
            documents.count + facts.count < configuration.sourcesPerStep
        {
            let stamp = pass.remaining[pass.position]
            switch stamp.kind {
            case .conversation: conversations.append(stamp.id)
            case .document: documents.append(stamp.id)
            case .fact: facts.append(stamp.id)
            case .collectionItem: break
            }
            last = stamp
            pass.position += 1
        }

        if let last {
            let batch = try await reader.read(
                conversations: Set(conversations), documents: Set(documents), facts: Set(facts))
            var writer = Writer(reembedAll: pass.state.reembedAll)
            var report = ApplyReport()
            for source in conversationSources(batch, requested: Set(conversations))
                + documentSources(batch.documents, requested: Set(documents))
                + factSources(batch.facts, requested: Set(facts))
            {
                try await writer.add(source, report: &report, indexer: self)
            }
            try await writer.flush(report: &report, indexer: self)

            pass.state.completed += conversations.count + documents.count + facts.count
            pass.state.cursor = SourceKey(last)
            try await save(pass.state)
            fullPass = pass
            update {
                $0.rebuild = MemoryIndexingProgress(
                    completed: pass.state.completed,
                    total: pass.state.completed + pass.remaining.count - pass.position)
            }
        }
        if pass.position >= pass.remaining.count {
            try await finishFullPass(pass.state)
        }
    }

    private func finishFullPass(_ state: FullPassState) async throws {
        // Sources deleted before the pass read them, or while it ran.
        var removed = 0
        var writer = Writer(reembedAll: false)
        var report = ApplyReport()
        var conversations = Set<UUID>()
        for kind in MemorySourceKind.allCases {
            let stale = try await index.sourceIDs(kind: kind).subtracting(try await reader.sourceIDs(kind))
            if kind == .fact { conversations = try await index.conversations(linkedToFacts: stale) }
            for id in stale {
                try await writer.add(
                    MemoryIndex.SourceChunks(kind: kind, sourceID: id, chunks: []), report: &report, indexer: self)
            }
            removed += stale.count
        }
        if !conversations.isEmpty {
            let batch = try await reader.read(conversations: conversations, documents: [], facts: [])
            for source in conversationSources(batch, requested: conversations) {
                try await writer.add(source, report: &report, indexer: self)
            }
        }
        try await writer.flush(report: &report, indexer: self)

        let now = clock.now
        try await index.markRebuilt(at: now)
        try await index.setStateValue(chunkingFingerprint, forKey: Self.chunkingKey)
        try await index.setStateValue(chunker.policy.timeZone.identifier, forKey: Self.timeZoneKey)
        try await save(nil)
        fullPass = nil
        backlogChecked = false
        update {
            $0.rebuild = nil
            $0.lastRebuild = now
            $0.lastIndexed = now
            $0.lastError = nil
        }
        let duration = now.timeIntervalSince(state.startedAt)
        Log.memory.notice(
            """
            Memory index rebuild finished: \(state.completed, privacy: .public) sources, \
            \(removed, privacy: .public) orphans removed, \(Int(duration.rounded()), privacy: .public) s since it started
            """)
    }

    /// What the chunks depend on besides the sources. A change starts a
    /// full pass.
    ///
    /// The leading version names the chunking rules themselves: `v2` (#173)
    /// left invalidated facts out of exchange keys and made
    /// `ApproximateTokenCounter` conservative, which changes keys and chunk
    /// boundaries.
    var chunkingFingerprint: String {
        let policy = chunker.policy
        return
            "\(Self.chunkingVersion) max=\(policy.maximumTokens) min=\(policy.minimumDocumentTokens) overlap=\(policy.exchangeOverlap) facts=\(policy.maximumFactsPerExchange) tz=\(policy.timeZone.identifier)"
    }

    /// Bumped whenever the chunker's output changes for the same sources
    /// and policy.
    static let chunkingVersion = "v2"

    // MARK: - Embedding backlog

    private func embeddingBacklogRemains() async throws -> Bool {
        guard let embedder, !embeddingBlocked else { return false }
        if status.embedding != nil { return true }
        guard !backlogChecked else { return false }
        backlogChecked = true
        let modelVersion: String
        do {
            modelVersion = try await embedder.currentModelVersion()
        } catch {
            update { $0.vectorsUnavailable = String(describing: error) }
            embeddingBlocked = true
            return false
        }
        let statistics = try await index.statistics(modelVersion: modelVersion)
        let missing = statistics.chunks - statistics.vectors
        update {
            $0.vectorsUnavailable = nil
            $0.embedding = missing > 0 ? MemoryIndexingProgress(completed: 0, total: missing) : nil
        }
        return missing > 0
    }

    private func embeddingStep() async throws {
        guard let embedder, var progress = status.embedding else { return }
        let finish = { (reason: String?) in
            self.embeddingBlocked = reason != nil
            self.update {
                $0.embedding = nil
                if let reason { $0.vectorsUnavailable = reason }
            }
        }
        let modelVersion: String
        let chunks: [MemoryChunk]
        let embeddings: [TextEmbedding]
        do {
            modelVersion = try await embedder.currentModelVersion()
            chunks = try await index.chunksNeedingEmbedding(
                modelVersion: modelVersion, limit: configuration.embeddingBatchSize, newestFirst: true)
            guard !chunks.isEmpty else { return finish(nil) }
            embeddings = try await embedder.embedDocuments(chunks.map(\.keyText))
            guard embeddings.count == chunks.count else {
                throw ChunkEmbeddingCountMismatch(expected: chunks.count, received: embeddings.count)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.memory.error("Embedding backlog stopped: \(String(describing: error), privacy: .public)")
            return finish(String(describing: error))
        }
        guard embeddings.allSatisfy({ $0.modelVersion == modelVersion }) else {
            // The model changed underneath; the next signal starts over.
            return finish(nil)
        }
        let stored = try await index.setEmbeddings(
            zip(chunks, embeddings).map { (chunkID: $0.id, contentHash: $0.contentHash, embedding: $1) })
        guard stored > 0 else { return finish(nil) }
        progress.completed += stored
        progress.total = max(progress.total, progress.completed)
        update { $0.embedding = progress }
    }

    private func refreshCounts() async {
        let modelVersion = try? await embedder?.currentModelVersion()
        guard let statistics = try? await index.statistics(modelVersion: modelVersion) else { return }
        update {
            $0.chunkCount = statistics.chunks
            $0.vectorCount = statistics.vectors
        }
    }

    // MARK: - Chunking

    private func conversationSources(_ batch: MemorySourceBatch, requested: Set<UUID>) -> [MemoryIndex.SourceChunks] {
        var statements: [UUID: [String]] = [:]
        var factIDs: [UUID: [UUID]] = [:]
        for fact in batch.exchangeFacts {
            guard let utterance = fact.sourceUtteranceID else { continue }
            // As in `MemoryIndexRebuilder`: an invalidated fact is linked but
            // left out of the `facts:` prefix.
            if fact.invalidatedAt == nil { statements[utterance, default: []].append(fact.statement) }
            factIDs[utterance, default: []].append(fact.id)
        }
        var sources: [MemoryIndex.SourceChunks] = []
        var found = Set<UUID>()
        for conversation in batch.conversations where requested.contains(conversation.id) {
            found.insert(conversation.id)
            sources.append(
                MemoryIndex.SourceChunks(
                    kind: .conversation, sourceID: conversation.id,
                    chunks: chunker.chunks(for: conversation, factsByUtterance: statements),
                    linkedFactIDs: Set(conversation.utterances.flatMap { factIDs[$0.id] ?? [] })))
        }
        for id in requested.subtracting(found).sorted(by: { $0.uuidString < $1.uuidString }) {
            sources.append(MemoryIndex.SourceChunks(kind: .conversation, sourceID: id, chunks: []))
        }
        return sources
    }

    private func documentSources(_ documents: [DocumentSnapshot], requested: Set<UUID>) -> [MemoryIndex.SourceChunks] {
        var sources: [MemoryIndex.SourceChunks] = []
        var found = Set<UUID>()
        for document in documents where requested.contains(document.id) {
            found.insert(document.id)
            sources.append(
                MemoryIndex.SourceChunks(kind: .document, sourceID: document.id, chunks: chunker.chunks(for: document)))
            for item in document.items {
                sources.append(
                    MemoryIndex.SourceChunks(
                        kind: .collectionItem, sourceID: item.id,
                        chunks: chunker.chunk(for: item, in: document).map { [$0] } ?? []))
            }
        }
        for id in requested.subtracting(found).sorted(by: { $0.uuidString < $1.uuidString }) {
            sources.append(MemoryIndex.SourceChunks(kind: .document, sourceID: id, chunks: []))
        }
        return sources
    }

    private func factSources(_ facts: [FactSnapshot], requested: Set<UUID>) -> [MemoryIndex.SourceChunks] {
        var sources: [MemoryIndex.SourceChunks] = []
        var found = Set<UUID>()
        for fact in facts where requested.contains(fact.id) && found.insert(fact.id).inserted {
            sources.append(
                MemoryIndex.SourceChunks(
                    kind: .fact, sourceID: fact.id, chunks: chunker.chunk(for: fact).map { [$0] } ?? []))
        }
        for id in requested.subtracting(found).sorted(by: { $0.uuidString < $1.uuidString }) {
            sources.append(MemoryIndex.SourceChunks(kind: .fact, sourceID: id, chunks: []))
        }
        return sources
    }

    // MARK: - Writing

    /// Gathers sources, embeds the chunks that need a vector, and writes
    /// them `writeBatchSize` chunks at a time.
    struct Writer {
        let reembedAll: Bool
        var pending: [MemoryIndex.SourceChunks] = []
        var pendingChunks = 0

        mutating func add(_ source: MemoryIndex.SourceChunks, report: inout ApplyReport, indexer: MemoryIndexer)
            async throws
        {
            pending.append(source)
            pendingChunks += source.chunks.count
            report.sources[source.kind, default: 0] += 1
            if source.chunks.isEmpty { report.removedSources += 1 }
            if pendingChunks >= indexer.configuration.writeBatchSize {
                try await flush(report: &report, indexer: indexer)
            }
        }

        mutating func flush(report: inout ApplyReport, indexer: MemoryIndexer) async throws {
            guard !pending.isEmpty else { return }
            try Task.checkCancellation()
            let embeddings = try await indexer.embeddings(for: pending.flatMap(\.chunks), reembedAll: reembedAll)
            let summary = try await indexer.index.replace(pending, embeddings: embeddings)
            report.chunksWritten += pendingChunks
            report.embedded += summary.newVectors
            report.reusedVectors += summary.keptVectors
            pending.removeAll(keepingCapacity: true)
            pendingChunks = 0
        }
    }

    /// Vectors for the chunks whose key text or model changed. Without a
    /// working model, none: the chunks are written for keyword search and
    /// the embedding backlog fills them in later.
    func embeddings(for chunks: [MemoryChunk], reembedAll: Bool) async throws -> [UUID: TextEmbedding] {
        guard let embedder, !embeddingBlocked, !chunks.isEmpty else { return [:] }
        do {
            let modelVersion = try await embedder.currentModelVersion()
            let current = reembedAll ? [:] : try await index.vectorStates(of: chunks.map(\.id))
            let needed = chunks.filter { chunk in
                guard let stored = current[chunk.id] else { return true }
                return stored.contentHash != chunk.contentHash || stored.modelVersion != modelVersion
            }
            guard !needed.isEmpty else { return [:] }
            let vectors = try await embedder.embedDocuments(needed.map(\.keyText))
            guard vectors.count == needed.count else {
                throw ChunkEmbeddingCountMismatch(expected: needed.count, received: vectors.count)
            }
            // The model changed underneath: the backlog embeds them later.
            guard vectors.allSatisfy({ $0.modelVersion == modelVersion }) else { return [:] }
            update { $0.vectorsUnavailable = nil }
            return Dictionary(zip(needed.map(\.id), vectors), uniquingKeysWith: { first, _ in first })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.memory.error(
                "Indexing continues without vectors: \(String(describing: error), privacy: .public)")
            embeddingBlocked = true
            update { $0.vectorsUnavailable = String(describing: error) }
            return [:]
        }
    }
}
