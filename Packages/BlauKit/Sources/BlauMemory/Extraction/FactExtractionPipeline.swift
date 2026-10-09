import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import os

/// What one topic's extraction learned.
public struct FactExtractionOutcome: Hashable, Sendable {
    public var topicID: UUID
    /// The model's summary of what the topic says about the user, windows
    /// joined. For the profile consolidation (#67).
    public var summary: String
    public var createdEntityIDs: [UUID] = []
    public var insertedFactIDs: [UUID] = []
    public var invalidatedFactIDs: [UUID] = []
    public var mergedEntityCount = 0
    public var skipped: [SkippedFactReason: Int] = [:]
    /// Requests sent to the text model (one per window).
    public var requestCount = 0

    public init(topicID: UUID, summary: String = "") {
        self.topicID = topicID
        self.summary = summary
    }
}

/// What the pipeline is doing, for observers (the debug screen, #67).
public enum FactExtractionEvent: Hashable, Sendable {
    /// A topic went into the queue.
    case queued(topicID: UUID)
    case started(topicID: UUID)
    case finished(FactExtractionOutcome)
    /// An attempt failed. With `willRetry` the topic stays queued.
    case failed(topicID: UUID, reason: String, willRetry: Bool)
    /// The text model can't be used (no xAI key): the queue waits for
    /// `resume()`.
    case waitingForGenerator
    /// Learning was turned off; the queued topics were dropped.
    case discarded(topicIDs: [UUID])
    /// `suspend()` stopped the worker. Every event of the work done before
    /// the suspension was delivered before this one, so a subscriber that
    /// sees it has seen everything extraction wrote.
    case suspended
}

/// What to do after an attempt fails.
public enum FactExtractionFailureDisposition: Hashable, Sendable {
    /// Try again after a backoff, up to `maximumAttempts`.
    case retry
    /// Keep the topic queued but stop until `resume()`: the user has to act
    /// first (enter or fix the xAI key, add credits).
    case waitForResume
    /// Drop the topic.
    case discard
}

/// Turns each closed topic into durable memory (#66), in the background:
///
/// 1. **Queue.** `topicClosed(_:)` records the topic in a persistent queue
///    and returns at once; the UI never waits for extraction. The queue
///    survives relaunches (`PendingFactExtractionStore`).
/// 2. **Extract.** A worker task at utility priority reads the topic's
///    transcript, splits it into windows that fit `transcriptTokenBudget`,
///    and asks the text model (xAI's chat completions with structured
///    output, the user's key from the Keychain, #33) for
///    `{entities, facts, summary}`, showing it the known entities the
///    window mentions and the current facts about them and the user.
/// 3. **Resolve.** `EntityResolver`: alias match, then embedding similarity
///    at or above a threshold, else a new entity.
/// 4. **Reconcile.** `FactReconciler`: add-only and validity-dated. A
///    contradicting fact invalidates the old one (`invalidatedAt`) instead
///    of deleting it; every new fact keeps its `sourceUtteranceID`.
/// 5. **Write.** `MemoryFactStoring.apply`, one save per window.
///
/// It runs only while the user lets Blau learn from conversations
/// (`isEnabled`), only while the thermal and power policy allows background
/// work (`IndexingGate`), and stops while the text model is unavailable
/// until `resume()`. Failures are retried with exponential backoff; a topic
/// is dropped after `maximumAttempts`.
public actor FactExtractionPipeline {
    public struct Configuration: Hashable, Sendable {
        /// Estimated transcript tokens per request; longer topics are split
        /// into several windows.
        public var transcriptTokenBudget: Int
        /// Known entities shown per request (those the window mentions).
        public var knownEntityLimit: Int
        /// Current facts shown per request.
        public var knownFactLimit: Int
        /// Facts the model is less sure of are dropped.
        public var minimumConfidence: Double
        /// Cosine similarity at which two entity names are the same entity.
        public var entitySimilarityThreshold: Float
        public var maximumResponseTokens: Int
        public var requestTimeout: Duration
        /// Attempts per topic before it is dropped.
        public var maximumAttempts: Int
        /// The first retry's delay; each later one is four times longer, up
        /// to `maximumRetryDelay`.
        public var retryDelay: Duration
        public var maximumRetryDelay: Duration

        public init(
            transcriptTokenBudget: Int = 6_000,
            knownEntityLimit: Int = 60,
            knownFactLimit: Int = 80,
            minimumConfidence: Double = 0.5,
            entitySimilarityThreshold: Float = 0.86,
            maximumResponseTokens: Int = 4_096,
            requestTimeout: Duration = .seconds(90),
            maximumAttempts: Int = 4,
            retryDelay: Duration = .seconds(30),
            maximumRetryDelay: Duration = .seconds(30 * 60)
        ) {
            self.transcriptTokenBudget = transcriptTokenBudget
            self.knownEntityLimit = knownEntityLimit
            self.knownFactLimit = knownFactLimit
            self.minimumConfidence = minimumConfidence
            self.entitySimilarityThreshold = entitySimilarityThreshold
            self.maximumResponseTokens = maximumResponseTokens
            self.requestTimeout = requestTimeout
            self.maximumAttempts = max(1, maximumAttempts)
            self.retryDelay = retryDelay
            self.maximumRetryDelay = maximumRetryDelay
        }

        public static let standard = Configuration()

        /// The delay before attempt `attempt + 1`, after `attempt` failures.
        func delay(afterFailures attempt: Int) -> Duration {
            var delay = retryDelay
            for _ in 1..<max(1, attempt) {
                delay *= 4
                if delay >= maximumRetryDelay { return maximumRetryDelay }
            }
            return min(delay, maximumRetryDelay)
        }
    }

    public nonisolated let configuration: Configuration

    private let generator: any TextGenerator
    private let transcripts: any TopicTranscriptSource
    private let store: any MemoryFactStoring
    private let resolver: EntityResolver
    private let isEnabled: @Sendable () async -> Bool
    private let pendingStore: any PendingFactExtractionStore
    private let gate: IndexingGate?
    private let classify: @Sendable (any Error) -> FactExtractionFailureDisposition
    private let clock: any BlauClock
    private let signposter: Signposter
    private let timeZone: TimeZone
    private let broadcaster = ExtractionEventBroadcaster()

    private var pending: [PendingFactExtraction]
    /// Topics in backoff, with the uptime they may run again.
    private var notBefore: [UUID: Duration] = [:]
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    /// `suspend()` calls not yet ended; nothing is extracted while above
    /// zero.
    private var suspensions = 0
    /// Topics extracted since launch (the most recent
    /// `recentTopicCapacity`), so a topic reported closed again isn't sent
    /// twice.
    private var recentlyExtracted: [UUID] = []
    private static let recentTopicCapacity = 256

    /// - Parameters:
    ///   - generator: The text model (`XAITextGenerator` in the app).
    ///   - transcripts: Where closed topics are read.
    ///   - store: Where entities and facts are read and written.
    ///   - embedder: The shared text embedding service for entity
    ///     resolution, or `nil` while its model isn't installed.
    ///   - isEnabled: Whether the user lets Blau learn from conversations,
    ///     checked before every topic.
    ///   - pending: The persistent queue.
    ///   - gate: Holds work back while the device is hot or short on power.
    ///   - classifyFailure: What to do after a failed attempt; the app maps
    ///     xAI errors (see `defaultFailureDisposition(for:)`).
    ///   - clock: Times retries.
    ///   - timeZone: Dates in prompts.
    public init(
        generator: any TextGenerator,
        transcripts: any TopicTranscriptSource,
        store: any MemoryFactStoring,
        configuration: Configuration = .standard,
        embedder: @escaping @Sendable () async -> (any TextEmbedder)? = { nil },
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        pending: any PendingFactExtractionStore = InMemoryPendingFactExtractionStore(),
        gate: IndexingGate? = nil,
        classifyFailure: @escaping @Sendable (any Error) -> FactExtractionFailureDisposition = {
            FactExtractionPipeline.defaultFailureDisposition(for: $0)
        },
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory,
        timeZone: TimeZone = .current
    ) {
        self.generator = generator
        self.transcripts = transcripts
        self.store = store
        self.configuration = configuration
        self.resolver = EntityResolver(
            similarityThreshold: configuration.entitySimilarityThreshold, embedder: embedder)
        self.isEnabled = isEnabled
        self.pendingStore = pending
        self.pending = pending.load()
        self.gate = gate
        self.classify = classifyFailure
        self.clock = clock
        self.signposter = signposter
        self.timeZone = timeZone
    }

    deinit {
        worker?.cancel()
        wake?.cancel()
        broadcaster.finish()
    }

    /// Topics a model reply can't be trusted for are retried; a topic that
    /// no longer exists is dropped; cancellation waits for `resume()`;
    /// anything else (network, server) is retried.
    public static func defaultFailureDisposition(for error: any Error) -> FactExtractionFailureDisposition {
        if error is CancellationError {
            return .waitForResume
        }
        if let storeError = error as? ConversationStoreError, case .topicNotFound = storeError {
            return .discard
        }
        return .retry
    }

    // MARK: Observing

    /// Every event from now on. Any number of subscribers.
    public nonisolated func events() -> AsyncStream<FactExtractionEvent> {
        broadcaster.subscribe()
    }

    /// Topics waiting for extraction, oldest first.
    public var pendingTopicIDs: [UUID] { pending.map(\.topicID) }

    /// Whether a worker is extracting now.
    public var isRunning: Bool { worker != nil }

    /// Waits until the worker has nothing it can do now: the queue is
    /// empty, every topic is in backoff, or it waits for `resume()`.
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: Suspending

    /// Whether `suspend()` holds the worker.
    public var isSuspended: Bool { suspensions > 0 }

    /// Stops extraction until `endSuspension()`, for Settings → Privacy &
    /// Data deleting the learned facts (#79): an extraction that read the
    /// store before the delete must not write facts after it.
    ///
    /// The topic being extracted is cancelled (its request too) and stays
    /// queued, without counting an attempt; a window it already wrote stays
    /// written, so it is deleted with the rest. Returns once the worker has
    /// stopped, after yielding `.suspended`. Calls nest: each needs its own
    /// `endSuspension()`.
    public func suspend() async {
        suspensions += 1
        worker?.cancel()
        await waitUntilIdle()
        broadcaster.yield(.suspended)
        Log.memory.notice("Fact extraction suspended")
    }

    /// Ends one `suspend()`; after the last one the queue runs again.
    public func endSuspension() {
        guard suspensions > 0 else { return }
        suspensions -= 1
        guard suspensions == 0 else { return }
        Log.memory.notice("Fact extraction resumed after a suspension")
        startWorker()
    }

    // MARK: Queueing

    /// A topic closed: queue it for extraction and return. Ignored while
    /// learning is off, and for a topic already queued or extracted.
    public func topicClosed(_ topicID: UUID) async {
        guard await isEnabled() else { return }
        guard !pending.contains(where: { $0.topicID == topicID }), !recentlyExtracted.contains(topicID) else {
            return
        }
        pending.append(PendingFactExtraction(topicID: topicID))
        pendingStore.save(pending)
        broadcaster.yield(.queued(topicID: topicID))
        Log.memory.debug("Queued topic \(topicID, privacy: .public) for fact extraction")
        startWorker()
    }

    /// Starts on whatever is queued: at launch, when the app becomes
    /// active, after an xAI key is entered. Topics in backoff keep waiting.
    public func resume() {
        startWorker()
    }

    /// Drops every queued topic, for example when the user turns learning
    /// off. A topic being extracted right now still finishes.
    public func discardPending() {
        guard !pending.isEmpty else { return }
        let dropped = pending.map(\.topicID)
        pending = []
        notBefore = [:]
        pendingStore.save(pending)
        broadcaster.yield(.discarded(topicIDs: dropped))
        Log.memory.notice("Dropped \(dropped.count, privacy: .public) topics waiting for fact extraction")
    }

    // MARK: Worker

    private func startWorker() {
        guard worker == nil, suspensions == 0, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { worker = nil }
        while !Task.isCancelled, suspensions == 0 {
            guard !pending.isEmpty else { return }
            guard await isEnabled() else {
                discardPending()
                return
            }
            let now = clock.uptime
            guard let next = pending.first(where: { (notBefore[$0.topicID] ?? .zero) <= now }) else {
                scheduleWake(now: now)
                return
            }
            guard await generator.isAvailable() else {
                Log.memory.notice("Fact extraction waits for the text model (no xAI key)")
                broadcaster.yield(.waitingForGenerator)
                return
            }
            do {
                try await gate?.waitUntilAllowed()
            } catch {
                return
            }
            // The queue may have changed while waiting.
            guard pending.contains(where: { $0.topicID == next.topicID }) else { continue }
            let keepsGoing = await process(next.topicID)
            if !keepsGoing {
                return
            }
        }
    }

    /// Extracts one topic and updates the queue.
    ///
    /// - Returns: `false` when the worker should stop until `resume()`.
    private func process(_ topicID: UUID) async -> Bool {
        broadcaster.yield(.started(topicID: topicID))
        let interval = signposter.beginInterval(.memoryExtract)
        do {
            let outcome = try await extract(topicID)
            interval.end(
                message: "\(outcome.insertedFactIDs.count) facts, \(outcome.invalidatedFactIDs.count) invalidated")
            remove(topicID)
            recentlyExtracted.append(topicID)
            if recentlyExtracted.count > Self.recentTopicCapacity {
                recentlyExtracted.removeFirst(recentlyExtracted.count - Self.recentTopicCapacity)
            }
            Log.memory.notice(
                """
                Extracted topic \(topicID, privacy: .public): \(outcome.insertedFactIDs.count, privacy: .public) facts \
                added, \(outcome.invalidatedFactIDs.count, privacy: .public) invalidated, \
                \(outcome.createdEntityIDs.count, privacy: .public) entities created, \
                \(outcome.skipped.values.reduce(0, +), privacy: .public) skipped
                """
            )
            broadcaster.yield(.finished(outcome))
            return true
        } catch {
            interval.end(message: "failed")
            let reason = String(describing: error)
            if suspensions > 0, Task.isCancelled {
                // `suspend()` cancelled it: not the topic's fault, so no
                // attempt is counted. It runs again after the suspension.
                Log.memory.notice("Extraction of topic \(topicID, privacy: .public) stopped by a suspension")
                broadcaster.yield(.failed(topicID: topicID, reason: "suspended", willRetry: true))
                return false
            }
            switch classify(error) {
            case .discard:
                remove(topicID)
                Log.memory.error(
                    "Dropped topic \(topicID, privacy: .public) from extraction: \(reason, privacy: .public)")
                broadcaster.yield(.failed(topicID: topicID, reason: reason, willRetry: false))
                return true
            case .waitForResume:
                Log.memory.notice("Fact extraction paused: \(reason, privacy: .public)")
                broadcaster.yield(.failed(topicID: topicID, reason: reason, willRetry: true))
                return false
            case .retry:
                guard let index = pending.firstIndex(where: { $0.topicID == topicID }) else { return true }
                pending[index].attempts += 1
                let attempts = pending[index].attempts
                if attempts >= configuration.maximumAttempts {
                    remove(topicID)
                    Log.memory.error(
                        "Gave up on topic \(topicID, privacy: .public) after \(attempts, privacy: .public) attempts: \(reason, privacy: .public)"
                    )
                    broadcaster.yield(.failed(topicID: topicID, reason: reason, willRetry: false))
                } else {
                    pendingStore.save(pending)
                    notBefore[topicID] = clock.uptime + configuration.delay(afterFailures: attempts)
                    Log.memory.error(
                        "Extraction of topic \(topicID, privacy: .public) failed (attempt \(attempts, privacy: .public)), will retry: \(reason, privacy: .public)"
                    )
                    broadcaster.yield(.failed(topicID: topicID, reason: reason, willRetry: true))
                }
                return true
            }
        }
    }

    private func remove(_ topicID: UUID) {
        pending.removeAll { $0.topicID == topicID }
        notBefore[topicID] = nil
        pendingStore.save(pending)
    }

    /// Restarts the worker when the earliest backoff ends.
    private func scheduleWake(now: Duration) {
        guard let earliest = pending.compactMap({ notBefore[$0.topicID] }).min() else { return }
        wake?.cancel()
        let clock = clock
        wake = Task(priority: .utility) { [weak self] in
            guard (try? await clock.sleep(for: earliest - now)) != nil else { return }
            await self?.resume()
        }
    }

    // MARK: Extraction

    /// Extracts one topic, window by window. Each window is written before
    /// the next is read, so later windows see what earlier ones learned.
    func extract(_ topicID: UUID) async throws -> FactExtractionOutcome {
        let topic = try await transcripts.topicSnapshot(topicID)
        let utterances = try await transcripts.topicUtterances(topicID).filter { !$0.isBlank }
        let numbered = utterances.enumerated().map { NumberedUtterance(number: $0.offset + 1, utterance: $0.element) }
        var outcome = FactExtractionOutcome(topicID: topicID)
        var summaries: [String] = []
        let reconciler = FactReconciler(minimumConfidence: configuration.minimumConfidence)

        for window in FactExtractionPrompt.windows(of: numbered, budget: configuration.transcriptTokenBudget) {
            // Nothing the user said, nothing to learn about them.
            guard window.contains(where: { $0.utterance.speaker == .user }) else { continue }
            try Task.checkCancellation()

            let known = EntityResolver.settingAsideEmptyDuplicates(try await store.entities())
            let text = window.map(\.utterance.text).joined(separator: "\n")
            let mentioned = FactExtractionPrompt.mentionedEntities(
                known, in: text, limit: configuration.knownEntityLimit)
            let facts = try await store.currentFacts(
                about: Set(mentioned.map(\.id)), includingUser: true, limit: configuration.knownFactLimit)
            let prompt = FactExtractionPrompt(
                date: window.first?.utterance.startedAt ?? topic.startedAt,
                topicTitle: topic.meaningfulTitle,
                entities: mentioned,
                facts: facts,
                utterances: window,
                timeZone: timeZone)

            let reply = try await generator.generate(
                prompt.request(
                    maximumResponseTokens: configuration.maximumResponseTokens,
                    timeout: configuration.requestTimeout))
            outcome.requestCount += 1
            let extraction = try FactExtraction.parse(reply)
            if !extraction.summary.isEmpty {
                summaries.append(extraction.summary)
            }

            let resolution = await resolver.resolve(extraction, known: known)
            let reconciled = reconciler.reconcile(
                extraction, resolution: resolution, prompt: prompt, knownFacts: facts, recordedAt: clock.now)
            for (reason, count) in reconciled.skipped {
                outcome.skipped[reason, default: 0] += count
            }
            guard !reconciled.plan.isEmpty else { continue }
            let written = try await store.apply(reconciled.plan)
            outcome.createdEntityIDs += written.createdEntityIDs
            outcome.insertedFactIDs += written.insertedFactIDs
            outcome.invalidatedFactIDs += written.invalidatedFactIDs
            outcome.mergedEntityCount += written.mergedEntityCount
            if written.skippedDuplicateCount > 0 {
                outcome.skipped[.duplicate, default: 0] += written.skippedDuplicateCount
            }
        }
        outcome.summary = summaries.joined(separator: " ")
        return outcome
    }
}

// MARK: - Broadcasting

/// Fans pipeline events out to every subscriber.
private final class ExtractionEventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<FactExtractionEvent>.Continuation]>([:])

    func subscribe() -> AsyncStream<FactExtractionEvent> {
        let (stream, continuation) = AsyncStream<FactExtractionEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    func yield(_ event: FactExtractionEvent) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(event)
        }
    }

    func finish() {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.finish()
        }
    }
}
