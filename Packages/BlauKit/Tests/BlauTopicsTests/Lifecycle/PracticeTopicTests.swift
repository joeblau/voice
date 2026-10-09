import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTopics

/// Practice runs as topics (#69): `TopicLifecycle` as the practice tools'
/// `PracticeRunRecording`.
@Suite("Practice topics")
struct PracticeTopicTests {
    static let title = "Practice: YC interview questions"

    /// Plays exchange `index` like `LifecycleFixture.play`, running
    /// `afterUser` between the user's utterance and the agent's reply (where
    /// Grok's tool call happens).
    static func play(
        _ fixture: LifecycleFixture, _ index: Int, afterUser: () async throws -> Void = {}
    ) async throws {
        try await fixture.record(fixture.users[index])
        await fixture.lifecycle.waitUntilIdle()
        try await afterUser()
        try await fixture.record(fixture.agents[index])
        await fixture.lifecycle.waitUntilIdle()
        await fixture.clock.waitForSleepers()
        fixture.clock.advance(by: .seconds(1))
        try await waitFor { await fixture.lifecycle.exchangeCount == index + 1 }
        await fixture.lifecycle.waitUntilIdle()
    }

    /// The tool's request time: just after the user's request ended.
    static func requestTime(_ fixture: LifecycleFixture, _ index: Int) -> Date {
        fixture.users[index].startedAt.addingTimeInterval(9)
    }

    @Test func aRunIsATopicOfItsOwnFromTheRequestToTheNextThingTheUserSays() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        let log = LifecycleEventLog(lifecycle)
        try await fixture.begin()
        try await fixture.play(0..<6)

        // Exchange 6 is the request; the tool call comes before the reply.
        var runID: UUID?
        try await Self.play(fixture, 6) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 6))
        }
        let run = try #require(runID)
        #expect(await lifecycle.isPracticeRunOpen(run))
        let practiceID = try #require(await lifecycle.practiceTopicID)
        #expect(await lifecycle.currentTopicID == practiceID)

        // Six exchanges of practice, two of them different subjects: no
        // topic opens inside the run.
        for index in 7..<12 {
            try await Self.play(fixture, index)
            await lifecycle.updatePracticeRun(run, summary: "Practiced \(index - 6) of 30 questions.")
        }
        await lifecycle.waitUntilIdle()
        var topics = try await fixture.topics()
        #expect(topics.count == 2)
        let practice = try #require(topics.last)
        #expect(practice.id == practiceID)
        #expect(practice.title == Self.title)
        #expect(!practice.titleIsProvisional)
        #expect(practice.summary == "Practiced 5 of 30 questions.")
        #expect(practice.startedAt == fixture.users[6].startedAt)
        // The topic before the run closed at the request and was refined.
        #expect(topics[0].endedAt == fixture.users[6].startedAt)
        #expect(!topics[0].titleIsProvisional)
        #expect(log.closed.contains { $0.id == topics[0].id })
        #expect(log.opened.contains { $0.id == practiceID })

        // The run ends; Grok's wrap-up (still exchange 11's reply here) stays
        // in it, and the topic closes when the user speaks next.
        await lifecycle.endPracticeRun(run, at: Self.requestTime(fixture, 11))
        #expect(!(await lifecycle.isPracticeRunOpen(run)))
        await lifecycle.waitUntilIdle()
        #expect(await lifecycle.currentTopicID == practiceID)
        try await fixture.play(12..<18)
        try await fixture.finish()

        topics = try await fixture.topics()
        #expect(try await fixture.topicStarts() == [0, 6, 12])
        #expect(topics[1].id == practiceID)
        #expect(topics[1].endedAt == fixture.users[12].startedAt)
        // Neither the closing refinement nor re-segmentation touched the
        // run's title or summary.
        #expect(topics[1].title == Self.title)
        #expect(topics[1].summary == "Practiced 5 of 30 questions.")
        #expect(try await fixture.topicOfExchange(11) == practiceID)
        #expect(try await fixture.topicOfExchange(12) == topics[2].id)
        #expect(!topics[2].titleIsProvisional)
        #expect(log.closed.filter { $0.id == practiceID }.count == 1)
    }

    @Test func aRunAskedForAtTheStartTakesTheFirstTopic() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        try await fixture.begin()
        let first = try #require(try await fixture.topics().first)
        var runID: UUID?
        try await Self.play(fixture, 0) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 0))
        }
        #expect(runID != nil)
        try await fixture.play(1..<4)
        let topics = try await fixture.topics()
        #expect(topics.count == 1)
        #expect(topics[0].id == first.id)
        #expect(topics[0].title == Self.title)
        #expect(!topics[0].titleIsProvisional)
        #expect(await lifecycle.practiceTopicID == first.id)
    }

    @Test func finishingTheConversationClosesTheRun() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        let log = LifecycleEventLog(lifecycle)
        try await fixture.begin()
        try await fixture.play(0..<3)
        var runID: UUID?
        try await Self.play(fixture, 3) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 3))
        }
        let run = try #require(runID)
        await lifecycle.updatePracticeRun(run, summary: "Practiced 1 of 30 questions, average 80%.")
        try await fixture.play(4..<6)
        try await fixture.finish()

        #expect(!(await lifecycle.isPracticeRunOpen(run)))
        let topics = try await fixture.topics()
        #expect(topics.count == 2)
        #expect(topics[1].title == Self.title)
        #expect(topics[1].summary == "Practiced 1 of 30 questions, average 80%.")
        #expect(!topics[1].isOpen)
        #expect(log.closed.contains { $0.id == topics[1].id })
        // A later run in the finished conversation isn't taken.
        #expect(await lifecycle.beginPracticeRun(title: Self.title, at: fixture.origin) == nil)
    }

    static let record =
        "Practiced 1 of 30 questions in YC interview questions, average 80%.\n"
        + "- Why now? 80%. Lead with the shift."

    /// A finished conversation of three topics, the second a practice run
    /// (exchanges 3 to 5) with a record: `topics[1]`.
    static func finishedRun() async throws -> (LifecycleFixture, [TopicSnapshot]) {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        try await fixture.begin()
        try await fixture.play(0..<3)
        var runID: UUID?
        try await Self.play(fixture, 3) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 3))
        }
        let run = try #require(runID)
        await lifecycle.updatePracticeRun(run, summary: Self.record)
        try await fixture.play(4..<6)
        await lifecycle.endPracticeRun(run, at: Self.requestTime(fixture, 5))
        try await fixture.play(6..<9)
        try await fixture.finish()
        let topics = try await fixture.topics()
        #expect(topics.count == 3)
        #expect(topics[1].title == Self.title)
        #expect(topics[1].summary == Self.record)
        return (fixture, topics)
    }

    /// The lifecycle no longer tracks the run once the conversation
    /// finished, so the guard must come from the stored topic: a merge
    /// relabels the survivor, and the record is kept nowhere else.
    @Test func mergingIntoARunAfterTheConversationKeepsItsRecord() async throws {
        let (fixture, topics) = try await Self.finishedRun()
        let log = LifecycleEventLog(fixture.lifecycle)

        let survivor = try await fixture.lifecycle.mergeWithPrevious(topics[2].id)
        await fixture.lifecycle.waitUntilIdle()
        #expect(survivor == topics[1].id)
        let merged = try await fixture.topics()
        #expect(merged.map(\.id) == [topics[0].id, topics[1].id])
        #expect(merged[1].title == Self.title)
        #expect(merged[1].summary == Self.record)
        #expect(try await fixture.topicOfExchange(8) == survivor)
        // Listeners still hear about the revised topic.
        try await waitFor { log.updated.contains { $0.id == survivor } }
    }

    @Test func aRenamedRunKeepsItsRecordThroughAMergeToo() async throws {
        let (fixture, topics) = try await Self.finishedRun()
        try await fixture.lifecycle.rename(topics[1].id, to: "Mock interview")
        await fixture.lifecycle.waitUntilIdle()

        try await fixture.lifecycle.mergeWithPrevious(topics[2].id)
        await fixture.lifecycle.waitUntilIdle()
        let merged = try await fixture.topics()
        #expect(merged[1].title == "Mock interview")
        #expect(merged[1].summary == Self.record)
    }

    @Test func splittingARunAfterTheConversationKeepsItsRecord() async throws {
        let (fixture, topics) = try await Self.finishedRun()

        let newID = try await fixture.lifecycle.split(topics[1].id, atUtterance: fixture.users[5].id)
        await fixture.lifecycle.waitUntilIdle()
        let split = try await fixture.topics()
        #expect(split.map(\.id) == [topics[0].id, topics[1].id, newID, topics[2].id])
        // The run's part keeps its record; the new part is labeled as usual.
        #expect(split[1].title == Self.title)
        #expect(split[1].summary == Self.record)
        #expect(split[2].title != Topic.placeholderTitle)
        #expect(split[2].summary != Self.record)
        #expect(try await fixture.topicOfExchange(5) == newID)
    }

    /// "Merge with Previous" on the run's own topic would delete it and
    /// leave the previous topic, relabeled, as the survivor: the record
    /// would be lost. The lifecycle refuses it, also after the conversation
    /// finished, when only the stored topic says it is a run.
    @Test func mergingARunIntoThePreviousTopicAfterTheConversationIsRefused() async throws {
        let (fixture, topics) = try await Self.finishedRun()

        await #expect(throws: TopicLifecycle.EditError.practiceRun) {
            try await fixture.lifecycle.mergeWithPrevious(topics[1].id)
        }
        await fixture.lifecycle.waitUntilIdle()
        let after = try await fixture.topics()
        #expect(after.map(\.id) == topics.map(\.id))
        #expect(after[0].title == topics[0].title)
        #expect(after[0].summary == topics[0].summary)
        #expect(after[1].title == Self.title)
        #expect(after[1].summary == Self.record)
        #expect(try await fixture.topicOfExchange(3) == topics[1].id)
    }

    @Test func aRenamedRunIsRecognizedByItsRecordAndNotMergedAway() async throws {
        let (fixture, topics) = try await Self.finishedRun()
        try await fixture.lifecycle.rename(topics[1].id, to: "Mock interview")
        await fixture.lifecycle.waitUntilIdle()

        await #expect(throws: TopicLifecycle.EditError.practiceRun) {
            try await fixture.lifecycle.mergeWithPrevious(topics[1].id)
        }
        await fixture.lifecycle.waitUntilIdle()
        let after = try await fixture.topics()
        #expect(after.map(\.id) == topics.map(\.id))
        #expect(after[1].title == "Mock interview")
        #expect(after[1].summary == Self.record)
    }

    /// A live run: refusing the merge keeps the lifecycle's run state on a
    /// topic that exists, so the next answers are still recorded there.
    @Test func mergingALiveRunIntoThePreviousTopicIsRefusedAndTheRunGoesOn() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        try await fixture.begin()
        try await fixture.play(0..<3)
        var runID: UUID?
        try await Self.play(fixture, 3) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 3))
        }
        let run = try #require(runID)
        await lifecycle.updatePracticeRun(run, summary: Self.record)
        try await Self.play(fixture, 4)
        let practiceID = try #require(await lifecycle.practiceTopicID)
        let before = try await fixture.topics()

        await #expect(throws: TopicLifecycle.EditError.practiceRun) {
            try await lifecycle.mergeWithPrevious(practiceID)
        }
        await lifecycle.waitUntilIdle()
        #expect(try await fixture.topics().map(\.id) == before.map(\.id))
        #expect(await lifecycle.isPracticeRunOpen(run))
        #expect(await lifecycle.practiceTopicID == practiceID)
        #expect(await lifecycle.currentTopicID == practiceID)

        let next = "Practiced 2 of 30 questions in YC interview questions, average 70%."
        await lifecycle.updatePracticeRun(run, summary: next)
        try await Self.play(fixture, 5)
        let practice = try #require(try await fixture.topics().first { $0.id == practiceID })
        #expect(practice.title == Self.title)
        #expect(practice.summary == next)
        #expect(try await fixture.topicOfExchange(5) == practiceID)
    }

    /// Before its first answer is recorded, a renamed live run has neither
    /// the title prefix nor a record: only the lifecycle knows it is a run.
    @Test func aRenamedLiveRunWithoutARecordIsNotMergedAwayEither() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        try await fixture.begin()
        try await fixture.play(0..<3)
        var runID: UUID?
        try await Self.play(fixture, 3) {
            runID = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 3))
        }
        let run = try #require(runID)
        let practiceID = try #require(await lifecycle.practiceTopicID)
        try await lifecycle.rename(practiceID, to: "Mock interview")
        await lifecycle.waitUntilIdle()

        await #expect(throws: TopicLifecycle.EditError.practiceRun) {
            try await lifecycle.mergeWithPrevious(practiceID)
        }
        await lifecycle.updatePracticeRun(run, summary: Self.record)
        await lifecycle.waitUntilIdle()
        let practice = try #require(try await fixture.topics().first { $0.id == practiceID })
        #expect(practice.title == "Mock interview")
        #expect(practice.summary == Self.record)
        #expect(await lifecycle.practiceTopicID == practiceID)
    }

    @Test func aSecondRunReplacesARunWaitingToClose() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let lifecycle = fixture.lifecycle
        try await fixture.begin()
        try await fixture.play(0..<3)
        var first: UUID?
        try await Self.play(fixture, 3) {
            first = await lifecycle.beginPracticeRun(title: Self.title, at: Self.requestTime(fixture, 3))
        }
        try await fixture.play(4..<5)
        await lifecycle.endPracticeRun(try #require(first), at: Self.requestTime(fixture, 4))
        var second: UUID?
        try await Self.play(fixture, 5) {
            second = await lifecycle.beginPracticeRun(
                title: "Practice: Sales objections", at: Self.requestTime(fixture, 5))
        }
        try await fixture.play(6..<8)
        let topics = try await fixture.topics()
        #expect(topics.map(\.title).suffix(2) == [Self.title, "Practice: Sales objections"])
        #expect(topics.last?.startedAt == fixture.users[5].startedAt)
        #expect(await lifecycle.isPracticeRunOpen(try #require(second)))
        #expect(!(await lifecycle.isPracticeRunOpen(try #require(first))))
    }

    @Test func withoutAConversationNoRunIsTaken() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        #expect(await fixture.lifecycle.beginPracticeRun(title: Self.title, at: fixture.origin) == nil)
        #expect(!(await fixture.lifecycle.isPracticeRunOpen(UUID())))
    }
}
