import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Testing

@testable import BlauMemory

/// A run that didn't finish (it failed, or was skipped) is retried after a
/// backoff, never on every launch or app activation, and nothing is
/// scheduled while learning is off.
@Suite("Profile consolidation: backoff after a run that didn't finish")
struct ProfileConsolidationBackoffTests {
    typealias Support = ExtractionTestSupport

    /// A week and a day after `t0`, so fixtures dated `t0` are recent.
    static let now = Support.t0.addingTimeInterval(8 * 86_400)

    private func makeConsolidator(
        _ fixture: ProfileFixture,
        generator: ScriptedTextGenerator,
        log: InMemoryProfileConsolidationLogStore = InMemoryProfileConsolidationLogStore(),
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        clock: ManualClock = ManualClock(now: ProfileConsolidationBackoffTests.now)
    ) -> ProfileConsolidator {
        ProfileConsolidator(
            generator: generator, store: fixture.store, topicSummaries: fixture.topics.conversations, log: log,
            isEnabled: isEnabled, clock: clock,
            signposter: Signposter(category: .memory, backend: RecordingSignpostBackend()), timeZone: Support.utc)
    }

    /// A bad key or a broken reply doesn't become a request on every
    /// launch: each failure pushes the next automatic run back (1 h, then
    /// 2 h...), and the background task is scheduled for then, not now.
    @Test func aFailedRunBacksOffInsteadOfRetryingAtOnce() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        let generator = ScriptedTextGenerator { _, index in
            guard index >= 2 else { throw FakeGeneratorError() }
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log, clock: clock)

        guard case .failed = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the first run to fail")
            return
        }
        let firstRetry = Self.now.addingTimeInterval(3_600)
        #expect(try await consolidator.decision() == .notDue(nextCheck: firstRetry))
        #expect(await consolidator.nextBackgroundCheck() == firstRetry)
        #expect(await consolidator.consolidateIfDue() == .notDue(nextCheck: firstRetry))
        #expect(generator.requests.count == 1)

        clock.advance(by: .seconds(3_600))
        guard case .failed = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the retry to fail")
            return
        }
        #expect(generator.requests.count == 2)
        let secondRetry = firstRetry.addingTimeInterval(2 * 3_600)
        #expect(try await consolidator.decision() == .notDue(nextCheck: secondRetry))
        #expect(log.load().failedAttempts == 2)

        clock.advance(by: .seconds(2 * 3_600))
        guard case .consolidated(let record) = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the third run to consolidate")
            return
        }
        #expect(record.reason == .firstRun)
        // Success clears the backoff.
        #expect(log.load().failedAttempts == 0)
        #expect(log.load().lastAttemptAt == nil)
        #expect(log.load().lastRunAt == secondRetry)
    }

    @Test func aSkippedRunBacksOffToo() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator(available: false) { _, _ in ProfileFixture.reply(profile: "Work: Acme.") }
        let consolidator = makeConsolidator(fixture, generator: generator)
        #expect(await consolidator.consolidateIfDue() == .skipped(.generatorUnavailable))
        #expect(try await consolidator.decision() == .notDue(nextCheck: Self.now.addingTimeInterval(3_600)))
    }

    /// Nothing to consolidate (memory changed between the decision and the
    /// run) starts the backoff as well.
    @Test func nothingToConsolidateBacksOff() async throws {
        let fixture = try ProfileFixture()
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log)
        #expect(await consolidator.consolidate(reason: .firstRun) == .skipped(.nothingToConsolidate))
        #expect(log.load().failedAttempts == 1)
        try fixture.addFacts([(nil, "works at", "Acme")])
        #expect(try await consolidator.decision() == .notDue(nextCheck: Self.now.addingTimeInterval(3_600)))
        #expect(generator.requests.isEmpty)
    }

    /// Topics older than the window consolidation reads give it nothing,
    /// so they don't make a first run due (it would only skip, forever).
    @Test func onlyOldTopicsAreNothingToConsolidate() async throws {
        let fixture = try ProfileFixture()
        _ = try await fixture.topics.recordTopic([(.user, "We hired Sam.", 5)])
        let now = Support.t0.addingTimeInterval(40 * 86_400)
        let clock = ManualClock(now: now)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let consolidator = makeConsolidator(fixture, generator: generator, clock: clock)
        let nextWeek = now.addingTimeInterval(7 * 86_400)
        #expect(try await consolidator.decision() == .notDue(nextCheck: nextWeek))
        #expect(await consolidator.consolidateIfDue() == .notDue(nextCheck: nextWeek))
        #expect(await consolidator.nextBackgroundCheck() == nextWeek)
        #expect(generator.requests.isEmpty)
    }

    @Test func nothingIsScheduledWhileLearningIsOff() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let log = InMemoryProfileConsolidationLogStore()
        let disabled = makeConsolidator(fixture, generator: generator, log: log, isEnabled: { false })
        #expect(await disabled.nextBackgroundCheck() == nil)
        #expect(await disabled.isLearningEnabled() == false)
        // Not an attempt: turning learning back on doesn't wait out a
        // backoff.
        #expect(await disabled.consolidate() == .skipped(.disabled))
        #expect(log.load().failedAttempts == 0)
        let enabled = makeConsolidator(fixture, generator: generator, log: log)
        #expect(await enabled.nextBackgroundCheck() == Self.now)
    }

    @Test func aLogWrittenBeforeTheBackoffStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "profile-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"lastRunAt":"2026-10-01T08:00:00Z","records":[]}"#.utf8).write(to: url)
        let log = FileProfileConsolidationLogStore(url: url).load()
        #expect(log.lastRunAt != nil)
        #expect(log.lastAttemptAt == nil)
        #expect(log.failedAttempts == 0)
        #expect(log.pendingRemovals == 0)

        var updated = log
        updated.recordFailedAttempt(at: Support.t0)
        updated.recordRemovals(2)
        FileProfileConsolidationLogStore(url: url).save(updated)
        #expect(FileProfileConsolidationLogStore(url: url).load() == updated)
    }
}
