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
