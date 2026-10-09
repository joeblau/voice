import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: the sleep-time run")
struct ProfileConsolidatorTests {
    typealias Support = ExtractionTestSupport

    /// A week and a day after `t0`, so fixtures dated `t0` are recent.
    static let now = Support.t0.addingTimeInterval(8 * 86_400)

    private func makeConsolidator(
        _ fixture: ProfileFixture,
        generator: ScriptedTextGenerator,
        log: InMemoryProfileConsolidationLogStore = InMemoryProfileConsolidationLogStore(),
        notes: InMemoryProfileConsolidationNoteStore = InMemoryProfileConsolidationNoteStore(),
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        topicSummaries: Bool = true,
        clock: ManualClock = ManualClock(now: ProfileConsolidatorTests.now),
        signposts: RecordingSignpostBackend = RecordingSignpostBackend()
    ) -> ProfileConsolidator {
        ProfileConsolidator(
            generator: generator, store: fixture.store,
            topicSummaries: topicSummaries ? fixture.topics.conversations : nil, log: log, notes: notes,
            isEnabled: isEnabled, clock: clock, signposter: Signposter(category: .memory, backend: signposts),
            timeZone: Support.utc)
    }

    // MARK: Acceptance: the profile stays within the token budget

    /// A model that ignores the word limit can't push the profile over the
    /// budget: the summary is cut to what the user's own words leave, and
    /// the pinned profile (both together) stays within 1,500 tokens.
    @Test func theProfileStaysWithinTheBudgetWhateverTheModelReturns() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme"), ("Acme", "raised", "a seed round")])
        try fixture.addProfileDocument(title: "About me", body: ProfileFixture.prose(40, prefix: "Me"))
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: ProfileFixture.prose(600))])
        let consolidator = makeConsolidator(fixture, generator: generator)

        let outcome = await consolidator.consolidate(reason: .manual)

        guard case .consolidated(let record) = outcome else {
            Issue.record("Expected a consolidation, got \(outcome)")
            return
        }
        let block = try #require(try fixture.blocks().first)
        #expect(block.text == record.after)
        #expect(!block.isOverBudget)
        let pinned = await PinnedMemoryProvider(store: fixture.store).pinnedMemory()
        let profile = try #require(pinned.profile)
        #expect(ProfileComposer.tokens(profile) <= ProfileBlock.tokenBudget)
        // The summary filled the room the user's words left, and was cut at
        // a sentence end.
        #expect(profile.hasSuffix(block.text))
        #expect(block.text.hasSuffix("startup."))
        #expect(ProfileComposer.tokens(profile) > ProfileBlock.tokenBudget - 40)
        // The model was told the room it has, as words.
        let request = try #require(generator.requests.first)
        let user = ProfileComposer.standard.userSection(try await fixture.store.userProfileDocuments())
        let words = ProfileComposer.wordBudget(forBytes: ProfileComposer.standard.summaryByteBudget(after: user))
        #expect(request.prompt.contains("Word limit for the profile: \(words)"))
    }

    // MARK: Acceptance: the diff view's record

    @Test func eachChangeIsLoggedWithItsDiff() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: The user works at Stripe.", at: Support.t0)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: The user works at Acme.")])
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log)

        _ = await consolidator.consolidate(reason: .weekly)

        let record = try #require(log.load().records.first)
        #expect(record.reason == .weekly)
        #expect(record.date == Self.now)
        #expect(record.before == "Work: The user works at Stripe.")
        #expect(record.after == "Work: The user works at Acme.")
        #expect(record.diff.segments.contains(.init(.removed, "Stripe.")))
        #expect(record.diff.segments.contains(.init(.added, "Acme.")))
        #expect(record.factCount == 1)
        #expect(log.load().lastRunAt == Self.now)
    }

    @Test func anUnchangedProfileIsNotLoggedAsAChange() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: The user works at Acme.", at: Support.t0)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: The user works at Acme.")])
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log)

        #expect(await consolidator.consolidate() == .unchanged)
        #expect(log.load().records.isEmpty)
        #expect(log.load().lastRunAt == Self.now)
        #expect(try fixture.blocks().first?.updatedAt == Support.t0)
    }

    // MARK: Inputs

    @Test func showsCurrentFactsUserFactsFirstAndNotInvalidatedOnes() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Stripe")], invalidatedAt: Support.t0.addingTimeInterval(60))
        try fixture.addFacts([("Acme", "raised", "a seed round")])
        try fixture.addFacts([(nil, "works at", "Acme")], origin: .user)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        _ = await makeConsolidator(fixture, generator: generator).consolidate()

        let prompt = try #require(generator.requests.first?.prompt)
        #expect(!prompt.contains("Stripe"))
        let user = try #require(prompt.range(of: "- User | works at | Acme"))
        let acme = try #require(prompt.range(of: "- Acme (organization) | raised"))
        #expect(user.lowerBound < acme.lowerBound)
        #expect(prompt.contains("[told by the user]"))
    }

    @Test func extractionNotesAreShownOnceThenUsedUp() async throws {
        let fixture = try ProfileFixture()
        let notes = InMemoryProfileConsolidationNoteStore()
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Goals: The user is raising.")])
        let consolidator = makeConsolidator(fixture, generator: generator, notes: notes)
        await consolidator.record(FactExtractionOutcome(topicID: UUID(), summary: "The user  is raising a seed round."))
        // An extraction that learned nothing about the user leaves no note.
        await consolidator.record(FactExtractionOutcome(topicID: UUID()))
        #expect(notes.load().count == 1)

        _ = await consolidator.consolidate()

        #expect(generator.requests.first?.prompt.contains(": The user is raising a seed round.") == true)
        #expect(notes.load().isEmpty)
    }

    /// A topic extracted again during a run (after re-segmentation)
    /// replaces its note; the newer note waits for the next run.
    @Test func aNoteReplacedDuringARunWaits() async throws {
        let fixture = try ProfileFixture()
        let notes = InMemoryProfileConsolidationNoteStore()
        let topic = UUID()
        let consolidatorBox = Mutex<ProfileConsolidator?>(nil)
        let generator = ScriptedTextGenerator { _, _ in
            let consolidator = consolidatorBox.withLock { $0 }
            await consolidator?.record(FactExtractionOutcome(topicID: topic, summary: "The user closed the round."))
            return ProfileFixture.reply(profile: "Goals: The user is raising.")
        }
        let consolidator = makeConsolidator(fixture, generator: generator, notes: notes)
        consolidatorBox.withLock { $0 = consolidator }
        await consolidator.record(FactExtractionOutcome(topicID: topic, summary: "The user is raising a seed round."))

        _ = await consolidator.consolidate()

        #expect(notes.load().map(\.summary) == ["The user closed the round."])
    }

    @Test func nothingToConsolidateSendsNothing() async throws {
        let fixture = try ProfileFixture()
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "x")])
        #expect(await makeConsolidator(fixture, generator: generator).consolidate() == .skipped(.nothingToConsolidate))
        #expect(generator.requests.isEmpty)
    }

    // MARK: Topic summaries

    /// Only topics of ended conversations get new summaries, and only while
    /// their summary is still what the model was shown.
    @Test func rewritesRecentTopicSummariesItIsAllowedTo() async throws {
        let fixture = try ProfileFixture()
        let ended = try await fixture.topics.recordTopic([(.user, "Dana and I are raising.", 5)], startingAt: 86_400)
        // An open conversation: its topic is closed but may still change.
        let open = ConversationID()
        let openStart = Support.t0.addingTimeInterval(2 * 86_400)
        try await fixture.topics.conversations.startConversation(id: open, at: openStart)
        let openTopic = try await fixture.topics.conversations.openTopic(at: openStart, title: "Hiring")
        try await fixture.topics.conversations.closeTopic(
            openTopic, title: "Hiring", summary: "They talk hiring.", at: openStart.addingTimeInterval(60))
        try await fixture.topics.conversations.flush()

        let generator = ScriptedTextGenerator(replies: [
            ProfileFixture.reply(
                profile: "Work: Acme.",
                topics: ["T1": "Joe and Dana plan hiring for Acme.", "T2": "Joe and Dana discuss the Acme seed round."])
        ])
        let consolidator = makeConsolidator(fixture, generator: generator)
        let outcome = await consolidator.consolidate()

        guard case .consolidated(let record) = outcome else {
            Issue.record("Expected a consolidation, got \(outcome)")
            return
        }
        #expect(record.topicChanges.map(\.topicID) == [ended.topicID])
        #expect(record.topicChanges.first?.after == "Joe and Dana discuss the Acme seed round.")
        #expect(try fixture.topicSummary(ended.topicID) == "Joe and Dana discuss the Acme seed round.")
        #expect(try fixture.topicSummary(openTopic) == "They talk hiring.")
    }

    @Test func aSummaryChangedMeanwhileIsKept() async throws {
        let fixture = try ProfileFixture()
        let topic = try await fixture.topics.recordTopic([(.user, "We hired Sam.", 5)], startingAt: 86_400)
        let conversations = fixture.topics.conversations
        let generator = ScriptedTextGenerator { _, _ in
            // Re-segmentation (or another device) writes a summary while
            // the model is answering.
            _ = try await conversations.replaceTopicSummary(topic.topicID, expected: nil, with: "Sam joins.")
            return ProfileFixture.reply(profile: "Work: Acme.", topics: ["T1": "Joe hires Sam as an engineer."])
        }
        _ = await makeConsolidator(fixture, generator: generator).consolidate()
        #expect(try fixture.topicSummary(topic.topicID) == "Sam joins.")
    }

    /// A practice run's topic (#69) keeps its summary: it is the run's
    /// record, one line per question with its score and note, and is kept
    /// nowhere else. That holds after the user renamed the topic too.
    @Test func neverRewritesAPracticeRunsRecord() async throws {
        let fixture = try ProfileFixture()
        let conversations = fixture.topics.conversations
        let conversation = ConversationID()
        let start = Support.t0.addingTimeInterval(86_400)
        try await conversations.startConversation(id: conversation, at: start)
        let record = """
            Practiced 2 of 11 questions in YC interview questions, average 55%.
            - What are you building? 70%. Lead with the customer.
            - Who are your users? 40%. Name one real user.
            """
        let run = try await conversations.openTopic(
            at: start, title: PracticeRunTopic.title(for: "YC interview questions"))
        try await conversations.closeTopic(
            run, title: PracticeRunTopic.title(for: "YC interview questions"), summary: record,
            at: start.addingTimeInterval(60))
        // The user renamed this run's topic: its record still marks it.
        let renamed = try await conversations.openTopic(at: start.addingTimeInterval(120), title: "My YC drill")
        try await conversations.closeTopic(
            renamed, title: "My YC drill", summary: record, at: start.addingTimeInterval(180))
        let hiring = try await conversations.openTopic(at: start.addingTimeInterval(240), title: "Hiring")
        try await conversations.closeTopic(
            hiring, title: "Hiring", summary: "They talk hiring.", at: start.addingTimeInterval(300))
        try await conversations.endConversation(conversation, at: start.addingTimeInterval(600))
        try await conversations.flush()

        let generator = ScriptedTextGenerator(replies: [
            ProfileFixture.reply(
                profile: "Goals: The user is preparing for the YC interview.",
                topics: [
                    "T1": "Joe and Dana plan hiring.", "T2": "The user practiced two YC questions.",
                    "T3": "The user rehearsed YC answers.",
                ])
        ])
        let outcome = await makeConsolidator(fixture, generator: generator).consolidate()

        guard case .consolidated(let consolidation) = outcome else {
            Issue.record("Expected a consolidation, got \(outcome)")
            return
        }
        // The runs are still shown for context, newest first.
        let shown = try #require(generator.requests.first?.prompt)
        #expect(shown.contains("T2"))
        #expect(shown.contains("T3"))
        #expect(consolidation.topicChanges.map(\.topicID) == [hiring])
        #expect(try fixture.topicSummary(hiring) == "Joe and Dana plan hiring.")
        #expect(try fixture.topicSummary(run) == record)
        #expect(try fixture.topicSummary(renamed) == record)
    }

    @Test func aPracticeRunsTopicNeverAcceptsASummary() {
        func topic(_ title: String, _ summary: String?) -> ProfileTopic {
            ProfileTopic(
                id: UUID(), title: title, summary: summary, startedAt: Support.t0,
                endedAt: Support.t0.addingTimeInterval(60), conversationEnded: true)
        }
        #expect(topic("Hiring", "They talk hiring.").acceptsSummary)
        #expect(topic("Hiring", nil).acceptsSummary)
        #expect(!topic("Practice: YC interview questions", nil).acceptsSummary)
        #expect(topic("Practice: YC interview questions", "Practiced 0 of 11 questions in YC.").isPracticeRun)
        #expect(!topic("My drill", "Practiced 3 of 11 questions in YC interview questions.").acceptsSummary)
        #expect(topic("Gym", "Practiced squats and deadlifts.").acceptsSummary)
    }

    // MARK: Concurrency with other devices

    @Test func aBlockChangedMeanwhileIsNotOverwritten() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: Stripe.", at: Support.t0)
        let generator = ScriptedTextGenerator { _, _ in
            // Another device's consolidation syncs in meanwhile.
            try fixture.addBlock("Work: Acme (from the iPad).", at: Support.t0.addingTimeInterval(3_600))
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let log = InMemoryProfileConsolidationLogStore()
        let outcome = await makeConsolidator(fixture, generator: generator, log: log).consolidate()
        #expect(outcome == .skipped(.conflict))
        #expect(try fixture.blocks().map(\.text).contains("Work: Acme (from the iPad)."))
        #expect(log.load().records.isEmpty)
    }

    @Test func duplicateBlocksAreMergedIntoOne() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: Acme.", at: Support.t0)
        try fixture.addBlock("Work: Old.", at: Support.t0.addingTimeInterval(-60))
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        _ = await makeConsolidator(fixture, generator: generator).consolidate()
        #expect(try fixture.blocks().map(\.text) == ["Work: Acme."])
    }

    // MARK: Refusals and failures

    @Test func anEmptyReplyNeverWipesAProfileWhileFactsExist() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        try fixture.addBlock("Work: Acme.", at: Support.t0)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "")])
        let outcome = await makeConsolidator(fixture, generator: generator).consolidate()
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(try fixture.blocks().map(\.text) == ["Work: Acme."])
    }

    @Test func modelErrorsFailWithoutWriting() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator { _, _ in throw FakeGeneratorError() }
        let log = InMemoryProfileConsolidationLogStore()
        let outcome = await makeConsolidator(fixture, generator: generator, log: log).consolidate()
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(try fixture.blocks().isEmpty)
        #expect(log.load().lastRunAt == nil)
        #expect(log.load().lastAttemptAt == Self.now)
        #expect(log.load().failedAttempts == 1)
    }

    @Test func learningOffOrNoKeySendsNothing() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let off = makeConsolidator(fixture, generator: generator, isEnabled: { false })
        #expect(await off.consolidate() == .skipped(.disabled))
        #expect(await off.consolidateIfDue() == .skipped(.disabled))
        generator.setAvailable(false)
        #expect(await makeConsolidator(fixture, generator: generator).consolidate() == .skipped(.generatorUnavailable))
        #expect(generator.requests.isEmpty)
    }

    // MARK: Scheduling

    @Test func runsWhenDueAndNotAgainUntilMemoryChanges() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let clock = ManualClock(now: Self.now)
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let consolidator = makeConsolidator(fixture, generator: generator, clock: clock)

        guard case .consolidated(let first) = await consolidator.consolidateIfDue() else {
            Issue.record("The first run should be due")
            return
        }
        #expect(first.reason == .firstRun)

        clock.advance(by: .seconds(86_400))
        guard case .notDue = await consolidator.consolidateIfDue() else {
            Issue.record("Nothing changed: not due")
            return
        }

        // Twenty new facts bring the next run forward.
        try fixture.addFacts(
            (1...20).map { (nil, "likes", "thing \($0)") }, createdAt: Self.now.addingTimeInterval(3_600))
        #expect(try await consolidator.decision() == .due(.newFacts))
        #expect(generator.requests.count == 1)
    }

    @Test func aBlockAnotherDeviceConsolidatedCountsAsTheLastRun() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")], createdAt: Self.now.addingTimeInterval(-7_200))
        try fixture.addBlock("Work: Acme.", at: Self.now.addingTimeInterval(-3_600))
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let decision = try await makeConsolidator(fixture, generator: generator).decision()
        #expect(decision == .notDue(nextCheck: Self.now.addingTimeInterval(-3_600 + 12 * 3_600)))
    }

    // MARK: Concurrency and telemetry

    @Test func concurrentCallsShareOneRun() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let latch = Latch()
        let generator = ScriptedTextGenerator { _, _ in
            await latch.wait()
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let consolidator = makeConsolidator(fixture, generator: generator)
        async let first = consolidator.consolidate()
        try await eventually { latch.waiterCount == 1 }
        async let second = consolidator.consolidate()
        // The second call is waiting for the first run, not starting one.
        try await eventually { await consolidator.waiterCount == 1 }
        latch.open()
        let outcomes = await [first, second]
        #expect(outcomes[0] == outcomes[1])
        #expect(generator.requests.count == 1)
    }

    /// The background task expiring cancels the request; nothing is written.
    @Test func cancellingStopsTheRunWithoutWriting() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator { _, _ in
            try await Task.sleep(for: .seconds(60))
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let log = InMemoryProfileConsolidationLogStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log)
        let run = Task { await consolidator.consolidate() }
        try await eventually { generator.requests.count == 1 }
        run.cancel()
        guard case .failed = await run.value else {
            Issue.record("Expected the cancelled run to fail")
            return
        }
        #expect(try fixture.blocks().isEmpty)
        #expect(log.load().lastRunAt == nil)
        #expect(await consolidator.isRunning == false)
    }

    @Test func runsUnderTheMemoryConsolidateSignpostAndReportsEvents() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let signposts = RecordingSignpostBackend()
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let consolidator = makeConsolidator(fixture, generator: generator, signposts: signposts)
        let events = consolidator.events()
        _ = await consolidator.consolidate(reason: .manual)
        #expect(signposts.completedIntervals.contains("memory.consolidate"))
        var seen: [ProfileConsolidationEvent] = []
        for await event in events {
            seen.append(event)
            if case .finished = event { break }
        }
        #expect(seen.first == .started(.manual))
    }

    // MARK: Erasing (#79)

    /// Settings → Privacy & Data deleted the learned facts: this device's
    /// log (profile text before and after each run) and waiting notes go
    /// too, while the schedule stays.
    @Test func erasingLocalHistoryDropsRecordsAndNotes() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let generator = ScriptedTextGenerator(replies: [ProfileFixture.reply(profile: "Work: Acme.")])
        let log = InMemoryProfileConsolidationLogStore()
        let notes = InMemoryProfileConsolidationNoteStore()
        let consolidator = makeConsolidator(fixture, generator: generator, log: log, notes: notes)
        _ = await consolidator.consolidate(reason: .manual)
        await consolidator.record(FactExtractionOutcome(topicID: UUID(), summary: "The user closed the round."))
        await consolidator.noteRemovedFacts(count: 2)
        #expect(!log.load().records.isEmpty)
        #expect(!notes.load().isEmpty)

        await consolidator.eraseLocalHistory()

        #expect(log.load().records.isEmpty)
        #expect(log.load().pendingRemovals == 0)
        #expect(log.load().lastRunAt == Self.now)
        #expect(notes.load().isEmpty)
        #expect(await consolidator.log().records.isEmpty)
    }

    /// A run that already read the facts finishes before they are deleted,
    /// so it can't write a profile from them afterwards.
    @Test func waitingUntilIdleWaitsForTheRunningConsolidation() async throws {
        let fixture = try ProfileFixture()
        try fixture.addFacts([(nil, "works at", "Acme")])
        let latch = Latch()
        let generator = ScriptedTextGenerator { _, _ in
            await latch.wait()
            return ProfileFixture.reply(profile: "Work: Acme.")
        }
        let consolidator = makeConsolidator(fixture, generator: generator)
        // Nothing running: returns at once.
        await consolidator.waitUntilIdle()

        let run = Task { await consolidator.consolidate() }
        try await eventually { generator.requests.count == 1 }
        let waiter = Task { await consolidator.waitUntilIdle() }
        try await eventually { await consolidator.waiterCount == 1 }
        #expect(await consolidator.isRunning)
        latch.open()
        await waiter.value
        _ = await run.value
        #expect(try fixture.blocks().first?.text == "Work: Acme.")
        #expect(await consolidator.waiterCount == 0)
    }
}
