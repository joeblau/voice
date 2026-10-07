import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

/// `PerformancePolicy`: following a conditions source, publishing changes,
/// the recovery timer, signposts and statistics (#75).
@Suite("Performance policy", .timeLimit(.minutes(1)))
struct PerformancePolicyTests {
    let clock = ManualClock()
    let source = ManualDeviceConditionsSource()
    let signposts = RecordingSignpostBackend()

    func makePolicy(recoveryDelay: Duration = .seconds(60)) -> PerformancePolicy {
        PerformancePolicy(
            source: source,
            configuration: PerformancePolicyConfiguration(recoveryDelay: recoveryDelay),
            clock: clock,
            signposter: Signposter(category: .performance, backend: signposts))
    }

    @Test func startsNormal() {
        let policy = makePolicy()
        #expect(policy.performanceLevel == .normal)
        #expect(policy.snapshot == PerformanceSnapshot())
    }

    @Test func followsTheSourceOnceStarted() async throws {
        let policy = makePolicy()
        source.send(DeviceConditions(thermalState: .serious))
        #expect(policy.performanceLevel == .normal, "not started yet")

        policy.start()
        try await waitUntil { policy.performanceLevel == .reduced }
        source.update { $0.thermalState = .critical }
        try await waitUntil { policy.performanceLevel == .minimal }
        #expect(policy.snapshot.reasons == [.thermal(.critical)])

        policy.stop()
        source.send(.nominal)
        try await Task.sleep(for: .milliseconds(20))
        #expect(policy.performanceLevel == .minimal, "stopped: the level stays")
    }

    @Test func startingTwiceObservesOnce() async throws {
        let policy = makePolicy()
        policy.start()
        policy.start()
        source.send(DeviceConditions(isLowPowerModeEnabled: true))
        try await waitUntil { policy.performanceLevel == .reduced }
        #expect(policy.statistics.levelChanges == 1)
    }

    @Test func publishesSnapshotsAndLevelChanges() async throws {
        let policy = makePolicy()
        let snapshots = Collector(policy.updates())
        let levels = Collector(policy.performanceLevels())
        try await waitUntil { snapshots.values.count == 1 && levels.values.count == 1 }

        policy.update(DeviceConditions(thermalState: .fair))
        try await waitUntil { snapshots.values.count == 2 }
        policy.update(DeviceConditions(thermalState: .serious))
        try await waitUntil { levels.values.count == 2 }
        policy.update(DeviceConditions(thermalState: .serious))  // no change at all

        #expect(levels.values == [.normal, .reduced])
        try await waitUntil { snapshots.values.count == 3 }
        #expect(snapshots.values.map(\.conditions.thermalState) == [.nominal, .fair, .serious])
        #expect(snapshots.values.last?.reasons == [.thermal(.serious)])
    }

    @Test func theRecoveryTimerRelaxesTheLevelWithoutANewReading() async throws {
        let policy = makePolicy()
        policy.update(DeviceConditions(thermalState: .critical))
        policy.update(DeviceConditions(thermalState: .nominal))
        #expect(policy.snapshot.isRecovering)

        await clock.waitForSleepers()
        clock.advance(by: .seconds(60))
        try await waitUntil { policy.performanceLevel == .reduced }

        // The next step gets its own timer.
        await clock.waitForSleepers()
        clock.advance(by: .seconds(59))
        try await Task.sleep(for: .milliseconds(20))
        #expect(policy.performanceLevel == .reduced)
        clock.advance(by: .seconds(1))
        try await waitUntil { policy.performanceLevel == .normal }
        #expect(!policy.snapshot.isRecovering)
    }

    @Test func aNewEscalationCancelsThePendingRecovery() async throws {
        let policy = makePolicy()
        policy.update(DeviceConditions(thermalState: .serious))
        policy.update(DeviceConditions(thermalState: .fair))
        await clock.waitForSleepers()
        policy.update(DeviceConditions(thermalState: .serious))
        try await waitUntil { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(20))
        #expect(policy.performanceLevel == .reduced)
    }

    @Test func overridesApplyAtOnce() {
        let policy = makePolicy()
        policy.update(DeviceConditions(thermalState: .serious))
        policy.setOverride(.minimal)
        #expect(policy.snapshot.level == .minimal)
        #expect(policy.snapshot.override == .minimal)
        #expect(policy.snapshot.reasons == [.override])
        policy.setOverride(nil)
        #expect(policy.performanceLevel == .reduced)
    }

    @Test func eachDegradedStretchIsASignpostInterval() {
        let policy = makePolicy(recoveryDelay: .zero)
        policy.update(DeviceConditions(thermalState: .serious))
        #expect(signposts.openIntervals == ["perf.degraded"])
        policy.update(DeviceConditions(thermalState: .critical))
        #expect(signposts.openIntervals == ["perf.degraded"], "one interval per stretch")
        policy.update(.nominal)
        policy.reevaluate()
        #expect(policy.performanceLevel == .normal)
        #expect(signposts.openIntervals.isEmpty)
        #expect(signposts.endMessages(of: "perf.degraded") == ["minimal"])
        #expect(signposts.events == ["perf.levelChange", "perf.levelChange", "perf.levelChange", "perf.levelChange"])
    }

    @Test func recordsStatisticsOnItsClock() {
        let policy = makePolicy()
        clock.advance(by: .seconds(30))
        policy.update(DeviceConditions(thermalState: .serious))
        clock.advance(by: .seconds(90))
        let statistics = policy.statistics
        #expect(statistics.seconds == 120)
        #expect(statistics.seconds(at: .normal) == 30)
        #expect(statistics.seconds(at: .reduced) == 90)
        #expect(statistics.seconds(at: .serious) == 90)
        #expect(statistics.worstLevel == .reduced)
        #expect(statistics.levelChanges == 1)
        #expect(statistics.secondsHotAtNormal == 0)
    }

    @Test func endsItsStreamsWhenReleased() async {
        var policy: PerformancePolicy? = makePolicy()
        let levels = policy!.performanceLevels()
        policy = nil
        var received: [PerformanceLevel] = []
        for await level in levels { received.append(level) }
        #expect(received == [.normal])
    }

    // MARK: Providers

    @Test func aFixedLevelYieldsOnceAndStaysOpen() async throws {
        let fixed = FixedPerformanceLevel(.reduced)
        #expect(fixed.performanceLevel == .reduced)
        let collector = Collector(fixed.performanceLevels())
        try await waitUntil { collector.values == [.reduced] }
        #expect(!collector.finished)
    }

    @Test func aManualLevelPublishesOnlyChanges() async throws {
        let manual = ManualPerformanceLevel()
        let collector = Collector(manual.performanceLevels())
        try await waitUntil { collector.values == [.normal] }
        manual.set(.normal)
        manual.set(.minimal)
        try await waitUntil { collector.values == [.normal, .minimal] }
        #expect(manual.subscriberCount == 1)
    }

    // MARK: System source

    /// The Mac reports its real thermal state and Low Power Mode, and no
    /// battery. Reads only; changes nothing.
    @Test func theSystemSourceReadsTheDevice() async throws {
        let stream = SystemDeviceConditionsSource().conditions()
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.thermalState == ThermalState(ProcessInfo.processInfo.thermalState))
        #expect(first.isLowPowerModeEnabled == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #if os(macOS)
            #expect(first.battery == .unknown)
        #endif
    }
}

/// Collects a stream's values on a task of its own.
final class Collector<Value: Sendable>: Sendable {
    private struct State {
        var values: [Value] = []
        var finished = false
    }

    private let state = Mutex(State())
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Value>) {
        let started = Task { [weak self] in
            for await value in stream {
                self?.state.withLock { $0.values.append(value) }
            }
            self?.state.withLock { $0.finished = true }
        }
        task.withLock { $0 = started }
    }

    deinit {
        task.withLock { $0?.cancel() }
    }

    var values: [Value] { state.withLock { $0.values } }
    var finished: Bool { state.withLock { $0.finished } }
}

/// Polls `condition` until it holds, failing after `timeout`.
func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}
