import BlauCore
import Synchronization
import os

/// Decides how much work the conversation pipeline may do (#75): watches
/// the thermal state, Low Power Mode and the battery, and publishes a
/// `PerformanceLevel` that every subsystem adapts to.
///
/// ```swift
/// let performance = PerformancePolicy()               // the device's readings
/// performance.start()
///
/// // Synchronous reads on hot paths:
/// PerformanceASRChunkSizePolicy(performance)          // 320 ms → 1280 ms chunks
/// SecondPassTranscriber(..., performance: performance) // off below normal
/// TopicLabelingService.standard(..., performance: performance)
///
/// // Changes, for the UI and for work that waits:
/// for await snapshot in performance.updates() { ... }
/// ```
///
/// The decision logic is `PerformanceLevelTracker` (thresholds in
/// `PerformancePolicyConfiguration`): a worse level applies at once, a
/// better one after `recoveryDelay`, one level at a time. The policy runs a
/// timer for that delay, so recovery happens even when no notification
/// arrives.
///
/// Level changes are logged under `Log.performance` (category `perf`) with
/// their reasons. Each stretch below `normal` is a `perf.degraded` signpost
/// interval on `Signposts.performance` whose end message is the worst level
/// reached, and every change is a `perf.levelChange` event, so Instruments
/// shows when and for how long the pipeline was degraded next to the
/// Thermal State track.
public final class PerformancePolicy: PerformanceLevelProviding, Sendable {
    public let configuration: PerformancePolicyConfiguration

    private let source: any DeviceConditionsSource
    private let clock: any BlauClock
    private let signposter: Signposter
    private let state: Mutex<State>

    private struct State {
        var tracker: PerformanceLevelTracker
        var recorder: PerformanceStatisticsRecorder
        var observing: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var timerDeadline: Duration?
        /// Open while the level is below `normal`.
        var degraded: SignpostInterval?
        var worstWhileDegraded: PerformanceLevel = .normal
        var nextSubscriberID: UInt64 = 0
        var snapshotSubscribers: [UInt64: AsyncStream<PerformanceSnapshot>.Continuation] = [:]
        var levelSubscribers: [UInt64: AsyncStream<PerformanceLevel>.Continuation] = [:]
    }

    /// - Parameters:
    ///   - source: The readings. Defaults to the device's own.
    ///   - configuration: Thresholds and the recovery delay.
    ///   - clock: Times the recovery delay and the statistics; tests pass a
    ///     `ManualClock`.
    ///   - signposter: Where `perf.degraded` and `perf.levelChange` go.
    public init(
        source: any DeviceConditionsSource = SystemDeviceConditionsSource(),
        configuration: PerformancePolicyConfiguration = .standard,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.performance
    ) {
        self.source = source
        self.configuration = configuration
        self.clock = clock
        self.signposter = signposter
        let start = clock.uptime
        var recorder = PerformanceStatisticsRecorder(start: start, hotThermalState: configuration.reducedThermalState)
        recorder.record(PerformanceSnapshot(), at: start)
        state = Mutex(State(tracker: PerformanceLevelTracker(configuration: configuration), recorder: recorder))
    }

    deinit {
        state.withLock { state in
            state.observing?.cancel()
            state.timer?.cancel()
            state.degraded?.end(message: state.worstWhileDegraded.rawValue)
            for continuation in state.snapshotSubscribers.values { continuation.finish() }
            for continuation in state.levelSubscribers.values { continuation.finish() }
        }
    }

    // MARK: Lifecycle

    /// Starts following `source`. Calling it again does nothing.
    public func start() {
        state.withLock { state in
            guard state.observing == nil else { return }
            let source = source
            state.observing = Task { [weak self] in
                for await conditions in source.conditions() {
                    guard let self else { return }
                    self.update(conditions)
                }
            }
        }
        Log.performance.notice("Performance policy started")
    }

    /// Stops following `source`. The level stays where it is.
    public func stop() {
        state.withLock { state in
            state.observing?.cancel()
            state.observing = nil
            state.timer?.cancel()
            state.timer = nil
            state.timerDeadline = nil
        }
    }

    // MARK: Reading

    public var performanceLevel: PerformanceLevel { state.withLock { $0.tracker.level } }

    /// The level, why, and the latest readings.
    public var snapshot: PerformanceSnapshot { state.withLock { Self.snapshot(of: $0.tracker) } }

    /// Time at each level and thermal state since the policy was created.
    public var statistics: PerformanceStatistics {
        let now = clock.uptime
        return state.withLock { $0.recorder.statistics(at: now) }
    }

    /// The current snapshot, then one after every change of the level, its
    /// reasons or the readings. A slow consumer only sees the latest.
    public func updates() -> AsyncStream<PerformanceSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PerformanceSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.snapshotSubscribers[id] = continuation
            continuation.yield(Self.snapshot(of: state.tracker))
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.snapshotSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func performanceLevels() -> AsyncStream<PerformanceLevel> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PerformanceLevel.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.levelSubscribers[id] = continuation
            continuation.yield(state.tracker.level)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.levelSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Changing

    /// Applies new readings. `start()` calls it for every reading from the
    /// source; tests call it directly.
    public func update(_ conditions: DeviceConditions) {
        apply { tracker, now in tracker.update(conditions, at: now) }
    }

    /// Holds the level at `level` whatever the readings say, or (with
    /// `nil`) goes back to the readings at once. For the debug menu and UI
    /// tests.
    public func setOverride(_ level: PerformanceLevel?) {
        apply { tracker, now in tracker.setOverride(level, at: now) }
    }

    /// Re-evaluates the current readings, applying a recovery whose delay
    /// has passed. The recovery timer calls it.
    public func reevaluate() {
        apply { tracker, now in tracker.evaluate(at: now) }
    }

    private struct Change {
        var from: PerformanceLevel
        var to: PerformanceLevel
        var snapshot: PerformanceSnapshot
    }

    /// Applies one change and delivers it, all under the lock.
    ///
    /// `update` (the observation task), `reevaluate` (the recovery timer)
    /// and `setOverride` (the main actor) can run at the same time, so the
    /// clock is read and the subscribers are told inside the same critical
    /// section that applies the change. Otherwise two changes applied as A
    /// then B could reach a `bufferingNewest(1)` stream as B then A, leaving
    /// it on a stale level until the next change, and the tracker could get
    /// an older timestamp than the change before it. `yield` neither blocks
    /// nor runs `onTermination`, so the lock is never re-entered.
    private func apply(_ body: (inout PerformanceLevelTracker, Duration) -> Bool) {
        let change = state.withLock { state -> Change in
            let now = clock.uptime
            let before = Self.snapshot(of: state.tracker)
            _ = body(&state.tracker, now)
            let after = Self.snapshot(of: state.tracker)
            state.recorder.record(after, at: now)
            scheduleRecovery(&state)
            updateSignposts(&state, from: before.level, to: after.level)
            if before != after {
                for subscriber in state.snapshotSubscribers.values { subscriber.yield(after) }
            }
            if before.level != after.level {
                for subscriber in state.levelSubscribers.values { subscriber.yield(after.level) }
            }
            return Change(from: before.level, to: after.level, snapshot: after)
        }
        if change.from != change.to {
            let reasons = change.snapshot.reasons.map(\.description).joined(separator: ", ")
            let conditions = change.snapshot.conditions
            Log.performance.notice(
                """
                Performance level \(change.from.rawValue, privacy: .public) -> \(change.to.rawValue, privacy: .public) \
                (\(reasons.isEmpty ? "conditions allow it" : reasons, privacy: .public); thermal \
                \(conditions.thermalState.rawValue, privacy: .public), Low Power Mode \
                \(conditions.isLowPowerModeEnabled, privacy: .public), battery \
                \(conditions.battery.percent.map { "\($0)%" } ?? "unknown", privacy: .public) \
                \(conditions.battery.state.rawValue, privacy: .public))
                """
            )
        }
    }

    /// Keeps one timer running for the tracker's recovery deadline. It
    /// sleeps until the deadline itself, so a timer task that starts late
    /// still fires on time.
    private func scheduleRecovery(_ state: inout State) {
        let deadline = state.tracker.recoveryDeadline
        guard deadline != state.timerDeadline else { return }
        state.timer?.cancel()
        state.timer = nil
        state.timerDeadline = deadline
        guard let deadline else { return }
        let clock = clock
        state.timer = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.recoveryTimerFired(deadline: deadline)
        }
    }

    private func recoveryTimerFired(deadline: Duration) {
        let isCurrent = state.withLock { state in
            guard state.timerDeadline == deadline else { return false }
            // Fired: a new timer may be needed for the next step.
            state.timer = nil
            state.timerDeadline = nil
            return true
        }
        if isCurrent { reevaluate() }
    }

    private func updateSignposts(_ state: inout State, from: PerformanceLevel, to: PerformanceLevel) {
        guard from != to else { return }
        signposter.event("perf.levelChange")
        if to.isDegraded {
            if state.degraded == nil {
                state.degraded = signposter.beginInterval("perf.degraded")
                state.worstWhileDegraded = to
            }
            state.worstWhileDegraded = max(state.worstWhileDegraded, to)
        } else {
            state.degraded?.end(message: state.worstWhileDegraded.rawValue)
            state.degraded = nil
            state.worstWhileDegraded = .normal
        }
    }

    private static func snapshot(of tracker: PerformanceLevelTracker) -> PerformanceSnapshot {
        PerformanceSnapshot(
            level: tracker.level,
            reasons: tracker.reasons,
            conditions: tracker.conditions,
            override: tracker.override,
            isRecovering: tracker.isRecovering
        )
    }
}
