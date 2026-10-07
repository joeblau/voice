import BlauCore
import Foundation
import Synchronization
import Testing

@Suite("ManualClock")
struct ManualClockTests {
    @Test func startsAtTheGivenTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualClock(now: start, uptime: .seconds(10))
        #expect(clock.now == start)
        #expect(clock.uptime == .seconds(10))
        #expect(clock.sleeperCount == 0)
    }

    @Test func advanceMovesWallAndMonotonicTime() {
        let clock = ManualClock()
        let start = clock.now
        clock.advance(by: .milliseconds(1_500))
        #expect(clock.uptime == .milliseconds(1_500))
        #expect(clock.now.timeIntervalSince(start) == 1.5)
    }

    @Test func sleeperWakesOnlyOnceItsDeadlineIsReached() async throws {
        let clock = ManualClock()
        let woke = Mutex(false)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(1))
            woke.withLock { $0 = true }
        }

        await clock.waitForSleepers(count: 1)
        clock.advance(by: .milliseconds(999))
        // Give a wrongly woken task every chance to run.
        for _ in 0..<100 { await Task.yield() }
        #expect(!woke.withLock { $0 })
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .milliseconds(1))
        try await sleeper.value
        #expect(woke.withLock { $0 })
        #expect(clock.sleeperCount == 0)
    }

    @Test func sleepersWakeInDeadlineOrder() async throws {
        let clock = ManualClock()
        let order = Mutex<[Int]>([])
        let tasks = [3, 1, 2].map { seconds in
            Task {
                try await clock.sleep(for: .seconds(seconds))
                order.withLock { $0.append(seconds) }
            }
        }

        await clock.waitForSleepers(count: 3)
        for _ in 1...3 {
            let woken = order.withLock { $0.count }
            clock.advance(by: .seconds(1))
            // Wait for the woken task to record itself before the next tick.
            while order.withLock({ $0.count }) == woken { await Task.yield() }
        }
        for task in tasks { try await task.value }
        #expect(order.withLock { $0 } == [1, 2, 3])
    }

    @Test func zeroOrNegativeSleepReturnsImmediately() async throws {
        let clock = ManualClock()
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .seconds(-1))
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellingASleeperThrowsCancellationError() async {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(60)) }
        await clock.waitForSleepers(count: 1)

        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func sleepingInAnAlreadyCancelledTaskThrows() async {
        let clock = ManualClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(1))
        }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func worksThroughTheProtocol() async throws {
        let manual = ManualClock()
        let clock: any BlauClock = manual
        let sleeper = Task { try await clock.sleep(for: .milliseconds(320)) }
        await manual.waitForSleepers()
        manual.advance(by: .milliseconds(320))
        try await sleeper.value
        #expect(clock.uptime == .milliseconds(320))
    }
}

@Suite("SystemClock")
struct SystemClockTests {
    @Test func uptimeIsMonotonicAndSharedAcrossInstances() {
        let first = SystemClock().uptime
        let second = SystemClock().uptime
        #expect(second >= first)
    }

    @Test func nowTracksTheWallClock() {
        let clock: some BlauClock = .system
        #expect(abs(clock.now.timeIntervalSinceNow) < 5)
    }

    @Test func sleepWaitsAtLeastTheRequestedDuration() async throws {
        let clock = SystemClock()
        let before = clock.uptime
        try await clock.sleep(for: .milliseconds(20))
        #expect(clock.uptime - before >= .milliseconds(20))
    }

    @Test func sleepIsCancellable() async {
        let sleeper = Task { try await SystemClock().sleep(for: .seconds(60)) }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }
}
