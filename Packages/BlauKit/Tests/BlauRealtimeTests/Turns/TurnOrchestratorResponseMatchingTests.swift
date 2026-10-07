import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// Matching `response.created` to turns when the server doesn't echo the
/// `response.create` metadata (`turn: nil`). Only one `response.create` is
/// outstanding at a time: the next turn's waits until the previous one is
/// answered (`response.created`, or an `error` rejecting it) and any
/// cancelled response is done, or until the hold limit. So an untagged
/// `response.created` always answers the one outstanding request.
///
/// The server events in these tests follow the requests the orchestrator
/// actually sent, in order, as a server does.
@Suite("Turn orchestrator: untagged responses")
struct TurnOrchestratorResponseMatchingTests {
    /// Waits until the orchestrator reports an error.
    private func waitForError(_ harness: TurnHarness) async throws {
        try await waitUntil("error state") {
            if case .error = await harness.orchestrator.state { true } else { false }
        }
    }

    /// Lets turn 1 (already sent) time out after the harness's 5 s.
    private func timeOut(_ harness: TurnHarness) async throws {
        try await harness.waitForState(.agentThinking)
        await harness.elapse(.seconds(5))
        try await waitForError(harness)
    }

    private func responseCreates(_ socket: FakeSocket) -> Int {
        socket.sentEvents.filter { $0.type == "response.create" }.count
    }

    @Test func aMergedTurnsLateResponseDoesntTakeTheContinuationsReply() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        let first = harness.utterance("I was thinking", from: 0, to: 1.5)
        await harness.orchestrator.handle(.final(first))
        try await harness.waitForSent("response.create", on: socket)
        // The continuation arrives before `resp_1`'s `response.created`: its
        // text goes out at once, its `response.create` waits.
        await harness.orchestrator.handle(.final(harness.utterance("about the launch", from: 1.8, to: 2.6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        #expect(responseCreates(socket) == 1)

        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
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
        #expect(!socket.cancelledResponses.contains("resp_2"))

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
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)

        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
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
        try await timeOut(harness)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["timedOut"])

        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        // The first turn's response turns up after all, then the second's.
        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
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

    @Test func aTimedOutTurnsMissingResponseHoldsTheNextTurnBackOnlyBriefly() async throws {
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()

        // Turn 1 never gets a response.
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await timeOut(harness)

        // Turn 2's request waits for turn 1's answer, up to the hold limit.
        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        #expect(responseCreates(socket) == 1)
        await harness.elapse(.seconds(2))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        for event in ServerEvents.reply("Hi!", response: "resp_2", item: "item_2", turn: nil) {
            socket.push(event)
        }
        try await waitUntil("second turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_2"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["timedOut", "completed"])
        #expect(socket.cancelledResponses == [nil])  // only turn 1's, when it timed out
    }

    /// Review probe 1: turn 1 times out and its response never comes; the
    /// user speaks again, and interrupts that turn before its reply too.
    @Test func aTimeoutFollowedByAnInterruptionDoesntShiftLaterReplies() async throws {
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await timeOut(harness)

        // Turn 2: its request goes out once the hold limit gives up on
        // turn 1's.
        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        await harness.elapse(.seconds(2))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        // Turn 3 interrupts turn 2 before `resp_2` is created.
        await harness.orchestrator.handle(.final(harness.utterance("Hello??", from: 14, to: 15)))
        try await harness.waitForSent("conversation.item.create", count: 3, on: socket)
        #expect(responseCreates(socket) == 2)
        socket.push(ServerEvents.responseCreated("resp_2", turn: nil))
        socket.push(ServerEvents.responseDone("resp_2", status: .cancelled))
        try await harness.waitForSent("response.create", count: 3, on: socket)
        for event in ServerEvents.reply("Hi!", response: "resp_3", item: "item_3", turn: nil) {
            socket.push(event)
        }

        try await waitUntil("third turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_3"])
        #expect(socket.cancelledResponses.contains("resp_2"))
        #expect(!socket.cancelledResponses.contains("resp_3"))
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["timedOut", "interrupted", "completed"])
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.last?.text == "Hi!")
    }

    /// Probe 1 with the interruption while turn 2's request is still held:
    /// turn 2 never asks, and turn 3's request is the next one sent.
    @Test func aTurnInterruptedWhileItsRequestIsHeldNeverSendsIt() async throws {
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await timeOut(harness)

        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        await harness.orchestrator.handle(.final(harness.utterance("Hello??", from: 14, to: 15)))
        try await harness.waitForSent("conversation.item.create", count: 3, on: socket)
        await harness.elapse(.seconds(2))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        #expect(socket.turnTag(1) == "3")
        // Turn 2 never asked for a response, so it cancels none.
        #expect(socket.cancelledResponses == [nil])

        for event in ServerEvents.reply("Hi!", response: "resp_3", item: "item_3", turn: nil) {
            socket.push(event)
        }
        try await waitUntil("third turn answered") { await harness.snapshot().completedTurns == 1 }
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_3"])
    }

    /// Review probe 2: an interruption whose `response.create` is rejected
    /// because the cancelled response is still active. It is asked again
    /// once that response is done, and the turns after it stay in step.
    @Test(arguments: [true, false])
    func aRejectedRequestIsAskedAgainAndLaterTurnsStayInStep(serverNamesTheEvent: Bool) async throws {
        let harness = TurnHarness()
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Tell me about the bridge", from: 0, to: 2)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: nil))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 1000))
        try await harness.waitForState(.agentSpeaking)

        // Turn 2 interrupts; its request waits for `resp_1` to finish, but
        // the server is slow to, so it goes out at the hold limit and is
        // rejected.
        await harness.orchestrator.handle(.final(harness.utterance("Actually, the tunnel", from: 5, to: 6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        #expect(socket.cancelledResponses == ["resp_1"])
        await harness.elapse(.seconds(2))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        let rejected = try #require(socket.responseCreateEventIDs.last ?? nil)
        socket.push(ServerEvents.activeResponseError(eventID: serverNamesTheEvent ? rejected : nil))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 3, on: socket)
        let retry = try #require(socket.responseCreateEventIDs.last ?? nil)
        #expect(retry != rejected)
        #expect(socket.turnTag(2) == "2")

        // Turn 3 interrupts turn 2 before its response is created.
        await harness.orchestrator.handle(.final(harness.utterance("Hello?", from: 9, to: 10)))
        try await harness.waitForSent("conversation.item.create", count: 3, on: socket)
        socket.push(ServerEvents.responseCreated("resp_2", turn: nil))
        socket.push(ServerEvents.responseDone("resp_2", status: .cancelled))
        try await harness.waitForSent("response.create", count: 4, on: socket)
        harness.audio.setIdle(true)
        for event in ServerEvents.reply("Hi!", response: "resp_3", item: "item_3", turn: nil) {
            socket.push(event)
        }

        try await waitUntil("third turn answered") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(harness.audio.enqueued.contains { $0.item.itemID == "item_3" })
        #expect(!harness.audio.enqueued.contains { $0.item.itemID == "item_2" })
        #expect(socket.cancelledResponses.contains("resp_2"))
        #expect(!socket.cancelledResponses.contains("resp_3"))
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["interrupted", "interrupted", "completed"])
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.last?.text == "Hi!")
    }

    @Test(arguments: [true, false])
    func aRequestRejectedWhileAnUnseenResponseRunsIsAskedAgainWhenItIsDone(serverNamesTheEvent: Bool)
        async throws
    {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        #expect(socket.responseCreateEventIDs == ["blau_rc_1_1"])

        socket.push(ServerEvents.activeResponseError(eventID: serverNamesTheEvent ? "blau_rc_1_1" : nil))
        // Not asked again until the active response is done.
        try await waitUntil("rejection handled") { await harness.orchestrator.state == .agentThinking }
        try await Task.sleep(for: .milliseconds(50))
        #expect(responseCreates(socket) == 1)
        socket.push(ServerEvents.responseDone("resp_other", status: .completed))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        #expect(socket.responseCreateEventIDs == ["blau_rc_1_1", "blau_rc_1_2"])

        for event in ServerEvents.reply("Hi!", response: "resp_1", item: "item_1", turn: nil) {
            socket.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 1 }
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_1"])
    }

    @Test func aRequestRejectedForAnotherReasonFailsTheTurnAtOnce() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await harness.waitForState(.agentThinking)

        // An error about some other request changes nothing.
        socket.push(ServerEvents.error("invalid_value", eventID: "evt_other"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.orchestrator.state == .agentThinking)

        socket.push(ServerEvents.error("invalid_value", eventID: "blau_rc_1_1", message: "Invalid response"))
        try await waitForError(harness)
        #expect(
            await harness.orchestrator.state
                == .error(
                    TurnFailure(
                        kind: .response, message: "Invalid response",
                        issue: UserFacingIssue(.replyFailed, detail: "Invalid response"))))
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["rejected"])
        #expect(responseCreates(socket) == 1)

        // Nothing is outstanding: the next turn asks straight away.
        await harness.orchestrator.handle(.final(harness.utterance("Hello?", from: 5, to: 6)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        for event in ServerEvents.reply("Hi!", response: "resp_2", item: "item_2", turn: nil) {
            socket.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 1 }
    }

    @Test func anEchoedTagMatchesALateResponseAfterTheHoldLimit() async throws {
        // Turn 1's request goes unanswered past the hold limit, so turn 2's
        // goes out; turn 1's response then turns up after all. Its tag says
        // whose it is, so it isn't taken for turn 2's.
        let harness = TurnHarness(configuration: .init(responseTimeout: .seconds(5)))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await timeOut(harness)
        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        await harness.elapse(.seconds(2))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag(0)))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        for event in ServerEvents.reply("I'm here.", response: "resp_2", item: "item_2", turn: socket.turnTag(1)) {
            socket.push(event)
        }
        try await waitUntil("second turn answered") { await harness.snapshot().completedTurns == 1 }
        await harness.orchestrator.waitUntilSettled()
        #expect(Set(harness.audio.enqueued.map(\.item.itemID)) == ["item_2"])
        #expect(socket.cancelledResponses.contains("resp_1"))
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
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
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
