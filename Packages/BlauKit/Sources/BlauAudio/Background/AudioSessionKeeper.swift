import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Something that only moves forward while audio is being captured.
/// `AudioSessionKeeper`'s watchdog reads it to notice a silent stall.
public protocol CaptureProgressSource: Sendable {
    /// 16 kHz samples captured so far, counting audio lost to drops (time
    /// still moved). Stops growing only when no audio arrives at all.
    var capturedSampleCount: Int64 { get }
}

extension CaptureHub: CaptureProgressSource {
    public var capturedSampleCount: Int64 { nextSampleOffset }
}

/// Keeps a conversation's audio alive for as long as the user wants it, on
/// screen, off screen and with the device locked (#26, docs/background.md).
///
/// It is the app's `AudioService`. `startCapture()` brings up the
/// `AudioSessionController` (whose active `.playAndRecord` session and
/// running engine are what keep Blau running off screen, with the `audio`
/// background mode); `stopCapture()` releases it. In between it:
///
/// - **never stops audio because Blau left the screen** or the device
///   locked;
/// - **watches capture** (`CaptureProgressSource`) and, when audio stops
///   flowing while the controller says it is running (a silent stall that
///   no notification reports), rebuilds the graph without deactivating the
///   session, which works off screen; after `maximumStallRecoveries` failed
///   rebuilds it restarts from scratch when that is allowed (on screen) or
///   pauses until Blau is opened;
/// - **resumes on return to the foreground** whatever couldn't resume off
///   screen: an interruption that ended without `.shouldResume`, a failed
///   rebuild, a stall it gave up on (iOS doesn't let a background app start
///   recording). An interruption still in progress is left alone, since it
///   may be a call; the user takes the session back with `startCapture()`
///   (an interruption-ended notification is not guaranteed);
/// - **drives the recording indicator** (the Live Activity) and publishes
///   its `Snapshot` for the UI;
/// - **counts** background trips, interruptions, stalls, resumes and the
///   time spent in each phase (`Statistics`), for the soak report.
public actor AudioSessionKeeper: AudioService {
    public struct Configuration: Sendable, Hashable {
        /// How often the watchdog checks that audio is flowing.
        public var watchdogInterval: Duration
        /// No captured audio for this long while running is a stall.
        public var stallTimeout: Duration
        /// Graph rebuilds tried for one stall before restarting (on screen)
        /// or pausing (off screen).
        public var maximumStallRecoveries: Int

        public init(
            watchdogInterval: Duration = .seconds(1),
            stallTimeout: Duration = .seconds(3),
            maximumStallRecoveries: Int = 3
        ) {
            // A stall is noticed on the first check at least `stallTimeout`
            // after the last audio, so keep the interval well below it.
            precondition(watchdogInterval > .zero && stallTimeout > .zero)
            precondition(maximumStallRecoveries >= 0)
            self.watchdogInterval = watchdogInterval
            self.stallTimeout = stallTimeout
            self.maximumStallRecoveries = maximumStallRecoveries
        }

        public static let standard = Configuration()
    }

    /// Where the conversation's audio is.
    public enum Status: Sendable, Hashable, CustomStringConvertible {
        /// No conversation.
        case inactive
        /// Coming up (permission, session, engine).
        case starting
        /// Capturing and playing.
        case live
        /// Audio stopped flowing; the graph is being rebuilt.
        case recovering
        /// The system has the session (a call, Siri, another app's audio);
        /// the controller resumes when the system says it should. Returning
        /// to the foreground doesn't take it back (a call is never fought);
        /// an explicit `startCapture()` does.
        case interrupted
        /// Audio stopped and won't restart until the user is in Blau: it
        /// resumes on the next return to the foreground, or on
        /// `startCapture()`.
        case paused
        /// Starting or recovering failed on screen. `startCapture()`, or the
        /// next return to the foreground, tries again.
        case failed(AudioSessionError)

        public var description: String {
            switch self {
            case .inactive: "inactive"
            case .starting: "starting"
            case .live: "live"
            case .recovering: "recovering"
            case .interrupted: "interrupted"
            case .paused: "paused"
            case .failed(let error): "failed(\(error))"
            }
        }

        /// What the recording indicator shows, or `nil` to hide it.
        public var indicatorStatus: RecordingIndicatorState.Status? {
            switch self {
            case .inactive: nil
            case .live: .listening
            case .starting, .recovering: .reconnecting
            case .interrupted: .interrupted
            case .paused, .failed: .needsAttention
            }
        }
    }

    /// Counters for one conversation, reset by `startCapture()`.
    public struct Statistics: Sendable, Hashable, Codable {
        /// Times Blau left the screen.
        public var backgroundEntries = 0
        /// Interruptions (calls, Siri, media-server loss).
        public var interruptions = 0
        /// Restarts the keeper made on returning to the foreground.
        public var foregroundResumes = 0
        /// Times audio stopped flowing while running.
        public var stallsDetected = 0
        /// Stalls that ended with audio flowing again.
        public var stallsRecovered = 0
        /// The longest the watchdog saw no audio while running, in seconds
        /// (resolution: the watchdog interval).
        public var longestSilentCaptureSeconds = 0.0
        /// Time with the conversation on, per phase, in seconds.
        public var foregroundSeconds = 0.0
        public var backgroundSeconds = 0.0
        public var lockedSeconds = 0.0
        /// Time with the conversation on but audio not `live`, in seconds.
        public var notLiveSeconds = 0.0

        public init() {}

        /// Total time with the conversation on.
        public var totalSeconds: Double { foregroundSeconds + backgroundSeconds + lockedSeconds }
    }

    /// The keeper's state at one moment.
    public struct Snapshot: Sendable, Hashable {
        public var status: Status
        public var phase: ExecutionPhase
        /// When the current conversation started.
        public var startedAt: Date?
        public var statistics: Statistics
    }

    // MARK: Dependencies

    public nonisolated let configuration: Configuration
    private let controller: AudioSessionController
    private let progress: any CaptureProgressSource
    /// Registered with the controller before the first start.
    private var pendingComponents: [any AudioGraphComponent]
    private let indicator: (any RecordingIndicator)?
    private let clock: any BlauClock
    private let signposter: Signposter
    private let logger = Log.audio

    // MARK: State

    public private(set) var status: Status = .inactive
    public private(set) var phase: ExecutionPhase = .foreground
    public private(set) var statistics = Statistics()
    private var startedAt: Date?
    private var wantsSession = false
    private var controllerState: AudioSessionState = .idle
    private var isDeviceLocked = false

    private enum StallState: Equatable {
        case none
        /// Rebuilding after a stall; `attempts` rebuilds so far, the latest
        /// at `since`.
        case recovering(attempts: Int, since: Duration)
        /// Gave up off screen; resume in the foreground.
        case gaveUp
    }

    private var stall: StallState = .none
    private var lastSampleCount: Int64 = 0
    private var lastProgressAt: Duration = .zero
    /// When time was last added to the statistics.
    private var accountedUntil: Duration = .zero

    private var watchdog: Task<Void, Never>?
    private let observation = KeeperObservation()
    private var lastIndicator: RecordingIndicatorState?
    private var subscribers: [UInt64: AsyncStream<Snapshot>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0

    /// - Parameters:
    ///   - controller: The audio session and engine.
    ///   - progress: Proof that capture is alive, normally the capture hub.
    ///   - components: Graph components (capture, playback) to register
    ///     with the controller before the first start.
    ///   - indicator: The lock-screen indicator, if any.
    ///   - configuration: Watchdog timings.
    ///   - clock: Time source for the watchdog and the statistics.
    ///   - signposter: Where `audio.captureStall` events go.
    public init(
        controller: AudioSessionController,
        progress: any CaptureProgressSource,
        components: [any AudioGraphComponent] = [],
        indicator: (any RecordingIndicator)? = nil,
        configuration: Configuration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.audio
    ) {
        self.controller = controller
        self.progress = progress
        self.pendingComponents = components
        self.indicator = indicator
        self.configuration = configuration
        self.clock = clock
        self.signposter = signposter
        observation.start(
            Task { [weak self] in
                for await snapshot in await controller.updates() {
                    await self?.controllerPublished(snapshot.state)
                }
            })
    }

    deinit {
        observation.cancel()
        watchdog?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: AudioService

    public var isCapturing: Bool { status == .live }

    /// Starts the conversation's audio, or resumes it if it is paused,
    /// failed or interrupted. Does nothing if it is already on.
    ///
    /// While `.interrupted` this is the user asking to take the session
    /// back: iOS doesn't guarantee an interruption-ended notification (for
    /// example when another app's non-mixable audio takes the session), so
    /// without it the conversation could stay interrupted forever. If the
    /// microphone really is still held (a call in progress), activation
    /// fails and the status becomes `.failed`, which is shown. The automatic
    /// resume on returning to the foreground stays passive and never does
    /// this.
    ///
    /// - Throws: `AudioSessionError` if the audio can't start (microphone
    ///   permission denied, a call holding the microphone...). A first start
    ///   that fails ends the conversation; a restart that fails leaves it
    ///   `.failed`, to be retried.
    public func startCapture() async throws {
        if wantsSession {
            switch status {
            case .paused, .failed:
                try await restart(reason: "startCapture()")
            case .interrupted:
                try await restart(reason: "startCapture() while interrupted")
            case .inactive, .starting, .live, .recovering:
                break
            }
            return
        }
        wantsSession = true
        statistics = Statistics()
        startedAt = clock.now
        accountedUntil = clock.uptime
        stall = .none
        logger.notice("Conversation audio starting (\(self.phase.rawValue, privacy: .public))")
        update(force: .starting)
        let components = pendingComponents
        pendingComponents = []
        for component in components {
            await controller.register(component)
        }
        let result = await controller.start()
        guard wantsSession else { return }  // stopCapture() ran meanwhile.
        if case .failed(let error) = result {
            await end(reason: "failed to start: \(error)")
            throw error
        }
        await syncWithController()
        resetProgress()
        startWatchdog()
    }

    /// Stops the conversation's audio and hides the indicator.
    public func stopCapture() async {
        guard wantsSession else { return }
        await end(reason: "stopped")
    }

    // MARK: Phases

    /// Off screen the conversation keeps running; back on screen, whatever
    /// couldn't resume off screen is restarted.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        switch transition.to {
        case .active: setPhase(.foreground)
        case .background: setPhase(isDeviceLocked ? .locked : .background)
        case .inactive: break
        }
        guard wantsSession else { return }

        if transition.isEnteringBackground {
            statistics.backgroundEntries += 1
            logger.notice("Conversation audio continues off screen (\(self.status, privacy: .public))")
            await syncWithController()
        } else if transition.isBecomingActive {
            await resumeIfNeeded()
        }
    }

    /// Whether the device is locked (protected data unavailable). Refines
    /// an off-screen phase for the statistics.
    public func setDeviceLocked(_ locked: Bool) {
        isDeviceLocked = locked
        guard phase.isBackground else { return }
        setPhase(locked ? .locked : .background)
    }

    // MARK: Observing

    public var snapshot: Snapshot {
        Snapshot(status: status, phase: phase, startedAt: startedAt, statistics: currentStatistics())
    }

    /// A stream that starts with the current snapshot and yields every
    /// change of status or phase.
    public func updates() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    // MARK: Watchdog

    /// One watchdog check. The watchdog task calls it every
    /// `watchdogInterval`; tests call it directly.
    func checkCapture() async {
        guard wantsSession else { return }
        let now = clock.uptime
        let count = progress.capturedSampleCount

        // Interruptions that ended without `.shouldResume` don't publish a
        // new controller state; pick them up here.
        if controllerState == .interrupted, !awaitingManualResume, await controller.isAwaitingManualResume {
            logger.notice("The interruption ended without .shouldResume; resuming when Blau is in use")
            await syncWithController()
        }

        guard controllerState == .running, stall != .gaveUp else {
            resetProgress()
            return
        }
        if count != lastSampleCount {
            lastSampleCount = count
            lastProgressAt = now
            if case .recovering(let attempts, _) = stall {
                stall = .none
                statistics.stallsRecovered += 1
                logger.notice("Audio is flowing again after \(attempts, privacy: .public) rebuild(s)")
                update(force: nil)
            }
            return
        }

        let silent = now - lastProgressAt
        statistics.longestSilentCaptureSeconds = max(statistics.longestSilentCaptureSeconds, silent.timeInterval)
        switch stall {
        case .none where silent >= configuration.stallTimeout:
            statistics.stallsDetected += 1
            logger.fault(
                """
                No audio captured for \(silent.timeInterval, privacy: .public) s while running \
                (\(self.phase.rawValue, privacy: .public)); recovering
                """
            )
            await recover(attempt: 1)
        case .recovering(let attempts, let since) where now - since >= configuration.stallTimeout:
            if attempts < configuration.maximumStallRecoveries {
                await recover(attempt: attempts + 1)
            } else if phase.isBackground {
                logger.fault(
                    "Audio still stalled after \(attempts, privacy: .public) rebuild(s); resuming when Blau is opened")
                stall = .gaveUp
                update(force: nil)
            } else {
                try? await restart(reason: "audio still stalled after \(attempts) rebuild(s)")
            }
        case .none, .recovering, .gaveUp:
            break
        }
    }

    private func recover(attempt: Int) async {
        if await controller.recoverFromStall() {
            stall = .recovering(attempts: attempt, since: clock.uptime)
        } else {
            stall = .none
        }
        update(force: nil)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let interval = configuration.watchdogInterval
        let clock = clock
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                await self?.checkCapture()
            }
        }
    }

    private func resetProgress() {
        lastSampleCount = progress.capturedSampleCount
        lastProgressAt = clock.uptime
    }

    // MARK: Transitions

    /// The controller published `state`. Updates arrive in order but can
    /// lag behind calls this actor made itself (`start()` returning before
    /// its own updates are delivered), so the status always follows the
    /// controller's current state; the published one only counts
    /// interruptions.
    private func controllerPublished(_ state: AudioSessionState) async {
        if wantsSession, state == .interrupted, lastPublishedState != .interrupted {
            statistics.interruptions += 1
        }
        lastPublishedState = state
        await syncWithController()
    }

    private var lastPublishedState: AudioSessionState = .idle

    /// Reads the controller's state and flags and updates the status.
    private func syncWithController() async {
        let state = await controller.state
        awaitingManualResume = await controller.isAwaitingManualResume
        let previous = controllerState
        controllerState = state
        if state != .running {
            stall = .none
        } else if previous != .running {
            resetProgress()
        }
        update(force: nil)
    }

    private func resumeIfNeeded() async {
        await syncWithController()
        switch status {
        case .paused, .failed:
            statistics.foregroundResumes += 1
            try? await restart(reason: "returned to the foreground")
        case .inactive, .starting, .live, .recovering, .interrupted:
            break
        }
    }

    /// Stops and starts the controller from scratch. Only allowed on
    /// screen.
    private func restart(reason: String) async throws {
        logger.notice("Restarting conversation audio (\(reason, privacy: .public))")
        stall = .none
        await controller.stop()
        update(force: .starting)
        let result = await controller.start()
        guard wantsSession else { return }
        await syncWithController()
        resetProgress()
        if case .failed(let error) = result {
            throw error
        }
    }

    private func end(reason: String) async {
        accountTime()
        wantsSession = false
        watchdog?.cancel()
        watchdog = nil
        stall = .none
        await controller.stop()
        let totals = statistics
        logger.notice(
            """
            Conversation audio \(reason, privacy: .public) after \(totals.totalSeconds, privacy: .public) s \
            (background \(totals.backgroundSeconds, privacy: .public) s, locked \(totals.lockedSeconds, privacy: .public) s, \
            not live \(totals.notLiveSeconds, privacy: .public) s, \(totals.stallsDetected, privacy: .public) stall(s), \
            \(totals.interruptions, privacy: .public) interruption(s))
            """
        )
        update(force: .inactive)
        await waitForIndicator()
    }

    // MARK: Status

    /// The status the current facts call for.
    private func derivedStatus() -> Status {
        guard wantsSession else { return .inactive }
        switch controllerState {
        case .idle, .starting:
            return .starting
        case .running:
            switch stall {
            case .none: return .live
            case .recovering: return .recovering
            case .gaveUp: return .paused
            }
        case .interrupted:
            return awaitingManualResume ? .paused : .interrupted
        case .failed(let error):
            return phase.isBackground ? .paused : .failed(error)
        }
    }

    /// The controller's `isAwaitingManualResume`, as of the last sync.
    private var awaitingManualResume = false

    /// Sets `status` (to `forced`, or the derived status), accounts time,
    /// publishes, and queues an indicator update.
    private func update(force forced: Status?) {
        let next = forced ?? derivedStatus()
        guard next != status else { return }
        accountTime()
        logger.notice("Conversation audio \(self.status, privacy: .public) -> \(next, privacy: .public)")
        status = next
        publish()
        scheduleIndicatorUpdate()
    }

    /// Indicator updates run one after another, each showing the status
    /// current when it runs, so the indicator never ends on a stale state
    /// and calls never overlap.
    private var indicatorTask: Task<Void, Never>?

    private func scheduleIndicatorUpdate() {
        guard indicator != nil else { return }
        let previous = indicatorTask
        indicatorTask = Task { [weak self] in
            await previous?.value
            await self?.updateIndicator()
        }
    }

    private func updateIndicator() async {
        guard let indicator else { return }
        guard wantsSession, let indicatorStatus = status.indicatorStatus, let startedAt else {
            if lastIndicator != nil {
                lastIndicator = nil
                await indicator.hide()
            }
            return
        }
        let state = RecordingIndicatorState(status: indicatorStatus, startedAt: startedAt)
        guard state != lastIndicator else { return }
        lastIndicator = state
        await indicator.show(state)
    }

    private func setPhase(_ newPhase: ExecutionPhase) {
        guard newPhase != phase else { return }
        accountTime()
        phase = newPhase
        if wantsSession {
            logger.notice(
                "Conversation audio phase \(newPhase.rawValue, privacy: .public) (\(self.status, privacy: .public))")
        }
        update(force: nil)
        publish()
    }

    /// Adds the time since the last call to the current phase (and to
    /// `notLiveSeconds` when not live).
    private func accountTime() {
        let now = clock.uptime
        defer { accountedUntil = now }
        guard wantsSession else { return }
        let seconds = (now - accountedUntil).timeInterval
        guard seconds > 0 else { return }
        switch phase {
        case .foreground: statistics.foregroundSeconds += seconds
        case .background: statistics.backgroundSeconds += seconds
        case .locked: statistics.lockedSeconds += seconds
        }
        if status != .live {
            statistics.notLiveSeconds += seconds
        }
    }

    private func currentStatistics() -> Statistics {
        guard wantsSession else { return statistics }
        var copy = statistics
        let seconds = (clock.uptime - accountedUntil).timeInterval
        if seconds > 0 {
            switch phase {
            case .foreground: copy.foregroundSeconds += seconds
            case .background: copy.backgroundSeconds += seconds
            case .locked: copy.lockedSeconds += seconds
            }
            if status != .live { copy.notLiveSeconds += seconds }
        }
        return copy
    }

    private func publish() {
        guard !subscribers.isEmpty else { return }
        let current = snapshot
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    private func removeSubscriber(_ id: UInt64) {
        subscribers[id] = nil
    }

    /// Waits until the indicator shows the current status.
    func waitForIndicator() async {
        while let task = indicatorTask {
            await task.value
            if indicatorTask == task { return }
        }
    }
}

/// The controller-observation task started by `AudioSessionKeeper.init`,
/// held outside the actor because a synchronous actor initializer can't
/// store a task that captures `self`.
private final class KeeperObservation: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func start(_ task: Task<Void, Never>) {
        self.task.withLock { $0 = task }
    }

    func cancel() {
        task.withLock { $0?.cancel() }
    }
}
