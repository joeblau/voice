import Foundation
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: when it runs")
struct ProfileConsolidationScheduleTests {
    let schedule = ProfileConsolidationSchedule(interval: 7 * 86_400, factThreshold: 20, minimumSpacing: 12 * 3_600)
    let now = ExtractionTestSupport.t0
    let day: TimeInterval = 86_400

    @Test func theFirstRunWaitsForMemory() {
        #expect(schedule.decision(lastConsolidatedAt: nil, changes: 0, hasMemory: true, now: now) == .due(.firstRun))
        #expect(
            schedule.decision(lastConsolidatedAt: nil, changes: 0, hasMemory: false, now: now)
                == .notDue(nextCheck: now.addingTimeInterval(7 * day)))
    }

    @Test func weeklyWhenSomethingChanged() {
        let lastWeek = now.addingTimeInterval(-7 * day)
        #expect(schedule.decision(lastConsolidatedAt: lastWeek, changes: 1, hasMemory: true, now: now) == .due(.weekly))
        #expect(
            schedule.decision(lastConsolidatedAt: lastWeek, changes: 0, hasMemory: true, now: now)
                == .notDue(nextCheck: now.addingTimeInterval(7 * day)))
    }

    @Test func enoughNewFactsBringItForward() {
        let twoDaysAgo = now.addingTimeInterval(-2 * day)
        #expect(
            schedule.decision(lastConsolidatedAt: twoDaysAgo, changes: 20, hasMemory: true, now: now) == .due(.newFacts)
        )
        #expect(
            schedule.decision(lastConsolidatedAt: twoDaysAgo, changes: 19, hasMemory: true, now: now)
                == .notDue(nextCheck: twoDaysAgo.addingTimeInterval(7 * day)))
    }

    @Test func neverTwiceWithinTheMinimumSpacing() {
        let hourAgo = now.addingTimeInterval(-3_600)
        #expect(
            schedule.decision(lastConsolidatedAt: hourAgo, changes: 500, hasMemory: true, now: now)
                == .notDue(nextCheck: hourAgo.addingTimeInterval(12 * 3_600)))
    }

    @Test func valuesAreClamped() {
        let odd = ProfileConsolidationSchedule(
            interval: -1, factThreshold: 0, minimumSpacing: -5, retryDelay: -1, maximumRetryDelay: -10)
        #expect(odd.interval == 0)
        #expect(odd.factThreshold == 1)
        #expect(odd.minimumSpacing == 0)
        #expect(odd.retryDelay == 0)
        #expect(odd.maximumRetryDelay == 0)
    }

    // MARK: Retrying a run that didn't finish

    @Test func theRetryDelayDoublesUpToADay() {
        #expect(schedule.retryDelay(afterFailedAttempts: 0) == 0)
        #expect(schedule.retryDelay(afterFailedAttempts: 1) == 3_600)
        #expect(schedule.retryDelay(afterFailedAttempts: 2) == 7_200)
        #expect(schedule.retryDelay(afterFailedAttempts: 5) == 16 * 3_600)
        #expect(schedule.retryDelay(afterFailedAttempts: 6) == day)
        #expect(schedule.retryDelay(afterFailedAttempts: 1_000) == day)
    }

    /// A first run that keeps failing is due again only after the backoff,
    /// not on every check.
    @Test func aRunThatDidNotFinishWaitsOutTheBackoff() {
        let failedAt = now.addingTimeInterval(-600)
        #expect(
            schedule.decision(
                lastConsolidatedAt: nil, changes: 0, hasMemory: true, now: now, lastAttemptAt: failedAt,
                failedAttempts: 1) == .notDue(nextCheck: failedAt.addingTimeInterval(3_600)))
        #expect(
            schedule.decision(
                lastConsolidatedAt: nil, changes: 0, hasMemory: true, now: now, lastAttemptAt: failedAt,
                failedAttempts: 3) == .notDue(nextCheck: failedAt.addingTimeInterval(4 * 3_600)))
        #expect(
            schedule.decision(
                lastConsolidatedAt: nil, changes: 0, hasMemory: true, now: failedAt.addingTimeInterval(3_600),
                lastAttemptAt: failedAt, failedAttempts: 1) == .due(.firstRun))
        // The same for a weekly run.
        let lastWeek = now.addingTimeInterval(-7 * day)
        #expect(
            schedule.decision(
                lastConsolidatedAt: lastWeek, changes: 1, hasMemory: true, now: now, lastAttemptAt: failedAt,
                failedAttempts: 1) == .notDue(nextCheck: failedAt.addingTimeInterval(3_600)))
    }

    @Test func theBackoffNeverBringsARunForward() {
        let twoDaysAgo = now.addingTimeInterval(-2 * day)
        #expect(
            schedule.decision(
                lastConsolidatedAt: twoDaysAgo, changes: 1, hasMemory: true, now: now,
                lastAttemptAt: now.addingTimeInterval(-7_200), failedAttempts: 1)
                == .notDue(nextCheck: twoDaysAgo.addingTimeInterval(7 * day)))
    }

    /// A fact the user removed makes a run due on its own, a day or an
    /// hour after the last, without the weekly wait or `factThreshold`;
    /// only `minimumSpacing` and the retry backoff hold it back.
    @Test func aRemovalIsDueOnItsOwn() {
        let thirteenHoursAgo = now.addingTimeInterval(-13 * 3_600)
        #expect(
            schedule.decision(lastConsolidatedAt: thirteenHoursAgo, changes: 1, removals: 1, hasMemory: true, now: now)
                == .due(.removedFacts))
        // Without the removal, the same change waits for the week.
        #expect(
            schedule.decision(lastConsolidatedAt: thirteenHoursAgo, changes: 1, hasMemory: true, now: now)
                == .notDue(nextCheck: thirteenHoursAgo.addingTimeInterval(7 * day)))
        // Within `minimumSpacing` it waits for it.
        let hourAgo = now.addingTimeInterval(-3_600)
        #expect(
            schedule.decision(lastConsolidatedAt: hourAgo, changes: 1, removals: 1, hasMemory: true, now: now)
                == .notDue(nextCheck: hourAgo.addingTimeInterval(12 * 3_600)))
        // After a run that didn't finish, it waits for the backoff.
        let failedAt = now.addingTimeInterval(-600)
        #expect(
            schedule.decision(
                lastConsolidatedAt: thirteenHoursAgo, changes: 1, removals: 1, hasMemory: true, now: now,
                lastAttemptAt: failedAt, failedAttempts: 1) == .notDue(nextCheck: failedAt.addingTimeInterval(3_600)))
        // Removing every fact still needs the summary rewritten.
        #expect(
            schedule.decision(lastConsolidatedAt: thirteenHoursAgo, changes: 1, removals: 1, hasMemory: false, now: now)
                == .due(.removedFacts))
    }
}
