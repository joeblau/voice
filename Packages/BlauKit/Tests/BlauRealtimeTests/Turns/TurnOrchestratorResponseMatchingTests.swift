import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// Matching `response.created` to turns when the server doesn't echo the
/// `response.create` metadata (`turn: nil`): responses are matched in the
/// order they were asked for, and a turn given up before its response was
/// created keeps its place in that order.
@Suite("Turn orchestrator: untagged responses")
struct TurnOrchestratorResponseMatchingTests {
    @Test func aMergedTurnsLateResponseDoesntTakeTheContinuationsReply() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        let first = harness.utterance("I was thinking", from: 0, to: 1.5)
        await harness.orchestrator.handle(.final(first))
        try await harness.waitForSent("response.create", on: socket)
        // The continuation arrives before `resp_1`'s `response.created`.
        await harness.orchestrator.handle(.final(harness.utterance("about the launch", from: 1.8, to: 2.6)))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        for event in ServerEvents.reply("Sounds good.", response: "resp_2", item: "item_2", turn: nil) {
            socket.push(event)
        }

        try await waitUntil("continuation answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(harness.audio.enqueued.map(\.item.itemID).allSatisfy { $0 == "item_2" })
        #expect(!harness.audio.enqueued.isEmpty)
        // The merged turn's response is cancelled by id, and its item
        // (never played) removed from Grok's history.
        try await waitUntil("late response cleaned up") {
            socket.sentEvents.contains(.responseCancel(responseID: "resp_1"))
                && socket.sentEvents.contains(.conversationItemDelete(itemID: "item_1"))
        }
        #expect(!socket.sentEvents.contains(.responseCancel(responseID: "resp_2")))

        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.speaker) == [.user, .agent])
        #expect(stored[0].id == first.id)
        #expect(stored[0].text == "I was thinking about the launch")
        #expect(stored[1].text == "Sounds good.")
    }

    @Test func anInterruptedTurnsLateResponseDoesntTakeTheNextTurnsReply() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Tell me about the bridge", from: 0, to: 2)))
        try await harness.waitForSent("response.create", on: socket)
        // Something new, well after the question ended, before `resp_1` is
        // created.
        let followUp = harness.utterance("Actually, the tunnel", from: 5, to: 6)
        await harness.orchestrator.handle(.final(followUp))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        for event in ServerEvents.reply("It opened in 1937.", response: "resp_2", item: "item_2", turn: nil) {
            socket.push(event)
        }

        try await waitUntil("next turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_2"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["interrupted", "completed"])

        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.speaker) == [.user, .user, .agent])
        #expect(stored[1].id == followUp.id)
        #expect(stored[2].text == "It opened in 1937.")
    }

    @Test func aTimedOutTurnsLateResponseDoesntTakeTheNextTurnsReply() async throws {
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await harness.waitForState(.agentThinking)
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(5))
        try await waitUntil("timed out") {
            if case .error = await harness.orchestrator.state { true } else { false }
        }
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["timedOut"])

        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        // The first turn's response turns up after all, then the second's.
        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        for event in ServerEvents.reply("I'm here.", response: "resp_2", item: "item_2", turn: nil) {
            socket.push(event)
        }

        try await waitUntil("second turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_2"])
        try await waitUntil("late response cancelled") {
            socket.sentEvents.contains(.responseCancel(responseID: "resp_1"))
        }
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.speaker) == [.user, .user, .agent])
        #expect(harness.recording?.stored.last?.text == "I'm here.")
    }

    @Test func matchingRecoversWhenATimedOutTurnsResponseNeverComes() async throws {
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()

        func timeOut() async throws {
            try await harness.waitForState(.agentThinking)
            await harness.clock.waitForSleepers()
            harness.clock.advance(by: .seconds(5))
            try await waitUntil("timed out") {
                if case .error = await harness.orchestrator.state { true } else { false }
            }
        }

        // Turn 1 never gets a response.
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await timeOut()

        // Turn 2's response is taken for turn 1's (they can't be told apart
        // without the echo), so turn 2 times out too...
        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        socket.push(ServerEvents.responseCreated("resp_2", turn: nil))
        try await waitUntil("resp_2 cancelled") { socket.sentEvents.contains(.responseCancel(responseID: "resp_2")) }
        socket.push(ServerEvents.responseDone("resp_2", status: .cancelled))
        try await timeOut()

        // ...after which matching is back in step: turn 3 gets its reply.
        await harness.orchestrator.handle(.final(harness.utterance("Hello again", from: 20, to: 21)))
        try await harness.waitForSent("response.create", count: 3, on: socket)
        for event in ServerEvents.reply("Hi!", response: "resp_3", item: "item_3", turn: nil) {
            socket.push(event)
        }
        try await waitUntil("third turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_3"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["timedOut", "timedOut", "completed"])
    }

    @Test func anEchoedTagStillMatchesItsOwnTurn() async throws {
        // With the echo, an abandoned turn's response is matched by its tag,
        // whatever order the events come in.
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("I was thinking", from: 0, to: 1.5)))
        try await harness.waitForSent("response.create", on: socket)
        await harness.orchestrator.handle(.final(harness.utterance("about the launch", from: 1.8, to: 2.6)))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        for event in ServerEvents.reply("Sounds good.", response: "resp_2", item: "item_2", turn: socket.turnTag(1)) {
            socket.push(event)
        }
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag(0)))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await waitUntil("continuation answered") { await harness.snapshot().completedTurns == 1 }
        await harness.orchestrator.waitUntilSettled()
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_2"])
    }
}

@Suite("Turn orchestrator: refined transcripts")
struct TurnOrchestratorRefinedTranscriptTests {
    @Test func aRefinedFinalReplacesTheStoredTextButIsntSentAgain() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        var utterance = harness.utterance("whats the weather in paris", from: 0, to: 2)
        await harness.orchestrator.handle(.final(utterance))
        try await harness.waitForSent("response.create", on: socket)

        utterance.text = "What's the weather in Paris?"
        await harness.orchestrator.handle(.refined(utterance))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["What's the weather in Paris?"])
        #expect(harness.recording?.stored.first?.id == utterance.id)
        #expect(socket.sentUserTexts == ["whats the weather in paris"])
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 1)
    }

    @Test func aRefinedPartOfAMergedUtteranceUpdatesTheMergedRow() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        let first = harness.utterance("i was thinking", from: 0, to: 1.5)
        var second = harness.utterance("about the launch", from: 1.8, to: 2.6)
        await harness.orchestrator.handle(.final(first))
        try await harness.waitForSent("response.create", on: socket)
        // The first part's refinement arrives before the continuation.
        var refinedFirst = first
        refinedFirst.text = "I was thinking"
        await harness.orchestrator.handle(.refined(refinedFirst))
        await harness.orchestrator.handle(.final(second))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        second.text = "about the launch."
        await harness.orchestrator.handle(.refined(second))

        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.id) == [first.id])
        #expect(stored.map(\.text) == ["I was thinking about the launch."])
    }

    @Test func aRefinedIgnoredFinalStaysUnstored() async throws {
        let harness = TurnHarness()
        _ = try await harness.start()
        var rejected = harness.utterance("someone else", from: 0, to: 1, decision: .reject)
        await harness.orchestrator.handle(.final(rejected))
        rejected.text = "Someone else."
        await harness.orchestrator.handle(.refined(rejected))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.isEmpty == true)
    }
}
