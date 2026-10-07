import BlauCore
import BlauMemory
import BlauTelemetry
import Synchronization
import Testing

/// Memory indexing waits while the device is hot or short on power (#75).
@Suite("Indexing gate", .timeLimit(.minutes(1)))
struct IndexingGateTests {
    let clock = ManualClock()

    /// Starts `waitUntilAllowed()` on a task and records how it ended.
    final class Waiter: Sendable {
        private let result = Mutex<Result<Void, any Error>?>(nil)
        private let started = Mutex<Task<Void, Never>?>(nil)

        init(_ gate: IndexingGate) {
            let task = Task { [weak self] in
                let outcome: Result<Void, any Error>
                do {
                    try await gate.waitUntilAllowed()
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                self?.result.withLock { $0 = outcome }
            }
            started.withLock { $0 = task }
        }

        var task: Task<Void, Never> { started.withLock { $0! } }

        var isDone: Bool { result.withLock { $0 != nil } }

        var wasCancelled: Bool {
            result.withLock { result in
                if case .failure(let error) = result { error is CancellationError } else { false }
            }
        }
    }

    @Test(arguments: [(PerformanceLevel.normal, IndexingMode.immediate), (.reduced, .deferred), (.minimal, .suspended)])
    func levelsMapToModes(_ level: PerformanceLevel, mode: IndexingMode) {
        #expect(IndexingMode(level) == mode)
        #expect(IndexingGate(performance: FixedPerformanceLevel(level), clock: clock).mode == mode)
    }

    @Test func atNormalItReturnsAtOnce() async throws {
        let gate = IndexingGate(performance: FixedPerformanceLevel(.normal), clock: clock)
        try await gate.waitUntilAllowed()
        #expect(clock.sleeperCount == 0)
    }

    @Test func atReducedItWaitsOutTheDeferral() async throws {
        let gate = IndexingGate(performance: FixedPerformanceLevel(.reduced), deferral: .seconds(300), clock: clock)
        let waiter = Waiter(gate)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(299))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!waiter.isDone)
        clock.advance(by: .seconds(1))
        await waiter.task.value
        #expect(waiter.isDone && !waiter.wasCancelled)
    }

    @Test func atReducedItReturnsAsSoonAsTheLevelIsNormal() async throws {
        let level = ManualPerformanceLevel(.reduced)
        let gate = IndexingGate(performance: level, clock: clock)
        let waiter = Waiter(gate)
        await clock.waitForSleepers()
        level.set(.normal)
        await waiter.task.value
        #expect(waiter.isDone && !waiter.wasCancelled)
    }

    @Test func atMinimalItWaitsForTheLevelToImprove() async throws {
        let level = ManualPerformanceLevel(.minimal)
        let gate = IndexingGate(performance: level, deferral: .seconds(300), clock: clock)
        let waiter = Waiter(gate)
        // The waiter subscribes right after reading the start of its
        // deferral, so the clock only moves once that is fixed.
        try await waitUntil { level.subscriberCount == 1 }
        clock.advance(by: .seconds(3_600))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!waiter.isDone, "suspended: time alone doesn't release it")

        // Back to reduced after more than the deferral: no further wait.
        level.set(.reduced)
        await waiter.task.value
        #expect(waiter.isDone && !waiter.wasCancelled)
    }

    @Test func fromMinimalToReducedTheDeferralStillCountsFromTheCall() async throws {
        let level = ManualPerformanceLevel(.minimal)
        let gate = IndexingGate(performance: level, deferral: .seconds(300), clock: clock)
        let waiter = Waiter(gate)
        try await waitUntil { level.subscriberCount == 1 }
        clock.advance(by: .seconds(100))
        level.set(.reduced)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(199))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!waiter.isDone)
        clock.advance(by: .seconds(1))
        await waiter.task.value
        #expect(waiter.isDone)
    }

    @Test func cancellingTheWaitThrows() async throws {
        let gate = IndexingGate(performance: FixedPerformanceLevel(.minimal), clock: clock)
        let waiter = Waiter(gate)
        try await Task.sleep(for: .milliseconds(20))
        waiter.task.cancel()
        await waiter.task.value
        #expect(waiter.wasCancelled)
    }
}

/// Polls `condition` until it holds, failing after `timeout`.
private func waitUntil(
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
