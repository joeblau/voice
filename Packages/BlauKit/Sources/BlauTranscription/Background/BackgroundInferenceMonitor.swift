import BlauCore
import BlauTelemetry
import Synchronization
import os

/// Watches on-device inference while Blau is off screen and moves model
/// stages between the Neural Engine, the CPU and `SpeechTranscriber` as
/// `BackgroundInferencePolicy` decides (#26, docs/background.md).
///
/// ```swift
/// let monitor = BackgroundInferenceMonitor()
/// let silero = try await SileroSpeechProbabilityModel(modelDirectory: directory)
/// await monitor.register(silero, budget: .milliseconds(256))
/// let vad = VoiceActivitySegmenter(model: silero, inferenceObserver: monitor)
/// // The composition root adds the monitor to the lifecycle participants
/// // and tells it when the device locks.
/// ```
///
/// Stages report every inference through `record(_:)` (an
/// `InferenceObserver`), which only buffers it; a task drains the buffer
/// into the policy. Switches run one at a time: the monitor reconciles each
/// stage's desired backend with where it runs, re-reading the desired
/// backend after every switch, so a quick background → foreground bounce
/// ends with the stage where it should be.
///
/// Logs go to `Log.asr`; each switch is an `inference.backendSwitch`
/// interval on `Signposts.asr`.
public actor BackgroundInferenceMonitor: InferenceObserver, AppLifecycleParticipant {
    /// One switch the monitor performed, for the debug screen and reports.
    public struct SwitchRecord: Sendable, Hashable, Codable {
        public var uptimeSeconds: Double
        public var stage: String
        public var from: InferenceBackend
        public var to: InferenceBackend
        public var phase: ExecutionPhase
        public var reason: String
        /// `nil` when the switch succeeded.
        public var error: String?
    }

    /// The monitor's state at one moment.
    public struct Snapshot: Sendable, Hashable, Codable {
        public var phase: ExecutionPhase
        public var mitigation: BackgroundInferenceMitigation
        public var stages: [BackgroundInferencePolicy.StageStatus]
        /// The most recent switches, oldest first (at most
        /// `switchHistoryLimit`).
        public var switches: [SwitchRecord]
    }

    /// How many switch records the snapshot keeps.
    public static let switchHistoryLimit = 50

    private var policy: BackgroundInferencePolicy
    private var targets: [String: any InferenceBackendSwitchable] = [:]
    private var isDeviceLocked = false
    private var isReconciling = false
    private var switches: [SwitchRecord] = []
    /// Stages already logged as unable to keep up during this trip off
    /// screen.
    private var reportedExhausted: Set<String> = []

    private let clock: any BlauClock
    private let signposter: Signposter
    private let logger = Log.asr

    private let observations: AsyncStream<InferenceObservation>.Continuation
    private let intake = ObservationIntake()

    private var subscribers: [UInt64: AsyncStream<Snapshot>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0

    /// - Parameters:
    ///   - configuration: The mitigation and thresholds.
    ///   - clock: Timestamps switch records.
    ///   - signposter: Where `inference.backendSwitch` intervals go.
    public init(
        configuration: BackgroundInferencePolicy.Configuration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.asr
    ) {
        policy = BackgroundInferencePolicy(configuration: configuration)
        self.clock = clock
        self.signposter = signposter
        // Hundreds of inferences a minute at most; a backlog this deep only
        // builds if the actor is stuck, and then the newest matter.
        let (stream, continuation) = AsyncStream.makeStream(
            of: InferenceObservation.self, bufferingPolicy: .bufferingNewest(1_024))
        observations = continuation
        // A synchronous actor initializer can't store a task that captures
        // `self`, so it goes into a Sendable holder that already exists.
        let intake = intake
        intake.start(
            Task { [weak self] in
                for await observation in stream {
                    await self?.process(observation)
                    intake.markProcessed()
                }
            })
    }

    deinit {
        observations.finish()
        intake.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: Stages

    /// Starts managing `target`. `budget` is the time one inference may
    /// take (the audio it covers for a streaming stage). If Blau is off
    /// screen, the stage may switch at once.
    public func register(_ target: any InferenceBackendSwitchable, budget: Duration) async {
        let stage = BackgroundInferencePolicy.Stage(
            name: target.inferenceStage,
            ladder: target.supportedBackends,
            budget: budget,
            current: await target.inferenceBackend
        )
        targets[stage.name] = target
        if let change = policy.register(stage) {
            log(change)
        }
        logger.notice(
            """
            Inference stage \(stage.name, privacy: .public) registered on \
            \(stage.current.rawValue, privacy: .public) \
            (backends: \(stage.ladder.map(\.rawValue).joined(separator: ", "), privacy: .public))
            """
        )
        publish()
        await reconcile()
    }

    /// Stops managing the stage named `stage`.
    public func unregister(stage: String) {
        targets[stage] = nil
        policy.unregister(stage)
        publish()
    }

    // MARK: Observing inference

    /// Buffers `observation` for the policy. Never blocks.
    public nonisolated func record(_ observation: InferenceObservation) {
        intake.markRecorded()
        if case .dropped = observations.yield(observation) {
            // The oldest buffered observation made room and will never be
            // processed.
            intake.markProcessed()
        }
    }

    /// Feeds one observation to the policy and performs the switch it
    /// causes. `record(_:)` arrives here through the buffer; tests call it
    /// directly.
    func process(_ observation: InferenceObservation) async {
        let change = policy.observe(observation)
        if let change {
            log(change)
        } else if let status = policy.status(of: observation.stage), status.isExhausted,
            reportedExhausted.insert(observation.stage).inserted
        {
            logger.fault(
                """
                Inference stage \(observation.stage, privacy: .public) can't keep up off screen on \
                \(status.current.rawValue, privacy: .public) and has no backend left to try
                """
            )
        }
        if change != nil || observation.isFailure { publish() }
        await reconcile()
    }

    /// Waits until every observation recorded so far has been processed and
    /// any switch it caused has finished. For tests and reports.
    public func waitUntilIdle() async {
        while true {
            if intake.isDrained, !isReconciling { return }
            await Task.yield()
        }
    }

    // MARK: Phase

    /// Maps scene phases: `active` is the foreground, `background` is off
    /// screen (locked if `setDeviceLocked(true)` said so). `inactive` (the
    /// app switcher, Control Center, the moment before locking) changes
    /// nothing, so a pull-down of Control Center doesn't reload models.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        switch transition.to {
        case .active: await setPhase(.foreground)
        case .background: await setPhase(isDeviceLocked ? .locked : .background)
        case .inactive: break
        }
    }

    /// Whether the device is locked (protected data unavailable). Only
    /// refines an off-screen phase; the policy treats `background` and
    /// `locked` alike, but reports tell them apart.
    public func setDeviceLocked(_ locked: Bool) async {
        isDeviceLocked = locked
        guard policy.phase.isBackground else { return }
        await setPhase(locked ? .locked : .background)
    }

    /// Moves to `phase` and performs the switches it calls for.
    public func setPhase(_ phase: ExecutionPhase) async {
        guard phase != policy.phase else { return }
        let from = policy.phase
        let changes = policy.setPhase(phase)
        if !phase.isBackground { reportedExhausted.removeAll() }
        logger.notice(
            """
            Inference phase \(from.rawValue, privacy: .public) -> \(phase.rawValue, privacy: .public): \
            \(changes.count, privacy: .public) stage(s) to move
            """
        )
        for change in changes { log(change) }
        publish()
        await reconcile()
    }

    // MARK: Performance level

    /// Applies the thermal and power policy's level (#75): at `minimal`,
    /// stages that can run on Apple's `SpeechTranscriber` move there (see
    /// `BackgroundInferencePolicy`).
    public func setPerformanceLevel(_ level: PerformanceLevel) async {
        let from = policy.performanceLevel
        guard level != from else { return }
        let changes = policy.setPerformanceLevel(level)
        logger.notice(
            """
            Inference performance level \(from.rawValue, privacy: .public) -> \(level.rawValue, privacy: .public): \
            \(changes.count, privacy: .public) stage(s) to move
            """
        )
        for change in changes { log(change) }
        publish()
        await reconcile()
    }

    /// Follows `levels` (`PerformancePolicy.performanceLevels()`) until it
    /// ends or the calling task is cancelled.
    public func follow(_ levels: AsyncStream<PerformanceLevel>) async {
        for await level in levels {
            await setPerformanceLevel(level)
        }
    }

    /// The level last applied.
    public var performanceLevel: PerformanceLevel { policy.performanceLevel }

    // MARK: State

    public var snapshot: Snapshot {
        Snapshot(
            phase: policy.phase,
            mitigation: policy.configuration.mitigation,
            stages: policy.statuses,
            switches: switches
        )
    }

    /// A stream that starts with the current snapshot and yields each
    /// change of phase, switch and error.
    public func updates() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    // MARK: Switching

    /// Performs pending switches one at a time until every stage runs where
    /// the policy wants it. Re-entrant calls return at once: the running
    /// loop picks up whatever they changed.
    private func reconcile() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        while let (stage, backend) = policy.pendingSwitch() {
            guard let target = targets[stage], let from = policy.status(of: stage)?.current else {
                policy.unregister(stage)
                continue
            }
            let phase = policy.phase
            let reason = lastReason[stage] ?? ""
            let started = clock.uptime
            do {
                try await signposter.withInterval("inference.backendSwitch") {
                    try await target.switchInferenceBackend(to: backend)
                }
                policy.switchCompleted(stage: stage, to: backend)
                let elapsed = (clock.uptime - started).milliseconds
                logger.notice(
                    """
                    Inference stage \(stage, privacy: .public) now runs on \(backend.rawValue, privacy: .public) \
                    (was \(from.rawValue, privacy: .public), \(phase.rawValue, privacy: .public), \
                    switch took \(Int(elapsed.rounded()), privacy: .public) ms)
                    """
                )
                appendRecord(stage: stage, from: from, to: backend, phase: phase, reason: reason, error: nil)
            } catch {
                let description = String(describing: error)
                logger.error(
                    """
                    Moving inference stage \(stage, privacy: .public) to \(backend.rawValue, privacy: .public) \
                    failed: \(description, privacy: .public)
                    """
                )
                appendRecord(stage: stage, from: from, to: backend, phase: phase, reason: reason, error: description)
                if let change = policy.switchFailed(stage: stage, backend: backend, error: description) {
                    log(change)
                }
            }
            publish()
        }
    }

    /// The reason of the latest change per stage, for the switch records.
    private var lastReason: [String: String] = [:]

    private func log(_ change: BackgroundInferencePolicy.Change) {
        lastReason[change.stage] = change.reason.description
        logger.notice(
            """
            Inference stage \(change.stage, privacy: .public): \(change.from.rawValue, privacy: .public) -> \
            \(change.to.rawValue, privacy: .public) because it \(change.reason.description, privacy: .public)
            """
        )
    }

    private func appendRecord(
        stage: String, from: InferenceBackend, to: InferenceBackend, phase: ExecutionPhase, reason: String,
        error: String?
    ) {
        switches.append(
            SwitchRecord(
                uptimeSeconds: clock.uptime.timeInterval, stage: stage, from: from, to: to, phase: phase,
                reason: reason, error: error))
        if switches.count > Self.switchHistoryLimit {
            switches.removeFirst(switches.count - Self.switchHistoryLimit)
        }
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
}

/// Counts observations in and out of the buffer, and owns the task that
/// drains it.
private final class ObservationIntake: Sendable {
    private struct State {
        var recorded: UInt64 = 0
        var processed: UInt64 = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    var isDrained: Bool { state.withLock { $0.processed >= $0.recorded } }

    func start(_ task: Task<Void, Never>) {
        state.withLock { $0.task = task }
    }

    func markRecorded() {
        state.withLock { $0.recorded &+= 1 }
    }

    func markProcessed() {
        state.withLock { $0.processed &+= 1 }
    }

    func cancel() {
        state.withLock { $0.task?.cancel() }
    }
}

extension InferenceObservation {
    fileprivate var isFailure: Bool {
        if case .failed = outcome { true } else { false }
    }
}
