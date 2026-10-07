import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauTopics
import Foundation
import Testing

/// Offline (#80): while Grok's replies wait for the connection, the user's
/// utterances still become exchanges and topics keep segmenting.
@Suite("Topic lifecycle: offline")
struct TopicLifecycleOfflineTests {
    /// Plays only the user's side of `exchanges`, as the turn orchestrator
    /// records it while offline: no replies.
    func playUserSide(of fixture: LifecycleFixture, _ exchanges: Range<Int>) async throws {
        for index in exchanges {
            try await fixture.record(fixture.users[index])
            await fixture.lifecycle.waitUntilIdle()
            await fixture.clock.waitForSleepers()
            fixture.clock.advance(by: .seconds(1))
            try await waitFor { await fixture.lifecycle.exchangeCount == index + 1 }
            await fixture.lifecycle.waitUntilIdle()
        }
    }

    @Test func topicsKeepSegmentingWhileRepliesAreDeferred() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        await fixture.lifecycle.setRepliesDeferred(true, in: fixture.conversation)
        try await playUserSide(of: fixture, 0..<fixture.transcript.count)
        try await fixture.finish()

        let topics = try await fixture.topics()
        #expect(topics.count == 3, "\(topics.map(\.title))")
        // With only the user's side (short questions, no answers) the
        // boundaries are less precise than with whole exchanges, but every
        // switch is found close to where the subject changes.
        let starts = try await fixture.topicStarts()
        #expect(starts.first == 0)
        #expect(starts.count == fixture.transcript.boundaries.count + 1, "\(starts)")
        for (found, labelled) in zip(starts.dropFirst(), fixture.transcript.boundaries) {
            #expect(abs(found - labelled) <= 2, "boundary at \(found), labelled \(labelled)")
        }
    }

    @Test func withoutTheSignalUnansweredUtterancesWaitForAReply() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        for index in 0..<4 {
            try await fixture.record(fixture.users[index])
        }
        await fixture.lifecycle.waitUntilIdle()
        // Online, user utterances with no reply yet are one exchange in the
        // making (the user may still be adding to it).
        #expect(await fixture.lifecycle.exchangeCount == 0)
    }

    @Test func repliesResumingRestoresTheUsualGrouping() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        await fixture.lifecycle.setRepliesDeferred(true, in: fixture.conversation)
        try await playUserSide(of: fixture, 0..<2)
        #expect(await fixture.lifecycle.exchangeCount == 2)

        await fixture.lifecycle.setRepliesDeferred(false, in: fixture.conversation)
        // Back online: a question and its answer are one exchange again.
        try await fixture.play(2..<4)
        #expect(await fixture.lifecycle.exchangeCount == 4)
    }

    @Test func anotherConversationsSignalIsIgnored() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        await fixture.lifecycle.setRepliesDeferred(true, in: ConversationID())
        for index in 0..<3 {
            try await fixture.record(fixture.users[index])
        }
        await fixture.lifecycle.waitUntilIdle()
        #expect(await fixture.lifecycle.exchangeCount == 0)
    }
}
