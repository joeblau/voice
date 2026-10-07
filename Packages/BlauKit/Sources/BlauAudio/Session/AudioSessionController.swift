import BlauCore
import BlauTelemetry
import Synchronization
import os

/// Owns the audio session and the voice-processing engine for a long-form,
/// full-duplex conversation, and keeps them running through phone calls,
/// route changes (AirPods ↔ speaker), engine reconfigurations and
/// media-server resets.
///
/// ```swift
/// let audio = AudioSessionController.live()
/// await audio.register(captureTap)      // #24
/// await audio.register(playbackNode)    // #25
/// await audio.start()
/// for await snapshot in await audio.updates() {
///     // snapshot.state, snapshot.route
/// }
/// ```
///
/// **Lifecycle.** `start()` checks microphone permission, configures the
/// session (`.playAndRecord`, `.voiceChat`, `[.defaultToSpeaker,
/// .allowBluetoothHFP]`, 48 kHz, 20 ms buffers), activates it, enables
/// voice processing on the stopped engine, installs the registered graph
/// components and starts the engine. `stop()` undoes all of it.
///
/// **Recovery.** While the caller wants audio running, the controller
/// handles:
/// - *Interruptions*: `interrupted` on begin; on end with `.shouldResume`
///   it reactivates and rebuilds. Without `.shouldResume` it stays
///   `interrupted` until `start()`.
/// - *Route changes*: publishes the new route; if the change stopped the
///   engine, or another framework changed the category, it rebuilds.
/// - *`AVAudioEngineConfigurationChange`*: rebuilds the graph so formats
///   follow the new hardware (for example 48 kHz speaker → 16 kHz HFP).
/// - *Media services reset*: recreates the engine and reconfigures the
///   session from scratch.
///
/// A rebuild that fails is retried after each of `RecoveryPolicy.retryDelays`
/// (devices often need a moment after a Bluetooth route switch); if every
/// attempt fails the state becomes `failed`.
public actor AudioSessionController {
    /// How hard to try when the engine won't come back after a change.
    public struct RecoveryPolicy: Sendable, Hashable {
        /// Delay before each attempt. The first is usually zero.
        public var retryDelays: [Duration]

        public init(retryDelays: [Duration]) {
            precondition(!retryDelays.isEmpty, "Recovery needs at least one attempt")
            self.retryDelays = retryDelays
        }

        /// Five attempts over about two seconds.
        public static let standard = RecoveryPolicy(retryDelays: [
            .zero, .milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1),
        ])
    }

    /// Why the graph is being rebuilt, for logs.
    enum RebuildCause: String, Sendable {
        case interruptionEnded
        case routeChange
        case categoryChange
        case engineConfigurationChange
        case mediaServicesReset
        case graphChanged
    }

    // MARK: Dependencies

    public nonisolated let configuration: AudioSessionConfiguration
    private let session: any AudioSessionBackend
    private let permission: any MicrophonePermissionProvider
    private let makeEngine: @Sendable () -> any AudioEngineBackend
    private let clock: any BlauClock
    private let recoveryPolicy: RecoveryPolicy
    private let signposter: Signposter
    private let logger = Log.audio

    // MARK: State

    /// The current lifecycle state.
    public private(set) var state: AudioSessionState = .idle
    /// The current route.
    public private(set) var route: AudioRoute

    private var engine: any AudioEngineBackend
    private var components: [any AudioGraphComponent] = []
    /// Whether the caller wants audio running: set by `start()`, cleared by
    /// `stop()` and by a failure.
    private var wantsRunning = false
    private var isSessionActive = false
    /// Bumped by every start, stop, interruption and rebuild, so work that
    /// was suspended (a permission prompt, a retry delay) can tell it has
    /// been superseded.
    private var generation: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    /// The session event loop and the first engine's configuration-change
    /// loop, started by `init`.
    private let observers = ObservationTasks()
    /// The configuration-change loop of an engine created after a
    /// media-services reset.
    private var engineEventsTask: Task<Void, Never>?
    /// Identifies the current engine, so a late configuration change from
    /// an engine replaced after a media-services reset is ignored.
    private var engineID: UInt64 = 0

    private var subscribers: [UInt64: AsyncStream<AudioSessionSnapshot>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0
    private var lastPublished: AudioSessionSnapshot?

    // MARK: Init

    /// - Parameters:
    ///   - session: The audio session. `SystemAudioSession()` on iOS.
    ///   - permission: Microphone permission. `SystemMicrophonePermission()`.
    ///   - configuration: Session and voice-processing settings.
    ///   - clock: Time source for retry delays.
    ///   - recoveryPolicy: Retry delays for rebuilding after a change.
    ///   - signposter: Where lifecycle intervals and events go.
    ///   - makeEngine: Creates the engine. Called once now and again after
    ///     every media-services reset. `VoiceProcessingAudioEngine.init` in
    ///     production.
    public init(
        session: any AudioSessionBackend,
        permission: any MicrophonePermissionProvider,
        configuration: AudioSessionConfiguration = .voiceChat,
        clock: any BlauClock = SystemClock(),
        recoveryPolicy: RecoveryPolicy = .standard,
        signposter: Signposter = Signposts.audio,
        makeEngine: @escaping @Sendable () -> any AudioEngineBackend
    ) {
        self.session = session
        self.permission = permission
        self.configuration = configuration
        self.clock = clock
        self.recoveryPolicy = recoveryPolicy
        self.signposter = signposter
        self.makeEngine = makeEngine
        let engine = makeEngine()
        self.engine = engine
        self.route = session.currentRoute

        // A synchronous actor initializer can't assign isolated properties
        // once `self` is captured, so the initial observation tasks go into
        // a Sendable holder that already exists.
        let sessionEvents = session.events
        let engineChanges = engine.configurationChanges
        observers.add(
            Task { [weak self] in
                for await event in sessionEvents {
                    await self?.handle(event)
                }
            }
        )
        observers.add(
            Task { [weak self] in
                for await _ in engineChanges {
                    await self?.engineConfigurationChanged(engineID: 0)
                }
            }
        )
    }

    deinit {
        observers.cancelAll()
        engineEventsTask?.cancel()
        recoveryTask?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: Observing

    /// The current state and route.
    public var snapshot: AudioSessionSnapshot {
        AudioSessionSnapshot(state: state, route: route)
    }

    /// A stream that starts with the current snapshot and then yields every
    /// change of state or route. Each call returns an independent stream;
    /// cancel the iterating task to stop observing.
    public func updates() -> AsyncStream<AudioSessionSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionSnapshot.self)
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    // MARK: Graph components

    /// Adds a node or tap to the engine graph. Register components before
    /// `start()`; registering while running rebuilds the graph, which
    /// briefly interrupts audio.
    public func register(_ component: any AudioGraphComponent) {
        guard !components.contains(where: { $0 === component }) else { return }
        components.append(component)
        if state == .running {
            scheduleRebuild(.graphChanged)
        }
    }

    /// Removes a component added with `register(_:)`.
    public func unregister(_ component: any AudioGraphComponent) {
        guard components.contains(where: { $0 === component }) else { return }
        if state == .running {
            components.removeAll { $0 === component }
            scheduleRebuild(.graphChanged)
        } else {
            components.removeAll { $0 === component }
        }
    }

    // MARK: Start and stop

    /// Starts capture and playback, asking for microphone permission first
    /// if needed. Also resumes from `interrupted` and retries from `failed`.
    /// Does nothing if already starting or running.
    ///
    /// - Returns: The state afterwards: `running`, or `failed` with the
    ///   reason. (It can be `idle` if `stop()` was called meanwhile.)
    @discardableResult
    public func start() async -> AudioSessionState {
        switch state {
        case .starting, .running:
            return state
        case .idle, .interrupted, .failed:
            break
        }

        wantsRunning = true
        let token = supersedePendingWork()
        setState(.starting)

        let granted = await ensureMicrophonePermission()
        guard token == generation, wantsRunning else {
            // stop() or an interruption ran while the permission prompt was up.
            return state
        }
        guard granted else {
            fail(.microphonePermissionDenied)
            return state
        }

        do {
            try signposter.withInterval("audio.sessionStart") { () throws(AudioSessionError) in
                try bringUp()
            }
            setState(.running)
        } catch {
            fail(error)
        }
        return state
    }

    /// Stops capture and playback and deactivates the session, letting
    /// other apps' audio resume. Safe to call in any state.
    public func stop() {
        wantsRunning = false
        supersedePendingWork()
        tearDownEngine()
        deactivateSession()
        setState(.idle)
    }

    // MARK: Session events

    /// Applies one session event. The event loop calls this for everything
    /// `session.events` yields; tests call it directly.
    func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan(let reason):
            interruptionBegan(reason)
        case .interruptionEnded(let shouldResume):
            interruptionEnded(shouldResume: shouldResume)
        case .routeChanged(let reason, let newRoute):
            routeChanged(reason, to: newRoute)
        case .mediaServicesLost:
            mediaServicesLost()
        case .mediaServicesReset:
            mediaServicesReset()
        }
    }

    private func interruptionBegan(_ reason: AudioInterruptionReason) {
        signposter.event("audio.interruptionBegan")
        logger.notice(
            "Interruption began (reason: \(reason.rawValue, privacy: .public), state: \(self.state, privacy: .public))")
        // `.interrupted` too: a second interruption must cancel a resume
        // that is already scheduled.
        guard wantsRunning, state == .running || state == .interrupted else { return }
        supersedePendingWork()
        // The system has already stopped the engine and deactivated the
        // session; stopping again keeps our bookkeeping honest.
        engine.stop()
        isSessionActive = false
        setState(.interrupted)
    }

    private func interruptionEnded(shouldResume: Bool) {
        signposter.event("audio.interruptionEnded")
        logger.notice(
            "Interruption ended (shouldResume: \(shouldResume, privacy: .public), state: \(self.state, privacy: .public))"
        )
        guard wantsRunning, state == .interrupted else { return }
        if shouldResume {
            scheduleRebuild(.interruptionEnded)
        } else {
            logger.notice("Not resuming automatically; waiting for start()")
        }
    }

    private func routeChanged(_ reason: AudioRouteChangeReason, to newRoute: AudioRoute) {
        signposter.event("audio.routeChange")
        logger.notice(
            "Route changed (reason: \(reason.rawValue, privacy: .public)): \(newRoute.summary, privacy: .public)"
        )
        route = newRoute
        publish()

        guard wantsRunning, state == .running else { return }
        switch reason {
        case .noSuitableRouteForCategory:
            fail(.noSuitableRoute)
        case .categoryChange:
            // Our own setCategory also lands here; only react if someone
            // else changed it.
            if !session.isConfigured(for: configuration) {
                scheduleRebuild(.categoryChange)
            }
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep,
            .routeConfigurationChange, .unknown:
            // Usually AVAudioEngineConfigurationChange follows and triggers
            // the rebuild. If the engine stopped without one, rebuild now.
            if !engine.isRunning {
                scheduleRebuild(.routeChange)
            }
        }
    }

    private func mediaServicesLost() {
        signposter.event("audio.mediaServicesLost")
        logger.error("Media services were lost")
        guard wantsRunning, state == .running || state == .interrupted else { return }
        supersedePendingWork()
        // Every audio object is dead: don't call into the engine.
        isSessionActive = false
        setState(.interrupted)
    }

    private func mediaServicesReset() {
        signposter.event("audio.mediaServicesReset")
        logger.error("Media services were reset; recreating the engine")
        replaceEngine()
        isSessionActive = false
        route = session.currentRoute
        switch state {
        case .running, .interrupted:
            setState(.interrupted)
            scheduleRebuild(.mediaServicesReset)
        case .starting:
            // start() is waiting on the permission prompt and brings the
            // new engine up itself.
            publish()
        case .idle, .failed:
            publish()
        }
    }

    func engineConfigurationChanged(engineID: UInt64) {
        guard engineID == self.engineID else { return }
        signposter.event("audio.engineConfigurationChange")
        logger.notice("Engine configuration changed (state: \(self.state, privacy: .public))")
        // When not running, the next start() builds the graph from scratch.
        guard wantsRunning, state == .running else { return }
        scheduleRebuild(.engineConfigurationChange)
    }

    // MARK: Rebuilding

    /// Cancels any pending rebuild and starts a new one.
    private func scheduleRebuild(_ cause: RebuildCause) {
        let token = supersedePendingWork()
        recoveryTask = Task {
            await rebuild(cause, token: token)
        }
    }

    private func rebuild(_ cause: RebuildCause, token: UInt64) async {
        var lastError = AudioSessionError.engineStartFailed(
            SystemError(domain: "BlauAudio", code: 0, message: "No attempt made")
        )
        for (attempt, delay) in recoveryPolicy.retryDelays.enumerated() {
            if delay > .zero {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard token == generation, wantsRunning else { return }
            do {
                try signposter.withInterval("audio.graphRebuild") { () throws(AudioSessionError) in
                    try bringUp()
                }
                logger.notice(
                    "Rebuilt after \(cause.rawValue, privacy: .public) (attempt \(attempt + 1, privacy: .public))"
                )
                setState(.running)
                return
            } catch {
                lastError = error
                logger.error(
                    """
                    Rebuild after \(cause.rawValue, privacy: .public) failed \
                    (attempt \(attempt + 1, privacy: .public)): \(error, privacy: .public)
                    """
                )
            }
        }
        guard token == generation else { return }
        fail(lastError)
    }

    /// Configures and activates the session, then builds and starts the
    /// graph from scratch. Synchronous, so nothing interleaves with it.
    private func bringUp() throws(AudioSessionError) {
        engine.stop()
        engine.teardown()

        do {
            try session.configure(configuration)
        } catch {
            throw .configurationFailed(SystemError(error))
        }
        do {
            try session.activate()
        } catch {
            throw .activationFailed(SystemError(error))
        }
        isSessionActive = true

        do {
            try engine.prepare(voiceProcessing: configuration.voiceProcessing, components: components)
        } catch {
            engine.teardown()
            throw .graphSetupFailed(SystemError(error))
        }
        do {
            try engine.start()
        } catch {
            engine.teardown()
            throw .engineStartFailed(SystemError(error))
        }

        route = session.currentRoute
        logger.notice(
            """
            Audio running: \(self.route.summary, privacy: .public), \
            voice processing \(self.configuration.voiceProcessing.isEnabled, privacy: .public), \
            \(self.components.count, privacy: .public) component(s)
            """
        )
    }

    // MARK: Helpers

    /// Cancels pending rebuilds and invalidates suspended work.
    ///
    /// - Returns: The new generation.
    @discardableResult
    private func supersedePendingWork() -> UInt64 {
        recoveryTask?.cancel()
        recoveryTask = nil
        generation &+= 1
        return generation
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch permission.status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            logger.notice("Requesting microphone permission")
            return await permission.request()
        }
    }

    private func fail(_ error: AudioSessionError) {
        logger.error("Audio session failed: \(error, privacy: .public)")
        wantsRunning = false
        supersedePendingWork()
        tearDownEngine()
        deactivateSession()
        setState(.failed(error))
    }

    private func tearDownEngine() {
        engine.stop()
        engine.teardown()
    }

    private func deactivateSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        do {
            try session.deactivate()
        } catch {
            // Deactivation failing leaves nothing for us to undo.
            logger.error("Deactivating the session failed: \(SystemError(error), privacy: .public)")
        }
    }

    private func replaceEngine() {
        engineEventsTask?.cancel()
        engine = makeEngine()
        engineID &+= 1
        let id = engineID
        let changes = engine.configurationChanges
        engineEventsTask = Task { [weak self] in
            for await _ in changes {
                await self?.engineConfigurationChanged(engineID: id)
            }
        }
    }

    private func setState(_ newState: AudioSessionState) {
        if state != newState {
            logger.notice("State \(self.state, privacy: .public) -> \(newState, privacy: .public)")
        }
        state = newState
        publish()
    }

    private func publish() {
        let current = snapshot
        guard current != lastPublished else { return }
        lastPublished = current
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    private func removeSubscriber(_ id: UInt64) {
        subscribers[id] = nil
    }

    /// Waits for the pending rebuild, if any. For tests.
    func waitForPendingRebuild() async {
        await recoveryTask?.value
    }
}

/// Long-lived tasks started from `AudioSessionController.init` and
/// cancelled when the controller goes away.
private final class ObservationTasks: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        for task in tasks.withLock({ $0 }) {
            task.cancel()
        }
    }
}
