import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import Observation
import os

/// The pinned profile (#67): sleep-time consolidation of the `ProfileBlock`,
/// what each realtime session is given about the user, and what Settings →
/// Memory → Profile shows (the profile, its token budget and the diff of
/// every consolidation).
///
/// BlauMemory can't import BlauRealtime (siblings), so this composition-root
/// type connects them: `realtimeContext(_:)` turns BlauMemory's `PinnedMemory`
/// into the `RealtimeMemoryContext` the session configurator puts into the
/// instructions, and consolidation calls xAI through `XAITextGenerator` with
/// the user's key (#33).
@MainActor
@Observable
final class ProfileMemory {
    /// This device's consolidations, newest first, for the diff view.
    private(set) var log = ProfileConsolidationLog()
    /// Whether a consolidation is running (the Update Now button).
    private(set) var isConsolidating = false
    /// What the last run here did, for the status line.
    private(set) var lastOutcome: ProfileConsolidationOutcome?

    @ObservationIgnored let consolidator: ProfileConsolidator
    @ObservationIgnored let pinned: PinnedMemoryProvider
    /// Runs consolidation in the background (`ProfileConsolidationBackgroundTask`);
    /// `false` in previews and tests.
    @ObservationIgnored let schedulesBackgroundWork: Bool

    /// How long past its due date a consolidation waits for a background
    /// task before it runs in the foreground instead (a phone that is never
    /// left charging and idle may not give one).
    static let foregroundCatchUpDelay: TimeInterval = 3 * 24 * 3_600

    @ObservationIgnored private var followers: [Task<Void, Never>] = []

    init(consolidator: ProfileConsolidator, pinned: PinnedMemoryProvider, schedulesBackgroundWork: Bool) {
        self.consolidator = consolidator
        self.pinned = pinned
        self.schedulesBackgroundWork = schedulesBackgroundWork
    }

    /// What the realtime session configurator reads for every
    /// `session.update`: `pinned` as a `RealtimeMemoryContext`.
    nonisolated static func realtimeContext(_ pinned: PinnedMemoryProvider) -> any RealtimeMemoryContextProviding {
        PinnedRealtimeMemoryContext(pinned: pinned)
    }

    /// Follows what changes the pinned memory: each extraction leaves its
    /// note for the next consolidation and refreshes the session's facts;
    /// each consolidation refreshes the log; turning learning off drops the
    /// waiting notes. Call once, at launch.
    func start(learning: MemoryLearning) {
        guard followers.isEmpty else { return }
        let consolidator = consolidator
        let pinned = pinned
        let extractions = learning.pipeline.events()
        followers.append(
            Task(priority: .utility) {
                for await event in extractions {
                    guard case .finished(let outcome) = event else { continue }
                    await consolidator.record(outcome)
                    if !outcome.insertedFactIDs.isEmpty || !outcome.invalidatedFactIDs.isEmpty {
                        await pinned.invalidate()
                    }
                }
            })
        let consolidations = consolidator.events()
        followers.append(
            Task { [weak self] in
                for await event in consolidations {
                    switch event {
                    case .started:
                        self?.isConsolidating = true
                    case .finished(let outcome):
                        await pinned.invalidate()
                        self?.lastOutcome = outcome
                        self?.isConsolidating = false
                        await self?.reloadLog()
                    }
                }
            })
        let toggles = learning.settings.changes()
        followers.append(
            Task {
                for await learns in toggles where !learns {
                    await consolidator.discardNotes()
                }
            })
        Task { await reloadLog() }
    }

    /// Consolidates now: Settings → Memory → Profile → Update Now.
    @discardableResult
    func consolidateNow() async -> ProfileConsolidationOutcome {
        isConsolidating = true
        let outcome = await consolidator.consolidate(reason: .manual)
        lastOutcome = outcome
        isConsolidating = false
        await reloadLog()
        return outcome
    }

    /// Runs a consolidation that a background task should have run days
    /// ago, the first one, or one the user's removal of a fact made due
    /// (what they deleted or asked Blau to forget shouldn't wait for a
    /// charging, idle background task). Called when the app becomes
    /// active, never during a conversation. A run that didn't finish
    /// starts a retry backoff
    /// (`ProfileConsolidationSchedule.retryDelay`), during which
    /// `decision()` isn't `.due`, so a failing run isn't repeated on every
    /// activation.
    func catchUpIfOverdue(now: Date = Date()) {
        guard schedulesBackgroundWork else { return }
        let consolidator = consolidator
        Task(priority: .utility) {
            guard await consolidator.isLearningEnabled() else { return }
            guard case .due(let reason)? = try? await consolidator.decision() else { return }
            let last = try? await consolidator.lastConsolidatedAt()
            let interval = consolidator.configuration.schedule.interval
            let overdue = last.map { now.timeIntervalSince($0) >= interval + Self.foregroundCatchUpDelay } ?? true
            guard reason == .firstRun || reason == .removedFacts || overdue else { return }
            Log.memory.notice(
                "Profile consolidation (\(reason.rawValue, privacy: .public)) is overdue; running it in the foreground")
            _ = await consolidator.consolidate(reason: reason)
        }
    }

    /// What a fact the user removed does to the pinned profile: drops the
    /// pinned cache and makes a consolidation due (`ProfileFactRemovals`).
    nonisolated var removals: ProfileFactRemovals {
        ProfileFactRemovals(consolidator: consolidator, pinned: pinned)
    }

    /// Call after the user deleted `count` facts (Settings → Memory → What
    /// Blau Learned). The next session no longer lists them, and the
    /// summary is consolidated without them at the next activation outside
    /// a conversation (`catchUpIfOverdue`) or background task.
    func factsRemoved(count: Int) async {
        await removals.factsRemoved(count: count)
    }

    /// `backend` with each fact the `forget` tool forgets (#68) reported as
    /// a removal, like a deletion in Settings.
    nonisolated func reportingRemovals(of backend: any MemoryToolBackend) -> any MemoryToolBackend {
        RemovalReportingMemoryToolBackend(base: backend, removals: removals)
    }

    /// When the background task should next look (after the retry backoff
    /// if the last run didn't finish), or `nil` while learning is off.
    func nextBackgroundCheck() async -> Date? {
        await consolidator.nextBackgroundCheck()
    }

    private func reloadLog() async {
        log = await consolidator.log()
    }
}

/// Converts BlauMemory's pinned memory into the realtime session's memory
/// context (the profile and the top facts in the instructions, #35).
struct PinnedRealtimeMemoryContext: RealtimeMemoryContextProviding {
    let pinned: PinnedMemoryProvider

    func memoryContext() async -> RealtimeMemoryContext {
        let memory = await pinned.pinnedMemory()
        return RealtimeMemoryContext(
            profile: memory.profile, facts: memory.facts.map { RealtimeMemoryContext.Fact($0.text, since: $0.since) })
    }
}

// MARK: - Factories

extension ProfileMemory {
    /// What the session instructions read: the profile and facts in the
    /// current store. Built before the realtime services, which take it.
    static func pinnedMemory(persistence: PersistenceController) -> PinnedMemoryProvider {
        PinnedMemoryProvider(store: profileStore(persistence))
    }

    /// The live app: consolidation with xAI's text API under the "Learn
    /// From Conversations" toggle and the thermal and power policy, topic
    /// summaries written through the transcript's store, the log in
    /// Application Support and the notes in `UserDefaults`.
    static func live(
        pinned: PinnedMemoryProvider,
        xai: XAIServices,
        transcript: PersistenceTranscriptRecorder,
        persistence: PersistenceController,
        learning: MemoryLearning,
        performance: PerformancePolicy
    ) -> ProfileMemory {
        var suiteName: String?
        var log: any ProfileConsolidationLogStore = FileProfileConsolidationLogStore.applicationSupport()
        #if DEBUG
            // UI-test launches never touch the developer's own log or notes.
            if XAIUITestStub.current != nil {
                suiteName = "blau.uitests"
                log = InMemoryProfileConsolidationLogStore()
            }
        #endif
        let preference = learning.settings.store
        let consolidator = ProfileConsolidator(
            generator: XAITextGenerator(client: xai.client),
            store: profileStore(persistence),
            topicSummaries: DeferredTopicSummaryWriter { try await transcript.conversationStore() },
            log: log,
            notes: UserDefaultsProfileConsolidationNoteStore(suiteName: suiteName),
            isEnabled: { preference.load() },
            gate: IndexingGate(performance: performance)
        )
        return ProfileMemory(consolidator: consolidator, pinned: pinned, schedulesBackgroundWork: true)
    }

    /// Previews, tests and UI-test launches: the in-memory store, a text
    /// model that is never available, and the log and notes in memory.
    static func offline(persistence: PersistenceController) -> ProfileMemory {
        let consolidator = ProfileConsolidator(
            generator: UnavailableProfileTextGenerator(), store: profileStore(persistence))
        return ProfileMemory(
            consolidator: consolidator, pinned: pinnedMemory(persistence: persistence), schedulesBackgroundWork: false)
    }

    private static func profileStore(_ persistence: PersistenceController) -> DeferredProfileMemoryStore {
        DeferredProfileMemoryStore { @MainActor [weak persistence] in persistence?.stack?.container }
    }
}

/// A text model that is never available, so offline environments never
/// send anything.
private struct UnavailableProfileTextGenerator: TextGenerator {
    struct Unavailable: Error {}

    func isAvailable() async -> Bool { false }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        throw Unavailable()
    }
}
