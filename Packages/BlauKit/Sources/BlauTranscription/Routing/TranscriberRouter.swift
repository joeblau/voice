import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Runs the right speech-to-text engine for the moment and switches between
/// them mid-conversation without losing or repeating words (#31).
///
/// ```swift
/// let router = TranscriberRouter(
///     parakeet: .init(isAvailable: { await models.directory(for: .parakeetRealtimeEOU) != nil },
///                     make: { try await ParakeetStreamingTranscriber.load(...) }),
///     apple: .init(isAvailable: { await AppleSpeechAssets.availability().isSupported },
///                  make: { AppleTranscriber(engine: SystemSpeechAnalyzerEngine(locale: try await AppleSpeechAssets.prepare()), ...) }),
///     preference: settings.enginePreference)
/// router.followPreferences(settings.preferenceChanges())   // the Settings toggle
/// try await router.start()
/// for await event in router.events { ... }                  // one stream, whichever engine runs
/// ```
///
/// **Which engine.** `TranscriberRoutingPolicy.choose(_:)` decides from the
/// user's preference, whether each engine is available, what
/// `BackgroundInferenceMonitor` asked for off screen and memory pressure.
/// The router re-decides on every change of those (`setPreference`,
/// `switchInferenceBackend(to:)`, `setMemoryPressure`,
/// `availabilityDidChange`).
///
/// **Off screen (#26).** The router is the speech-to-text stage (`"asr"`)
/// the background inference monitor manages: register it with
/// `monitor.register(router, budget: .milliseconds(320))`. Its backends are
/// the Neural Engine (Parakeet) and `systemSpeech` (Apple's engine); when
/// the monitor moves the stage to `systemSpeech` (the shipping mitigation
/// says so, or Parakeet keeps failing or falling behind off screen), the
/// router hands the conversation to Apple's engine at the next utterance
/// boundary, and back when Blau returns to the screen.
///
/// **Switching at an utterance boundary.** When the choice changes while
/// running, the router builds the new engine at once, then waits until the
/// running one has no utterance open (its last event was a final, and
/// `settleDelay` has passed without a new partial). Then it stops the old
/// engine (forwarding anything its stop commits), and starts the new one
/// with `start(resumingAt:)` at the end of the last committed utterance, so
/// the new engine reads any speech since then back from the capture
/// history. If no boundary comes within `maximumSwitchDelay` (a very long
/// monologue), it switches anyway: the old engine's `stop()` commits what
/// was said so far.
///
/// **One engine at a time.** Building an engine can take seconds (Apple's
/// may download its language assets first). While the router builds and
/// starts one (`start()`, or a retry after every engine failed) or hands
/// over to another, input changes are only recorded: the activation or
/// switch in progress re-decides from them when it ends, so the router
/// never builds two engines in parallel. Only the active engine's events,
/// and those of the one being drained on its way out, reach `events`.
public actor TranscriberRouter: Transcriber {
    /// How the router gets an engine.
    public struct EngineProvider: Sendable {
        /// Whether the engine can run now (its model installed, the language
        /// supported). Asked before every decision; keep it cheap.
        public let isAvailable: @Sendable () async -> Bool
        /// Builds a ready-to-start engine (loads its model). Called each time
        /// the router switches to it: an engine switched away from is
        /// finished and released, freeing its memory.
        public let make: @Sendable () async throws -> any RoutableTranscriber

        public init(
            isAvailable: @escaping @Sendable () async -> Bool,
            make: @escaping @Sendable () async throws -> any RoutableTranscriber
        ) {
            self.isAvailable = isAvailable
            self.make = make
        }
    }

    public struct Configuration: Hashable, Sendable {
        /// How long the running engine must stay quiet after a final before
        /// it is switched out, so the switch doesn't cut into speech that
        /// carries on straight after a commit.
        public var settleDelay: Duration
        /// The longest a switch waits for an utterance boundary.
        public var maximumSwitchDelay: Duration

        public init(settleDelay: Duration = .milliseconds(500), maximumSwitchDelay: Duration = .seconds(20)) {
            self.settleDelay = settleDelay
            self.maximumSwitchDelay = maximumSwitchDelay
        }

        public static let standard = Configuration()
    }

    /// What the router is running, for the HUD and diagnostics.
    public struct Status: Hashable, Sendable {
        public var engine: TranscriptionEngine?
        public var reason: TranscriberRoutingReason?
        /// The engine a switch is waiting to hand over to.
        public var pendingEngine: TranscriptionEngine?
        public var isRunning = false
    }

    public nonisolated let events: AsyncStream<TranscriptEvent>
    public nonisolated let configuration: Configuration

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let providers: [TranscriptionEngine: EngineProvider]
    private let clock: any BlauClock
    private let signposter: Signposter
    private let logger = Log.asr
    private let shared = Mutex(Shared())

    private struct Shared {
        var status = Status()
        var statistics = TranscriberRouterStatistics()
    }

    private var inputs: TranscriberRoutingInputs
    private var failedEngines: Set<TranscriptionEngine> = []
    private var conversationID: ConversationID?
    private var isRunning = false
    private var isFinished = false

    private var active: ActiveEngine?
    private var nextInstanceID = 0
    /// Whether the active engine has an utterance open (a partial since its
    /// last final).
    private var hasOpenUtterance = false
    /// `clock.uptime` of the active engine's latest event.
    private var lastEventAt: Duration?
    /// The end of the latest committed utterance: where the next engine
    /// resumes.
    private var resumePosition: Duration?

    private var pending: PendingSwitch?
    private var isSwitching = false
    /// Whether `start()` or a retry is building and starting an engine.
    /// Input changes meanwhile are deferred to the end of the activation.
    private var isActivating = false
    /// Whether an input changed while an activation or a switch was in
    /// progress, so it must re-decide when it ends.
    private var reevaluationDeferred = false
    /// Whether `stop()` is waiting for a switch in progress to end before
    /// it stops the engine that switch leaves running.
    private var isStopping = false
    /// Callers of `start()` waiting for an activation, a switch or a
    /// `stop()` in progress to end.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// Engines on their way out (`release()`): what their `stop()` commits
    /// is still forwarded.
    private var drainingIDs: Set<Int> = []
    /// The switch in progress. It runs in a task of its own, never inline
    /// from the event forwarding it waits on.
    private var switchTask: Task<Void, Never>?
    private var preferenceFeed: Task<Void, Never>?
    private var memoryPressureFeed: Task<Void, Never>?

    private struct ActiveEngine {
        let id: Int
        let engine: TranscriptionEngine
        let reason: TranscriberRoutingReason
        let transcriber: any RoutableTranscriber
        let forwarding: Task<Void, Never>
    }

    /// Callers of `switchInferenceBackend(to:)` waiting for the router to
    /// settle (no switch pending or running).
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    private struct PendingSwitch {
        let id: Int
        let engine: TranscriptionEngine
        let reason: TranscriberRoutingReason
        var transcriber: (any RoutableTranscriber)?
        var preparation: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var settleCheck: Task<Void, Never>?
        var requestedAt: Duration

        func cancelTasks() {
            preparation?.cancel()
            deadline?.cancel()
            settleCheck?.cancel()
        }
    }

    /// - Parameters:
    ///   - parakeet: The primary engine.
    ///   - apple: The fallback engine.
    ///   - preference: The user's choice (Settings).
    ///   - configuration: Switch timing.
    ///   - clock: Times the settle delay and the switch deadline.
    ///   - signposter: Where `asr.engineSwitch` events go.
    public init(
        parakeet: EngineProvider,
        apple: EngineProvider,
        preference: TranscriptionEnginePreference = .automatic,
        configuration: Configuration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.asr
    ) {
        self.providers = [.parakeet: parakeet, .apple: apple]
        self.inputs = TranscriberRoutingInputs(preference: preference)
        self.configuration = configuration
        self.clock = clock
        self.signposter = signposter
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        preferenceFeed?.cancel()
        memoryPressureFeed?.cancel()
        pending?.cancelTasks()
        active?.forwarding.cancel()
        continuation.finish()
    }

    /// What is running now.
    public nonisolated var status: Status { shared.withLock { $0.status } }

    /// The engine running now.
    public nonisolated var activeEngine: TranscriptionEngine? { status.engine }

    /// Switch counters.
    public nonisolated var statistics: TranscriberRouterStatistics { shared.withLock { $0.statistics } }

    /// The inputs the latest decision was made from.
    public var routingInputs: TranscriberRoutingInputs { inputs }

    // MARK: Transcriber

    public func start() async throws {
        // A `stop()` during an earlier `start()` or a switch lets that one
        // finish building its engine; this start then reuses it. Waiting
        // for a `stop()` in progress too keeps it from stopping the engine
        // this start brings up, and keeps this start from building a second
        // engine next to the one a switch is still building.
        while isActivating || isSwitching || isStopping {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        guard !isRunning, !isFinished else { return }
        isRunning = true
        isActivating = true
        do {
            await refreshAvailability()
            if let active, active.engine == TranscriberRoutingPolicy.choose(inputs)?.engine {
                // Restart after `stop()`: the engine is still built.
                try await active.transcriber.start(resumingAt: nil)
            } else {
                await release()
                try await activateBest(resumingAt: nil)
            }
        } catch {
            isRunning = false
            await endActivation()
            throw error
        }
        // The inputs may have changed while the engine was being built.
        await endActivation()
    }

    public func stop() async {
        guard isRunning, !isStopping else { return }
        isRunning = false
        isStopping = true
        publishStatus()
        defer {
            isStopping = false
            resumeStartWaiters()
        }
        await cancelPendingSwitch()
        // A switch in progress stops the engine it leaves running itself
        // when it sees the router isn't running any more.
        await switchTask?.value
        // Re-checked after every await: only stop an engine nobody has
        // started again meanwhile.
        guard !isRunning else { return }
        await active?.transcriber.stop()
        guard !isRunning else { return }
        publishStatus()
        logger.notice("Transcriber router stopped")
    }

    /// Stops, releases the engines and ends `events` for good.
    public func finish() async {
        await stop()
        // Marked before releasing, so a `start()` that was waiting for the
        // stop can't bring an engine up behind the release.
        isFinished = true
        preferenceFeed?.cancel()
        preferenceFeed = nil
        memoryPressureFeed?.cancel()
        memoryPressureFeed = nil
        await release()
        continuation.finish()
        resumeSettleWaiters(force: true)
    }

    /// Passes the phase change on to the running engine. Which engine runs
    /// off screen is `BackgroundInferenceMonitor`'s call
    /// (`switchInferenceBackend(to:)`), so a phase change alone switches
    /// nothing.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        await active?.transcriber.appPhaseDidChange(transition)
    }

    // MARK: Inputs

    /// Utterances committed from now on belong to `id`.
    public func setConversationID(_ id: ConversationID) async {
        conversationID = id
        await active?.transcriber.setConversationID(id)
        await pending?.transcriber?.setConversationID(id)
    }

    /// The user's engine choice changed.
    public func setPreference(_ preference: TranscriptionEnginePreference) async {
        guard preference != inputs.preference else { return }
        inputs.preference = preference
        logger.notice("Transcription engine preference: \(preference.rawValue, privacy: .public)")
        await reevaluate()
    }

    /// Follows the Settings toggle (`TranscriptionSettings
    /// .preferenceChanges()`) until `finish()`.
    public func followPreferences(_ changes: AsyncStream<TranscriptionEnginePreference>) {
        preferenceFeed?.cancel()
        preferenceFeed = Task { [weak self] in
            for await preference in changes {
                await self?.setPreference(preference)
            }
        }
    }

    /// Follows `levels` (`MemoryPressureMonitor.levels()`) until
    /// `finish()`: transcription moves to Apple's engine at `critical` and
    /// back once the pressure is `normal` again.
    public func followMemoryPressure(_ levels: AsyncStream<MemoryPressureLevel>) {
        memoryPressureFeed?.cancel()
        memoryPressureFeed = Task { [weak self] in
            for await level in levels {
                switch level {
                case .critical: await self?.setMemoryPressure(true)
                case .normal: await self?.setMemoryPressure(false)
                case .warning: break
                }
            }
        }
    }

    /// Whether the system reports critical memory pressure.
    public func setMemoryPressure(_ isCritical: Bool) async {
        guard isCritical != inputs.isUnderMemoryPressure else { return }
        inputs.isUnderMemoryPressure = isCritical
        await reevaluate()
    }

    /// An engine's availability may have changed (a model finished
    /// downloading or was deleted). Engines that failed to load get another
    /// chance.
    public func availabilityDidChange() async {
        failedEngines.removeAll()
        await reevaluate()
    }

    // MARK: Deciding

    private func refreshAvailability() async {
        for engine in TranscriptionEngine.allCases {
            let available = await providers[engine]?.isAvailable() ?? false
            let usable = available && !failedEngines.contains(engine)
            switch engine {
            case .parakeet: inputs.parakeetAvailable = usable
            case .apple: inputs.appleAvailable = usable
            }
        }
    }

    /// Re-decides and starts or cancels a switch when running.
    private func reevaluate() async {
        await refreshAvailability()
        guard isRunning, !isFinished else { return }
        guard !isActivating, !isSwitching else {
            // The activation or switch in progress re-decides when it ends.
            reevaluationDeferred = true
            return
        }
        await decide()
    }

    /// Starts or cancels a switch for the current inputs, or starts an
    /// engine if none runs. The caller has refreshed availability and made
    /// sure no other activation or switch is in progress.
    private func decide() async {
        guard let choice = TranscriberRoutingPolicy.choose(inputs) else {
            logger.error(
                "No transcription engine can run; keeping \(self.active?.engine.rawValue ?? "none", privacy: .public)")
            return
        }
        guard let active else {
            // Nothing running (every engine failed earlier): try again now.
            isActivating = true
            do {
                try await activateBest(resumingAt: resumePosition)
            } catch {
                logger.error(
                    "Transcriber router couldn't start an engine: \(String(describing: error), privacy: .public)")
            }
            await endActivation()
            return
        }
        if choice.engine == active.engine {
            if pending != nil {
                await cancelPendingSwitch()
                logger.notice("Transcriber router stays on \(active.engine.rawValue, privacy: .public)")
            }
            return
        }
        guard pending?.engine != choice.engine else { return }
        await cancelPendingSwitch()
        requestSwitch(to: choice.engine, reason: choice.reason)
    }

    // MARK: Switching

    private func requestSwitch(to engine: TranscriptionEngine, reason: TranscriberRoutingReason) {
        nextInstanceID += 1
        let id = nextInstanceID
        var switchRequest = PendingSwitch(id: id, engine: engine, reason: reason, requestedAt: clock.uptime)
        switchRequest.preparation = Task { [weak self] in
            await self?.prepareSwitch(id: id)
        }
        pending = switchRequest
        publishStatus()
        logger.notice(
            "Transcriber router will switch to \(engine.rawValue, privacy: .public) (\(reason.rawValue, privacy: .public)) at the next utterance boundary"
        )
    }

    /// Builds the pending engine, then waits for a boundary.
    private func prepareSwitch(id: Int) async {
        guard let request = pending, request.id == id, let provider = providers[request.engine] else { return }
        let transcriber: any RoutableTranscriber
        do {
            transcriber = try await provider.make()
        } catch {
            guard pending?.id == id else { return }
            pending = nil
            failedEngines.insert(request.engine)
            record { $0.failedActivations += 1 }
            logger.error(
                "Couldn't prepare \(request.engine.rawValue, privacy: .public) ASR: \(String(describing: error), privacy: .public)"
            )
            publishStatus()
            await reevaluate()
            return
        }
        if let conversationID {
            await transcriber.setConversationID(conversationID)
        }
        // Re-read after the awaits: the switch may have been cancelled or
        // replaced meanwhile.
        guard var current = pending, current.id == id, !Task.isCancelled else {
            await transcriber.finish()
            return
        }
        let elapsed = clock.uptime - current.requestedAt
        let remaining = max(.zero, configuration.maximumSwitchDelay - elapsed)
        let clock = self.clock
        current.transcriber = transcriber
        current.deadline = Task { [weak self] in
            do {
                try await clock.sleep(for: remaining)
            } catch {
                return
            }
            await self?.beginSwitch(id: id, forced: true)
        }
        pending = current
        attemptSwitch()
    }

    /// Switches now if the active engine is between utterances and has been
    /// quiet for `settleDelay`; otherwise checks again when it is.
    private func attemptSwitch() {
        guard var request = pending, request.transcriber != nil, !isSwitching else { return }
        guard !hasOpenUtterance else { return }  // the next final calls this again
        let quiet = lastEventAt.map { clock.uptime - $0 } ?? configuration.settleDelay
        if quiet >= configuration.settleDelay {
            beginSwitch(id: request.id, forced: false)
            return
        }
        guard request.settleCheck == nil else { return }
        let wait = configuration.settleDelay - quiet
        let clock = self.clock
        let id = request.id
        request.settleCheck = Task { [weak self] in
            do {
                try await clock.sleep(for: wait)
            } catch {
                return
            }
            await self?.settleCheckFired(id: id)
        }
        pending = request
    }

    private func settleCheckFired(id: Int) {
        guard var request = pending, request.id == id else { return }
        request.settleCheck = nil
        pending = request
        attemptSwitch()
    }

    /// Hands the switch to a task of its own. The caller may be the old
    /// engine's event forwarding, which the switch waits to drain.
    private func beginSwitch(id: Int, forced: Bool) {
        guard let request = pending, request.id == id, let incoming = request.transcriber, !isSwitching else { return }
        isSwitching = true
        pending = nil
        request.cancelTasks()
        switchTask = Task {
            await self.performSwitch(request, incoming: incoming, forced: forced)
        }
    }

    /// Waits for the switch in progress, if any. For tests.
    func waitForSwitch() async {
        while let task = switchTask {
            await task.value
            if switchTask == task {
                switchTask = nil
            }
        }
    }

    private func performSwitch(_ request: PendingSwitch, incoming: any RoutableTranscriber, forced: Bool) async {
        let outgoing = active?.engine

        await release()
        let resume = resumePosition
        do {
            try await activate(incoming, engine: request.engine, reason: request.reason, resumingAt: resume)
            record {
                $0.switches[request.reason, default: 0] += 1
                if forced { $0.forcedSwitches += 1 }
            }
            signposter.event("asr.engineSwitch")
            logger.notice(
                """
                Transcriber router switched \(outgoing?.rawValue ?? "none", privacy: .public) → \
                \(request.engine.rawValue, privacy: .public) (\(request.reason.rawValue, privacy: .public)\
                \(forced ? ", forced" : "", privacy: .public)) at \(resume.map { "\($0)" } ?? "now", privacy: .public)
                """
            )
        } catch {
            failedEngines.insert(request.engine)
            record { $0.failedActivations += 1 }
            logger.error(
                "Couldn't start \(request.engine.rawValue, privacy: .public) ASR: \(String(describing: error), privacy: .public)"
            )
            await refreshAvailability()
            do {
                try await activateBest(resumingAt: resume)
            } catch {
                logger.error(
                    "Transcriber router has no engine running: \(String(describing: error), privacy: .public)")
            }
        }
        isSwitching = false
        reevaluationDeferred = false
        publishStatus()
        resumeStartWaiters()
        if isFinished {
            await release()
        } else if !isRunning {
            await active?.transcriber.stop()
        } else {
            // The inputs may have changed again while switching.
            await reevaluate()
        }
    }

    /// Ends an activation (`start()` or `decide()`'s retry): applies a
    /// `stop()` or `finish()` that came meanwhile, re-decides from inputs
    /// that changed meanwhile, and lets a waiting `start()` go on.
    private func endActivation() async {
        await refreshAvailability()
        if isFinished {
            await release()
        } else if !isRunning {
            await active?.transcriber.stop()
        } else if active != nil {
            // Still marked as activating, so no other activation can slip
            // in, and a monitor waiting in `switchInferenceBackend` sees
            // the switch this may request rather than a settled router.
            await decide()
        }
        let again = reevaluationDeferred && isRunning && !isFinished
        reevaluationDeferred = false
        isActivating = false
        publishStatus()
        resumeStartWaiters()
        if again {
            await reevaluate()
        }
    }

    /// Lets callers of `start()` re-check whether they can go on.
    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelPendingSwitch() async {
        guard let request = pending else { return }
        pending = nil
        request.cancelTasks()
        await request.transcriber?.finish()
        publishStatus()
    }

    // MARK: Engines

    /// Starts the engine the policy picks, falling back to the other one if
    /// it can't start.
    private func activateBest(resumingAt position: Duration?) async throws {
        var lastError: (any Error)?
        for _ in TranscriptionEngine.allCases {
            guard let choice = TranscriberRoutingPolicy.choose(inputs), let provider = providers[choice.engine] else {
                break
            }
            do {
                let transcriber = try await provider.make()
                if let conversationID {
                    await transcriber.setConversationID(conversationID)
                }
                try await activate(transcriber, engine: choice.engine, reason: choice.reason, resumingAt: position)
                return
            } catch {
                lastError = error
                failedEngines.insert(choice.engine)
                record { $0.failedActivations += 1 }
                logger.error(
                    "Couldn't start \(choice.engine.rawValue, privacy: .public) ASR: \(String(describing: error), privacy: .public)"
                )
                await refreshAvailability()
            }
        }
        throw lastError ?? TranscriberRouterError.noEngineAvailable
    }

    /// Makes `transcriber` the active engine: forwards its events and
    /// starts it.
    private func activate(
        _ transcriber: any RoutableTranscriber,
        engine: TranscriptionEngine,
        reason: TranscriberRoutingReason,
        resumingAt position: Duration?
    ) async throws {
        nextInstanceID += 1
        let id = nextInstanceID
        let events = transcriber.events
        let forwarding = Task { [weak self] in
            for await event in events {
                await self?.receive(event, from: id)
            }
        }
        hasOpenUtterance = false
        lastEventAt = nil
        active = ActiveEngine(id: id, engine: engine, reason: reason, transcriber: transcriber, forwarding: forwarding)
        do {
            try await transcriber.start(resumingAt: position)
        } catch {
            if active?.id == id {
                active = nil
            }
            await transcriber.finish()
            await forwarding.value
            throw error
        }
        logger.notice(
            "Transcription engine: \(engine.rawValue, privacy: .public) (\(reason.rawValue, privacy: .public))")
        publishStatus()
    }

    /// Stops and finishes the active engine, after forwarding every event
    /// it emits on the way out.
    private func release() async {
        guard let old = active else { return }
        drainingIDs.insert(old.id)
        await old.transcriber.stop()
        await old.transcriber.finish()
        await old.forwarding.value
        drainingIDs.remove(old.id)
        if active?.id == old.id {
            active = nil
        }
    }

    /// Forwards one event from the active engine (or one being drained)
    /// and tracks where utterances end. Events from any other engine are
    /// dropped, so a stray engine can never put a second copy of an
    /// utterance on `events`.
    private func receive(_ event: TranscriptEvent, from id: Int) async {
        guard id == active?.id || drainingIDs.contains(id) else {
            logger.error("Transcriber router dropped an event from engine #\(id, privacy: .public), which isn't active")
            return
        }
        continuation.yield(event)
        if case .final(let utterance) = event {
            resumePosition = max(resumePosition ?? .zero, utterance.timeRange.end)
        }
        guard id == active?.id else { return }
        lastEventAt = clock.uptime
        switch event {
        case .partial:
            hasOpenUtterance = true
        case .final:
            hasOpenUtterance = false
            attemptSwitch()
        case .refined:
            // A second pass's better text for an earlier utterance: it says
            // nothing about whether one is open now.
            break
        }
    }

    // MARK: Status

    private func publishStatus() {
        let status = Status(
            engine: active?.engine, reason: active?.reason, pendingEngine: pending?.engine, isRunning: isRunning)
        shared.withLock { $0.status = status }
        resumeSettleWaiters()
    }

    /// Whether no switch is pending or running and no engine is being
    /// started.
    private var isSettled: Bool { pending == nil && !isSwitching && !isActivating }

    /// Suspends until no switch is pending or running.
    private func waitUntilSettled() async {
        guard !isSettled else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    private func resumeSettleWaiters(force: Bool = false) {
        guard force || isSettled, !settleWaiters.isEmpty else { return }
        let waiters = settleWaiters
        settleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func record(_ body: (inout TranscriberRouterStatistics) -> Void) {
        shared.withLock { body(&$0.statistics) }
    }
}

/// Counters from `TranscriberRouter`.
public struct TranscriberRouterStatistics: Hashable, Sendable {
    /// Completed switches, by why.
    public var switches: [TranscriberRoutingReason: Int64] = [:]
    /// Switches made without waiting for an utterance boundary.
    public var forcedSwitches: Int64 = 0
    /// Engines that failed to build or start.
    public var failedActivations: Int64 = 0

    public init() {}

    public var totalSwitches: Int64 { switches.values.reduce(0, +) }
}

public enum TranscriberRouterError: Error, Hashable, Sendable {
    /// Neither engine can run (no Parakeet model, and Apple's engine
    /// doesn't support the device or language).
    case noEngineAvailable
    /// The engine couldn't be built or started; the router keeps running
    /// the other one.
    case engineUnavailable(TranscriptionEngine)
}

// MARK: - Background inference (#26)

extension TranscriberRouter: InferenceBackendSwitchable {
    /// The stage name `BackgroundInferenceMonitor` knows speech-to-text by.
    public static let inferenceStage = ParakeetStreamingTranscriber.inferenceStage

    public nonisolated var inferenceStage: String { Self.inferenceStage }

    /// Parakeet on the Neural Engine, then Apple's `SpeechTranscriber`.
    /// (Parakeet on the CPU would sit between them once
    /// `ParakeetEouRecognizer` can load with `.cpuOnly`.)
    public nonisolated var supportedBackends: [InferenceBackend] { [.neuralEngine, .systemSpeech] }

    /// `systemSpeech` while Apple's engine runs, for whatever reason.
    public var inferenceBackend: InferenceBackend {
        active?.engine == .apple ? .systemSpeech : .neuralEngine
    }

    /// Moves speech-to-text to Apple's engine (`systemSpeech`) or back to
    /// Parakeet (`neuralEngine`), at the next utterance boundary, and
    /// returns once the switch is done (at most `maximumSwitchDelay` later).
    ///
    /// Going back to `neuralEngine` while the user's preference (or a
    /// missing Parakeet model) keeps Apple's engine running is not an
    /// error: the request is recorded and the other reason wins.
    ///
    /// - Throws: `TranscriberRouterError.engineUnavailable(.apple)` when
    ///   Apple's engine can't run (the monitor then marks the backend
    ///   unusable); `InferenceBackendError.unsupported` for the CPU.
    public func switchInferenceBackend(to backend: InferenceBackend) async throws {
        guard supportedBackends.contains(backend) else {
            throw InferenceBackendError.unsupported(stage: inferenceStage, backend: backend)
        }
        let wantsSystemSpeech = backend == .systemSpeech
        if inputs.systemSpeechRequested != wantsSystemSpeech {
            inputs.systemSpeechRequested = wantsSystemSpeech
            logger.notice(
                "Background inference moves speech-to-text to \(backend.rawValue, privacy: .public)")
            await reevaluate()
        }
        await waitUntilSettled()
        if wantsSystemSpeech, isRunning, active?.engine != .apple {
            inputs.systemSpeechRequested = false
            throw TranscriberRouterError.engineUnavailable(.apple)
        }
    }
}
