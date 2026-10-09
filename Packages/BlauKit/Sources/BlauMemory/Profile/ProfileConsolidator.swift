import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Why a consolidation didn't run.
public enum ProfileConsolidationSkip: String, Hashable, Sendable {
    /// Learning from conversations is off.
    case disabled
    /// The text model can't be used (no xAI key).
    case generatorUnavailable
    /// Memory holds nothing to consolidate yet.
    case nothingToConsolidate
    /// Another device changed the profile while this one was consolidating;
    /// the next run starts from its version.
    case conflict
    /// The thermal and power policy held it back and the wait was cancelled.
    case deferred
}

/// What one call to the consolidator did.
public enum ProfileConsolidationOutcome: Hashable, Sendable {
    /// The profile or topic summaries changed; the record is in the log.
    case consolidated(ProfileConsolidationRecord)
    /// It ran and nothing needed to change.
    case unchanged
    /// Not due yet.
    case notDue(nextCheck: Date)
    case skipped(ProfileConsolidationSkip)
    /// The request or a write failed; the next scheduled run tries again.
    case failed(String)
}

/// What the consolidator is doing, for observers (Settings → Memory →
/// Profile, the pinned memory cache).
public enum ProfileConsolidationEvent: Hashable, Sendable {
    case started(ProfileConsolidationReason)
    case finished(ProfileConsolidationOutcome)
}

/// Sleep-time consolidation of the pinned profile (#67, the Letta idea in
/// issue #1).
///
/// About once a week, after `ProfileConsolidationSchedule.factThreshold`
/// facts changed, or soon after the user removed a fact
/// (`noteRemovedFacts(count:)`), a background processing task asks the text model (xAI,
/// the user's key, #33) to rewrite the `ProfileBlock` summary from the
/// current facts, the notes fact extraction left (#66) and the recent
/// topics, and to improve the summaries of recent topics it can:
///
/// 1. **Read** the block, the user's own `.profile` pages, the current
///    facts (most important first), the notes and the recent closed
///    topics.
/// 2. **Budget.** The user's pages are pinned verbatim
///    (`ProfileComposer`); the summary gets what is left of
///    `ProfileBlock.tokenBudget`, and the model is told it as a word limit.
/// 3. **Generate and fit.** The reply is parsed and the summary cut to its
///    budget at a paragraph, sentence or word boundary, so the pinned
///    profile never exceeds the budget whatever the model returns.
/// 4. **Write** the block only if it is still what was read (another
///    device may have consolidated meanwhile), merging duplicate blocks;
///    write each new topic summary only if that topic's summary is still
///    what was read and its conversation has ended.
/// 5. **Record** the change in the log, which the diff view shows.
///
/// It runs only while the user lets Blau learn from conversations
/// (`isEnabled`), with the text model available, and after the thermal and
/// power gate (#75). Concurrent calls share one run.
public actor ProfileConsolidator {
    public struct Configuration: Hashable, Sendable {
        public var schedule: ProfileConsolidationSchedule
        public var composer: ProfileComposer
        /// Facts shown to the model.
        public var factLimit: Int
        /// How far back topics are shown.
        public var topicWindow: TimeInterval
        public var topicLimit: Int
        /// Extraction notes shown (the newest).
        public var noteLimit: Int
        public var maximumResponseTokens: Int
        public var requestTimeout: Duration

        public init(
            schedule: ProfileConsolidationSchedule = .standard,
            composer: ProfileComposer = .standard,
            factLimit: Int = 200,
            topicWindow: TimeInterval = 30 * 24 * 3_600,
            topicLimit: Int = 30,
            noteLimit: Int = 30,
            maximumResponseTokens: Int = 4_096,
            requestTimeout: Duration = .seconds(120)
        ) {
            self.schedule = schedule
            self.composer = composer
            self.factLimit = max(0, factLimit)
            self.topicWindow = max(0, topicWindow)
            self.topicLimit = max(0, topicLimit)
            self.noteLimit = max(0, noteLimit)
            self.maximumResponseTokens = maximumResponseTokens
            self.requestTimeout = requestTimeout
        }

        public static let standard = Configuration()
    }

    /// The most notes kept waiting; older ones are dropped.
    public static let noteCapacity = 60

    public nonisolated let configuration: Configuration

    private let generator: any TextGenerator
    private let store: any ProfileMemoryStoring
    private let topicSummaries: (any TopicSummaryWriting)?
    private let logStore: any ProfileConsolidationLogStore
    private let noteStore: any ProfileConsolidationNoteStore
    private let isEnabled: @Sendable () async -> Bool
    private let gate: IndexingGate?
    private let clock: any BlauClock
    private let signposter: Signposter
    private let timeZone: TimeZone
    private let broadcaster = ConsolidationEventBroadcaster()

    private var running: Task<ProfileConsolidationOutcome, Never>?
    /// Calls waiting for the running consolidation (tests wait for it).
    private(set) var waiterCount = 0

    /// - Parameters:
    ///   - generator: The text model (`XAITextGenerator` in the app).
    ///   - store: Where memory is read and the block written.
    ///   - topicSummaries: Where rewritten topic summaries go, or `nil` to
    ///     leave topics alone.
    ///   - log: This device's consolidation log.
    ///   - notes: Extraction notes waiting for the next run.
    ///   - isEnabled: Whether the user lets Blau learn from conversations.
    ///   - gate: Holds the run back while the device is hot or short on
    ///     power.
    ///   - clock: Dates the block and the log.
    ///   - timeZone: Dates in the prompt.
    public init(
        generator: any TextGenerator,
        store: any ProfileMemoryStoring,
        topicSummaries: (any TopicSummaryWriting)? = nil,
        log: any ProfileConsolidationLogStore = InMemoryProfileConsolidationLogStore(),
        notes: any ProfileConsolidationNoteStore = InMemoryProfileConsolidationNoteStore(),
        configuration: Configuration = .standard,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        gate: IndexingGate? = nil,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory,
        timeZone: TimeZone = .current
    ) {
        self.generator = generator
        self.store = store
        self.topicSummaries = topicSummaries
        self.logStore = log
        self.noteStore = notes
        self.configuration = configuration
        self.isEnabled = isEnabled
        self.gate = gate
        self.clock = clock
        self.signposter = signposter
        self.timeZone = timeZone
    }

    deinit {
        broadcaster.finish()
    }

    // MARK: Observing

    /// Every event from now on. Any number of subscribers.
    public nonisolated func events() -> AsyncStream<ProfileConsolidationEvent> {
        broadcaster.subscribe()
    }

    /// This device's log: the last run and the recent changes, newest first.
    public func log() -> ProfileConsolidationLog {
        logStore.load()
    }

    /// Whether a consolidation is running now.
    public var isRunning: Bool { running != nil }

    // MARK: Notes

    /// Keeps what an extraction learned about the user for the next run
    /// (`FactExtractionOutcome.summary`). Ignored when it has no summary.
    public func record(_ outcome: FactExtractionOutcome) {
        let summary = FactExtraction.clean(outcome.summary)
        guard !summary.isEmpty else { return }
        var notes = noteStore.load().filter { $0.id != outcome.topicID }
        notes.append(ProfileConsolidationNote(topicID: outcome.topicID, date: clock.now, summary: summary))
        if notes.count > Self.noteCapacity {
            notes.removeFirst(notes.count - Self.noteCapacity)
        }
        noteStore.save(notes)
    }

    /// The extraction notes waiting for the next run, oldest first.
    public func pendingNotes() -> [ProfileConsolidationNote] {
        noteStore.load()
    }

    /// Drops the waiting notes, for example when learning is turned off.
    public func discardNotes() {
        noteStore.save([])
    }

    // MARK: Removals

    /// Notes that the user removed `count` facts: deleted them (Settings →
    /// Memory → What Blau Learned) or had Blau forget them (the `forget`
    /// tool, #68). The summary may still say what they were, so the next
    /// run is due as soon as `minimumSpacing` and the retry backoff allow
    /// (`ProfileConsolidationReason.removedFacts`). A deleted fact leaves
    /// no record for `factChangeCount(since:)` to count, so without this
    /// the profile would keep it pinned until something unrelated changed.
    public func noteRemovedFacts(count: Int = 1) {
        guard count > 0 else { return }
        var log = logStore.load()
        log.recordRemovals(count)
        logStore.save(log)
        Log.memory.notice("The user removed \(count, privacy: .public) facts; the profile is due for consolidation")
    }

    /// Facts the user removed that no finished run has seen memory without.
    public func pendingRemovals() -> Int {
        logStore.load().pendingRemovals
    }

    // MARK: Erasing

    /// Waits for a consolidation that is running to finish. Settings →
    /// Privacy & Data calls it before deleting the learned facts, so a run
    /// that already read them can't write a new profile block from them
    /// after they are gone.
    public func waitUntilIdle() async {
        guard let running else { return }
        waiterCount += 1
        defer { waiterCount -= 1 }
        _ = await running.value
    }

    /// Forgets this device's own copies of what consolidation read and
    /// wrote, after the user deleted the learned facts and the profile
    /// (Settings → Privacy & Data): the log's records (the profile text
    /// before and after each run, the rewritten topic summaries) and the
    /// extraction notes waiting for the next run. The schedule (last run,
    /// retry backoff) stays; the removal count is cleared, since there is
    /// nothing left for a run to take out.
    public func eraseLocalHistory() {
        var log = logStore.load()
        log.records = []
        log.pendingRemovals = 0
        logStore.save(log)
        noteStore.save([])
        Log.memory.notice("Erased this device's profile consolidation log and notes")
    }

    /// Forgets the topic summaries this device's log holds, after the user
    /// deleted every conversation (Settings → Privacy & Data → Delete All
    /// Conversations): each record's rewritten topic summaries (the topics'
    /// titles and summaries before and after) go, and a record that changed
    /// nothing else goes with them. The profile changes, the notes and the
    /// schedule stay: deleting conversations keeps what was learned from
    /// them.
    public func eraseTopicHistory() {
        var log = logStore.load()
        log.removeTopicChanges()
        logStore.save(log)
        Log.memory.notice("Erased the topic summaries in this device's profile consolidation log")
    }

    // MARK: Scheduling

    /// Whether a consolidation is due, from this device's last run, the
    /// block's `updatedAt`, what changed since (including facts the user
    /// removed, `noteRemovedFacts(count:)`), and the retry backoff after
    /// runs that didn't finish.
    public func decision() async throws -> ProfileConsolidationDecision {
        let now = clock.now
        let last = try await lastConsolidatedAt()
        let log = logStore.load()
        var changes = noteStore.load().count + log.pendingRemovals
        if let last {
            changes += try await store.factChangeCount(since: last)
        }
        // The memory a run would read: older topics alone give it nothing.
        let hasMemory = try await store.hasMemory(topicsSince: now.addingTimeInterval(-configuration.topicWindow))
        return configuration.schedule.decision(
            lastConsolidatedAt: last, changes: changes, removals: log.pendingRemovals, hasMemory: hasMemory,
            now: now, lastAttemptAt: log.lastAttemptAt, failedAttempts: log.failedAttempts)
    }

    /// Whether the user lets Blau learn from conversations; consolidation
    /// runs only then.
    public func isLearningEnabled() async -> Bool {
        await isEnabled()
    }

    /// When the background task should next look: now if a run is due,
    /// the decision's next check if not, or `nil` while learning is off
    /// (nothing to schedule; leaving the app after turning it back on
    /// schedules again).
    public func nextBackgroundCheck() async -> Date? {
        guard await isEnabled() else { return nil }
        let now = clock.now
        do {
            switch try await decision() {
            case .due: return now
            case .notDue(let nextCheck): return nextCheck
            }
        } catch {
            return now.addingTimeInterval(configuration.schedule.interval)
        }
    }

    /// The later of this device's last run and the profile block's
    /// `updatedAt` (another device's consolidation syncs in), or `nil` if
    /// the profile was never consolidated.
    public func lastConsolidatedAt() async throws -> Date? {
        let block = try await store.profileBlock(key: ProfileBlock.userKey)
        return [logStore.load().lastRunAt, block?.updatedAt].compactMap { $0 }.max()
    }

    /// Consolidates if `decision()` says it is due: what the background
    /// task calls.
    public func consolidateIfDue() async -> ProfileConsolidationOutcome {
        guard await isEnabled() else { return .skipped(.disabled) }
        let decision: ProfileConsolidationDecision
        do {
            decision = try await self.decision()
        } catch {
            return .failed(String(describing: error))
        }
        switch decision {
        case .notDue(let nextCheck):
            return .notDue(nextCheck: nextCheck)
        case .due(let reason):
            return await consolidate(reason: reason)
        }
    }

    /// Consolidates now. A call while one is running waits for it and
    /// returns its outcome. Cancelling the calling task (the background
    /// task expiring) cancels the run: nothing is written after the
    /// request is cut off.
    public func consolidate(reason: ProfileConsolidationReason = .manual) async -> ProfileConsolidationOutcome {
        if let running {
            waiterCount += 1
            defer { waiterCount -= 1 }
            return await withTaskCancellationHandler {
                await running.value
            } onCancel: {
                running.cancel()
            }
        }
        let task = Task(priority: .utility) { [weak self] () -> ProfileConsolidationOutcome in
            guard let self else { return .skipped(.disabled) }
            return await self.run(reason: reason)
        }
        running = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running = nil
        return outcome
    }

    // MARK: Running

    private func run(reason: ProfileConsolidationReason) async -> ProfileConsolidationOutcome {
        // Not an attempt: turning learning back on shouldn't wait out a
        // backoff.
        guard await isEnabled() else { return .skipped(.disabled) }
        guard await generator.isAvailable() else {
            Log.memory.notice("Profile consolidation waits for the text model (no xAI key)")
            return recordingAttempt(.skipped(.generatorUnavailable))
        }
        do {
            try await gate?.waitUntilAllowed()
        } catch {
            return recordingAttempt(.skipped(.deferred))
        }
        broadcaster.yield(.started(reason))
        let interval = signposter.beginInterval(.memoryConsolidate)
        let outcome: ProfileConsolidationOutcome
        do {
            outcome = try await consolidateOnce(reason: reason)
        } catch {
            outcome = .failed(String(describing: error))
        }
        switch outcome {
        case .consolidated(let record):
            interval.end(message: "\(record.tokenCount) tokens, \(record.topicChanges.count) topics")
            Log.memory.notice(
                """
                Consolidated the profile (\(reason.rawValue, privacy: .public)): \
                \(ProfileComposer.tokens(record.before), privacy: .public) → \
                \(record.tokenCount, privacy: .public) tokens, \(record.diff.addedWordCount, privacy: .public) words \
                added, \(record.diff.removedWordCount, privacy: .public) removed, \
                \(record.topicChanges.count, privacy: .public) topic summaries
                """
            )
        case .unchanged:
            interval.end(message: "unchanged")
            Log.memory.notice("Profile consolidation (\(reason.rawValue, privacy: .public)) changed nothing")
        case .skipped(let skip):
            interval.end(message: skip.rawValue)
            Log.memory.notice("Profile consolidation skipped: \(skip.rawValue, privacy: .public)")
        case .failed(let reason):
            interval.end(message: "failed")
            Log.memory.error("Profile consolidation failed: \(reason, privacy: .public)")
        case .notDue:
            interval.end(message: "not due")
        }
        recordingAttempt(outcome)
        broadcaster.yield(.finished(outcome))
        return outcome
    }

    /// Starts or extends the retry backoff after a run that didn't finish,
    /// so the next automatic one waits for it (`decision()`). A run that
    /// finished already reset it (`consolidateOnce`).
    @discardableResult
    private func recordingAttempt(_ outcome: ProfileConsolidationOutcome) -> ProfileConsolidationOutcome {
        switch outcome {
        case .consolidated, .unchanged, .notDue, .skipped(.disabled):
            break
        case .skipped, .failed:
            var log = logStore.load()
            log.recordFailedAttempt(at: clock.now)
            logStore.save(log)
            let delay = configuration.schedule.retryDelay(afterFailedAttempts: log.failedAttempts)
            Log.memory.notice(
                "Profile consolidation retries in \(Int(delay / 60), privacy: .public) min (attempt \(log.failedAttempts, privacy: .public))"
            )
        }
        return outcome
    }

    private func consolidateOnce(reason: ProfileConsolidationReason) async throws -> ProfileConsolidationOutcome {
        let now = clock.now
        // Removals noted before memory is read are what this run sees memory
        // without; ones noted while it runs wait for the next.
        let removals = logStore.load().pendingRemovals
        let block = try await store.profileBlock(key: ProfileBlock.userKey)
        let documents = try await store.userProfileDocuments()
        let facts = try await store.currentFacts(limit: configuration.factLimit)
        let topics = try await store.recentTopics(
            since: now.addingTimeInterval(-configuration.topicWindow), limit: configuration.topicLimit)
        let waiting = noteStore.load()
        let notes = Array(waiting.sorted { $0.date > $1.date }.prefix(configuration.noteLimit))

        let currentSummary = block?.text ?? ""
        guard !facts.isEmpty || !topics.isEmpty || !notes.isEmpty || !currentSummary.isEmpty else {
            // No summary pins what was removed, so there is nothing left
            // to take out; don't keep a run due for it.
            if removals > 0 {
                var log = logStore.load()
                log.pendingRemovals = max(0, log.pendingRemovals - removals)
                logStore.save(log)
            }
            return .skipped(.nothingToConsolidate)
        }

        let composer = configuration.composer
        let userSection = composer.userSection(documents, leavingRoomForSummary: true)
        let summaryBudget = composer.summaryByteBudget(after: userSection)
        let prompt = ProfileConsolidationPrompt(
            date: now, currentSummary: currentSummary, userAuthored: userSection, facts: facts, notes: notes,
            topics: topics, summaryByteBudget: summaryBudget, removedFactCount: removals, timeZone: timeZone)
        try Task.checkCancellation()
        let reply = try ProfileConsolidationReply.parse(
            try await generator.generate(
                prompt.request(
                    maximumResponseTokens: configuration.maximumResponseTokens,
                    timeout: configuration.requestTimeout)))

        try Task.checkCancellation()
        let summary = ProfileComposer.fitted(reply.profile, maximumBytes: summaryBudget)
        if summary.isEmpty, !currentSummary.isEmpty, !facts.isEmpty {
            // Wiping a profile while memory still holds facts is a broken
            // reply, not a consolidation.
            throw ProfileConsolidationError.invalidResponse("The reply's profile is empty")
        }

        let write: ProfileBlockWrite
        if summary == currentSummary, (block?.copyCount ?? 1) <= 1 {
            write = .unchanged
        } else {
            write = try await store.writeProfileBlock(
                key: ProfileBlock.userKey, text: summary, expectedText: block?.text, at: now)
        }
        if write == .conflict {
            return .skipped(.conflict)
        }

        let topicChanges = await applyTopicSummaries(reply.topicSummaries, prompt: prompt)

        // Notes the model saw are used up; ones added meanwhile wait,
        // including a newer note that replaced one the model saw (a topic
        // extracted again after re-segmentation).
        let used = Set(notes)
        noteStore.save(noteStore.load().filter { !used.contains($0) })

        var log = logStore.load()
        log.recordSuccessfulRun(at: now, removals: removals)
        let changedProfile = write == .written && summary != currentSummary
        guard changedProfile || !topicChanges.isEmpty else {
            logStore.save(log)
            return .unchanged
        }
        let record = ProfileConsolidationRecord(
            date: now, reason: reason, before: currentSummary, after: changedProfile ? summary : currentSummary,
            topicChanges: topicChanges, factCount: facts.count, noteCount: notes.count, topicCount: topics.count)
        log.insert(record)
        logStore.save(log)
        return .consolidated(record)
    }

    /// Writes the model's topic summaries where they are allowed and still
    /// current. A failed write only loses that topic's new summary.
    private func applyTopicSummaries(_ summaries: [String: String], prompt: ProfileConsolidationPrompt) async
        -> [TopicSummaryChange]
    {
        guard let topicSummaries, !summaries.isEmpty else { return [] }
        var changes: [TopicSummaryChange] = []
        // Newest first, the order the prompt lists them in.
        for (offset, topic) in prompt.topics.enumerated() {
            guard let summary = summaries["T\(offset + 1)"], topic.acceptsSummary, summary != topic.summary else {
                continue
            }
            do {
                if try await topicSummaries.replaceTopicSummary(topic.id, expected: topic.summary, with: summary) {
                    changes.append(
                        TopicSummaryChange(topicID: topic.id, title: topic.title, before: topic.summary, after: summary)
                    )
                }
            } catch {
                Log.memory.error(
                    "Couldn't rewrite the summary of topic \(topic.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return changes
    }
}

// MARK: - Broadcasting

/// Fans consolidation events out to every subscriber.
private final class ConsolidationEventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<ProfileConsolidationEvent>.Continuation]>([:])

    func subscribe() -> AsyncStream<ProfileConsolidationEvent> {
        let (stream, continuation) = AsyncStream<ProfileConsolidationEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    func yield(_ event: ProfileConsolidationEvent) {
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
