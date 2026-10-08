import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

/// A fact the user removes (deletes in Settings → Memory, or has Blau
/// forget with the `forget` tool) leaves the pinned facts at once and the
/// consolidated summary at the next run, which the removal makes due on
/// its own once `minimumSpacing` has passed.
@Suite("Profile consolidation: facts the user removes")
struct ProfileFactRemovalTests {
    typealias Support = ExtractionTestSupport

    /// A week and a day after `t0`, so fixtures dated `t0` are recent.
    static let now = Support.t0.addingTimeInterval(8 * 86_400)
    static let spacing = ProfileConsolidationSchedule.standard.minimumSpacing

    private func makeConsolidator(
        _ fixture: ProfileFixture,
        generator: ScriptedTextGenerator,
        log: InMemoryProfileConsolidationLogStore = InMemoryProfileConsolidationLogStore(),
        clock: ManualClock
    ) -> ProfileConsolidator {
        ProfileConsolidator(
            generator: generator, store: fixture.store, topicSummaries: fixture.topics.conversations, log: log,
            clock: clock, signposter: Signposter(category: .memory, backend: RecordingSignpostBackend()),
            timeZone: Support.utc)
    }

    /// The review's probe: consolidate, delete a fact, and the profile was
    /// never due again, so the deleted fact stayed pinned. Now the deletion
    /// makes it due once `minimumSpacing` has passed, and the run takes the
    /// fact out of the summary.
    @Test func aDeletedFactMakesTheProfileDueAndLeavesIt() async throws {
        let fixture = try ProfileFixture()
        let ids = try fixture.addFacts([(nil, "is", "pregnant"), (nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        let generator = ScriptedTextGenerator(replies: [
            ProfileFixture.reply(profile: "Background: The user is pregnant. Work: Acme."),
            ProfileFixture.reply(profile: "Work: Acme."),
        ])
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log, clock: clock)
        let pinned = PinnedMemoryProvider(store: fixture.store, clock: clock)
        let removals = ProfileFactRemovals(consolidator: consolidator, pinned: pinned)

        guard case .consolidated = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the first run to consolidate")
            return
        }
        #expect(await pinned.pinnedMemory().profile == "Background: The user is pregnant. Work: Acme.")

        // An hour later the user deletes the fact in Settings.
        clock.advance(by: .seconds(3_600))
        try await SwiftDataMemoryFactStore(modelContainer: fixture.container).deleteFact(ids[0])
        await removals.factsRemoved(count: 1)
        #expect(await consolidator.pendingRemovals() == 1)

        // It leaves the pinned facts at once (the cache was dropped)...
        let afterDelete = await pinned.pinnedMemory()
        #expect(afterDelete.facts.map(\.text) == ["User works at Acme"])
        // ...and the summary once `minimumSpacing` has passed.
        #expect(try await consolidator.decision() == .notDue(nextCheck: Self.now.addingTimeInterval(Self.spacing)))
        clock.advance(by: .seconds(Self.spacing - 3_600 + 1))
        #expect(try await consolidator.decision() == .due(.removedFacts))
        #expect(await consolidator.nextBackgroundCheck() == clock.now)

        guard case .consolidated(let record) = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the removal to consolidate")
            return
        }
        #expect(record.reason == .removedFacts)
        #expect(record.after == "Work: Acme.")
        let prompt = try #require(generator.requests.last?.prompt)
        #expect(prompt.contains("The user removed 1 fact from memory"))
        #expect(!prompt.contains("| pregnant"))
        // The removal is used up: nothing is due until something changes.
        #expect(log.load().pendingRemovals == 0)
        guard case .notDue = try await consolidator.decision() else {
            Issue.record("Expected nothing due after the removal's run")
            return
        }
        await pinned.invalidate()
        #expect(await pinned.pinnedMemory().profile == "Work: Acme.")
    }

    /// Deleting through `ProfileFactRemovals` drops the pinned memory
    /// cache, so the next session isn't told the deleted fact for up to
    /// `maximumAge`.
    @Test func aDeletionInvalidatesThePinnedCache() async throws {
        let fixture = try ProfileFixture()
        let ids = try fixture.addFacts([(nil, "is", "pregnant"), (nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        let pinned = PinnedMemoryProvider(store: fixture.store, maximumAge: .seconds(300), clock: clock)
        let consolidator = makeConsolidator(
            fixture, generator: ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "")]), clock: clock)
        #expect(await pinned.pinnedMemory().facts.count == 2)

        try await SwiftDataMemoryFactStore(modelContainer: fixture.container).deleteFact(ids[0])
        // Cached: without the removal, the deleted fact would still be pinned.
        #expect(await pinned.pinnedMemory().facts.count == 2)

        await ProfileFactRemovals(consolidator: consolidator, pinned: pinned).factsRemoved(count: 1)
        #expect(await pinned.pinnedMemory().facts.map(\.text) == ["User works at Acme"])
    }

    /// The `forget` tool (#68) invalidates rather than deletes; through
    /// `RemovalReportingMemoryToolBackend` it counts as a removal too, so a
    /// spoken "forget that" doesn't wait for the weekly run.
    @Test func theForgetToolReportsARemoval() async throws {
        let fixture = try ProfileFixture()
        let ids = try fixture.addFacts([(nil, "is", "pregnant"), (nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        try fixture.addBlock("Background: The user is pregnant.", at: Self.now.addingTimeInterval(-2 * 86_400))
        let consolidator = makeConsolidator(
            fixture, generator: ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")]),
            clock: clock)
        let pinned = PinnedMemoryProvider(store: fixture.store, maximumAge: .seconds(300), clock: clock)
        #expect(await pinned.pinnedMemory().facts.count == 2)
        // Two days after the last run, one change: not due by the weekly rule.
        guard case .notDue = try await consolidator.decision() else {
            Issue.record("Expected nothing due before the removal")
            return
        }

        let service = MemoryToolService(
            MemoryToolService.Context(container: fixture.container, index: nil), embedder: nil, clock: clock)
        let backend = RemovalReportingMemoryToolBackend(
            base: service, removals: ProfileFactRemovals(consolidator: consolidator, pinned: pinned))
        let forgotten = try #require(try await backend.forget(ids[0]))
        #expect(!forgotten.isCurrent)

        #expect(await consolidator.pendingRemovals() == 1)
        #expect(try await consolidator.decision() == .due(.removedFacts))
        #expect(await pinned.pinnedMemory().facts.map(\.text) == ["User works at Acme"])

        // A fact that doesn't exist removes nothing.
        #expect(try await backend.forget(UUID()) == nil)
        #expect(await consolidator.pendingRemovals() == 1)
    }

    /// A removal noted while a run is reading memory waits for the next run
    /// rather than being cleared by this one, which may have read the fact.
    @Test func aRemovalDuringARunWaitsForTheNext() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        let owner = ConsolidatorBox()
        let generator = ScriptedTextGenerator { _, _ in
            await owner.value?.noteRemovedFacts(count: 1)
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log, clock: clock)
        owner.value = consolidator

        guard case .consolidated = await consolidator.consolidate(reason: .firstRun) else {
            Issue.record("Expected a consolidation")
            return
        }
        #expect(log.load().pendingRemovals == 1)
        clock.advance(by: .seconds(Self.spacing))
        #expect(try await consolidator.decision() == .due(.removedFacts))
    }

    /// A run that doesn't finish keeps the removal for the retry, after the
    /// backoff.
    @Test func aFailedRunKeepsTheRemoval() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: Acme. Background: pregnant.", at: Self.now.addingTimeInterval(-86_400))
        let clock = ManualClock(now: Self.now)
        let generator = ScriptedTextGenerator { _, _ in throw FakeGeneratorError() }
        let consolidator = makeConsolidator(fixture, generator: generator, clock: clock)
        await consolidator.noteRemovedFacts(count: 1)

        guard case .failed = await consolidator.consolidateIfDue() else {
            Issue.record("Expected the run to fail")
            return
        }
        #expect(await consolidator.pendingRemovals() == 1)
        #expect(try await consolidator.decision() == .notDue(nextCheck: Self.now.addingTimeInterval(3_600)))
        clock.advance(by: .seconds(3_600))
        #expect(try await consolidator.decision() == .due(.removedFacts))
    }

    /// With no summary and nothing left in memory, nothing pins what was
    /// removed, so the removal doesn't keep a run due.
    @Test func aRemovalWithNothingPinnedIsDropped() async throws {
        let fixture = try ProfileFixture()
        let clock = ManualClock(now: Self.now)
        let log = InMemoryProfileConsolidationLogStore()
        var seeded = ProfileConsolidationLog(lastRunAt: Self.now.addingTimeInterval(-86_400))
        seeded.recordRemovals(1)
        log.save(seeded)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "")])
        let consolidator = makeConsolidator(fixture, generator: generator, log: log, clock: clock)
        #expect(try await consolidator.decision() == .due(.removedFacts))

        #expect(await consolidator.consolidateIfDue() == .skipped(.nothingToConsolidate))
        #expect(log.load().pendingRemovals == 0)
        #expect(generator.requests.isEmpty)
    }

    @Test func noRemovalIsNotedForNothing() async throws {
        let fixture = try ProfileFixture()
        let consolidator = makeConsolidator(
            fixture, generator: ScriptedTextGenerator(replies: [""]), clock: ManualClock(now: Self.now))
        await consolidator.noteRemovedFacts(count: 0)
        await consolidator.noteRemovedFacts(count: -3)
        #expect(await consolidator.pendingRemovals() == 0)
    }
}

/// The consolidator a scripted model calls back into.
private final class ConsolidatorBox: Sendable {
    private let state = Mutex<ProfileConsolidator?>(nil)

    var value: ProfileConsolidator? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
