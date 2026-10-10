import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

@Suite("Turn orchestrator")
struct TurnOrchestratorTests {
    // MARK: A full turn

    @Test func aTurnGoesFromTheUtteranceToAudioTranscriptAndStorage() async throws {
        let harness = TurnHarness()
        let updates = StreamCollector(harness.orchestrator.updates(bufferingPolicy: .unbounded))
        defer { updates.cancel() }
        harness.audio.setIdle(false)
        let socket = try await harness.start()

        await harness.orchestrator.handle(
            .partial(text: "What should", range: TimeRange(start: .zero, duration: .seconds(1))))
        try await harness.waitForState(.userSpeaking)
        #expect(await harness.snapshot().userPartial == "What should")

        let question = harness.utterance("What should I focus on this week?", from: 0, to: 2)
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)
        try await harness.waitForState(.agentThinking)

        // The session is configured first, then the text item, then the
        // request, tagged with the turn.
        #expect(socket.sentEvents.map(\.type) == ["session.update", "conversation.item.create", "response.create"])
        #expect(socket.sentUserTexts == ["What should I focus on this week?"])
        let tag = try #require(socket.turnTag())
        #expect(await harness.snapshot().userPartial == nil)

        // 640 ms later the first audio arrives.
        harness.clock.advance(by: .milliseconds(640))
        for event in ServerEvents.reply(
            "Start with the launch checklist.", response: "resp_1", item: "item_1", turn: tag)
        {
            socket.push(event)
        }
        try await waitUntil("response done") { await harness.snapshot().completedTurns == 1 }

        // Audio went to the player under the item's id, and was finished.
        let item = PlaybackItemID(itemID: "item_1", contentIndex: 0)
        #expect(Set(harness.audio.enqueued.map(\.item)) == [item])
        #expect(harness.audio.enqueuedBytes == 500 / 5 * 5 * 48)
        #expect(harness.audio.finished.contains(item))

        // Still playing: the agent is speaking, its words on screen.
        var snapshot = await harness.snapshot()
        #expect(snapshot.state == .agentSpeaking)
        #expect(snapshot.agentText == "Start with the launch checklist.")
        #expect(snapshot.usage.totalTokens == 120)
        #expect(snapshot.usage.responses == 1)
        // Billed usage for the HUD's cost estimate: one text input, 500 ms of reply audio.
        #expect(snapshot.usage.textInputs == 1)
        #expect(snapshot.usage.outputAudio == .milliseconds(500))
        #expect(snapshot.latency.firstAudio.last == .milliseconds(640))
        #expect(snapshot.latency.firstAudio.p50 == .milliseconds(640))
        #expect(snapshot.latency.turn.last == .milliseconds(640))

        // Playback drains: back to listening.
        harness.audio.setIdle(true)
        try await harness.waitForState(.listening)
        snapshot = await harness.snapshot()
        #expect(snapshot.agentText.isEmpty)

        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.speaker) == [.user, .agent])
        #expect(stored.map(\.text) == ["What should I focus on this week?", "Start with the launch checklist."])
        #expect(stored.allSatisfy { $0.conversationID == harness.conversationID })
        #expect(stored[0].id == question.id)
        #expect(stored[1].timeRange.duration == .milliseconds(500))
        #expect(stored[1].startedAt == turnT0.addingTimeInterval(0.64))

        // The collector reads the snapshots on a task of its own: let it
        // catch up with the last one before comparing.
        try await waitUntil("every state collected") { updates.states.count >= 7 }
        #expect(
            updates.states == [
                .paused, .listening, .userSpeaking, .committing, .agentThinking, .agentSpeaking, .listening,
            ])
        #expect(harness.signposts.completedIntervals == ["realtime.firstAudio", "realtime.turn"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["completed"])
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func aTextOnlyReplyIsStoredAndEndsTheTurnAtOnce() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Spell it", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)

        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(
            .responseOutputTextDelta(.init(responseID: "resp_1", itemID: "item_1", contentIndex: 0, delta: "B-L-A-U")))
        socket.push(ServerEvents.responseDone("resp_1"))
        try await waitUntil("completed") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)

        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Spell it", "B-L-A-U"])
        #expect(harness.audio.enqueued.isEmpty)
        #expect(await harness.snapshot().latency.firstAudio.totalCount == 0)
        #expect(harness.signposts.endMessages(of: "realtime.firstAudio") == ["completed"])
    }

    @Test func theTranscriptFromResponseDoneFillsInMissingDeltas() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hi", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(
            .responseDone(
                .init(
                    response: RealtimeResponse(
                        id: "resp_1", status: .completed,
                        output: [
                            .message(
                                .init(
                                    id: "item_1", role: .assistant,
                                    content: [ContentPart(type: .audio, transcript: "Hello there.")]))
                        ]))))
        try await harness.waitForState(.listening)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Hi", "Hello there."])
    }

    // MARK: Filtering

    /// The gate (#47) passes an uncertain utterance on only when its
    /// uncertain policy allows it, so the orchestrator sends it.
    @Test func blankAndRejectedUtterancesAreNotSent() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        try await harness.orchestrator.send(harness.utterance("   ", from: 0, to: 1))
        try await harness.orchestrator.send(harness.utterance("TV noise", from: 2, to: 3, decision: .reject))
        try await harness.orchestrator.send(harness.utterance("Maybe me", from: 4, to: 5, decision: .uncertain))
        try await harness.orchestrator.send(harness.utterance("Me", from: 6, to: 7, decision: .accept))
        try await harness.waitForSent("response.create", on: socket)
        await harness.orchestrator.waitUntilSettled()
        #expect(socket.sentUserTexts == ["Maybe me", "Me"])
        #expect(harness.recording?.stored.map(\.text) == ["Maybe me", "Me"])
    }

    @Test func anIgnoredUtteranceEndsTheUserSpeakingState() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.partial(text: "Turn it", range: .instant(.zero)))
        try await harness.waitForState(.userSpeaking)
        await harness.orchestrator.handle(.final(harness.utterance("Turn it up", from: 0, to: 1, decision: .reject)))
        try await harness.waitForState(.listening)
        #expect(await harness.snapshot().userPartial == nil)
        #expect(socket.sentUserTexts.isEmpty)
    }

    @Test func sendingOutsideAConversationThrows() async throws {
        let harness = TurnHarness()
        await #expect(throws: TurnOrchestrator.OrchestratorError.notRunning) {
            try await harness.orchestrator.send(harness.utterance("Hello", from: 0, to: 1))
        }
    }

    // MARK: Rapid follow-ups

    @Test func aFollowUpWithinTheMergeWindowContinuesTheTurn() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        let first = harness.utterance("I was thinking", from: 0, to: 1.5)
        await harness.orchestrator.handle(.final(first))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag(0)))
        try await waitUntil("response matched") { await harness.orchestrator.state == .agentThinking }

        // Resumed 300 ms after the first part ended.
        await harness.orchestrator.handle(.final(harness.utterance("about the launch", from: 1.8, to: 2.6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)

        // The new `response.create` waits until the cancelled response is
        // done: the server runs one response at a time. (If `resp_1`'s
        // `response.created` is handled after the merge, it is cancelled
        // again by id.)
        #expect(
            Array(socket.sentEvents.map(\.type).prefix(5)) == [
                "session.update", "conversation.item.create", "response.create", "response.cancel",
                "conversation.item.create",
            ])
        // `resp_1`, or the response in progress if its `response.created`
        // hadn't been handled yet: either cancels it.
        #expect(
            [.responseCancel(responseID: "resp_1"), .responseCancel(responseID: nil)].contains(socket.sentEvents[3]))
        #expect(socket.sentUserTexts == ["I was thinking", "about the launch"])

        // The cancelled response's late audio is dropped.
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        #expect(socket.sentEvents.last?.type == "response.create")
        socket.push(ServerEvents.responseCreated("resp_2", turn: socket.turnTag(1)))
        socket.push(ServerEvents.audio("item_2", response: "resp_2", milliseconds: 100))
        try await harness.waitForState(.agentSpeaking)
        #expect(harness.audio.enqueued.map(\.item.itemID) == ["item_2"])

        // One user utterance, merged, under the first part's id.
        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.count == 1)
        #expect(stored[0].id == first.id)
        #expect(stored[0].text == "I was thinking about the launch")
        #expect(stored[0].timeRange == TimeRange(start: .zero, end: .seconds(2.6)))
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["merged"])
        #expect(harness.signposts.events == ["realtime.turnMerged"])
        // Only the continued turn is a latency sample; the cancelled one
        // never ended.
        #expect(await harness.snapshot().latency.firstAudio.totalCount == 1)
    }

    @Test func aMergedReplyThatWasNeverHeardIsRemovedFromGroksHistory() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("So", from: 0, to: 0.5)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag(0)))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 80))
        try await harness.waitForState(.agentSpeaking)

        // Still in the jitter buffer: nothing heard.
        await harness.orchestrator.handle(.final(harness.utterance("what now", from: 0.7, to: 1.2)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        #expect(socket.sentEvents.contains(.conversationItemDelete(itemID: "item_1")))
        #expect(!socket.sentEvents.contains { $0.type == "conversation.item.truncate" })
        #expect(harness.audio.flushes == 1)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.speaker) == [.user])
    }

    @Test func aQueuedFollowUpMergesIntoTheQueuedUtterance() async throws {
        let connector = FakeConnector(script: [.fail(.network(code: URLError.notConnectedToInternet.rawValue))])
        let harness = TurnHarness(connector: connector)
        let started = Task { try await harness.orchestrator.start(conversationID: harness.conversationID) }
        try await waitUntil("retry scheduled") { harness.clock.sleeperCount > 0 }

        await harness.orchestrator.handle(.final(harness.utterance("First half", from: 0, to: 1)))
        await harness.orchestrator.handle(.final(harness.utterance("second half", from: 1.2, to: 2)))
        #expect(await harness.snapshot().queuedUtterances == 1)

        harness.clock.advance(by: .seconds(1))
        _ = try await started.value
        let socket = try await connector.socket(0)
        try await harness.waitForSent("response.create", on: socket)
        #expect(socket.sentEvents.map(\.type).first == "session.update")
        #expect(socket.sentUserTexts == ["First half", "second half"])
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 1)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["First half second half"])
    }

    // MARK: Interruptions

    @Test func aNewUtteranceCutsTheReplyAtWhatWasHeard() async throws {
        let harness = TurnHarness()
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Tell me about the bridge", from: 0, to: 2)))
        try await harness.waitForSent("response.create", on: socket)
        let tag = socket.turnTag()
        socket.push(ServerEvents.responseCreated("resp_1", turn: tag))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 1000))
        socket.push(ServerEvents.transcript("item_1", response: "resp_1", "The Golden Gate Bridge opened in 1937."))
        try await harness.waitForState(.agentSpeaking)
        try await waitUntil("transcript") { await !harness.snapshot().agentText.isEmpty }
        harness.audio.setPlayed(PlaybackItemID(itemID: "item_1"), milliseconds: 500)

        // Something new, well after the question ended.
        let followUp = harness.utterance("Actually, just the year", from: 5, to: 6)
        await harness.orchestrator.handle(.final(followUp))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        let types = socket.sentEvents.map(\.type)
        #expect(
            Array(types.suffix(4)) == [
                "response.cancel", "conversation.item.truncate", "conversation.item.create", "response.create",
            ])
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 500)))
        #expect(harness.audio.flushes == 1)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["interrupted"])
        #expect(harness.signposts.events == ["realtime.turnInterrupted"])

        // What was heard is stored, then corrected by the server's cut.
        await harness.orchestrator.waitUntilSettled()
        let agent = try #require(harness.recording?.stored.first { $0.speaker == .agent })
        #expect(agent.text == "The Golden Gate")
        #expect(agent.timeRange.duration == .milliseconds(500))
        socket.push(
            .conversationItemTruncated(
                .init(
                    itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 500,
                    transcript: "The Golden Gate Bridge")))
        try await waitUntil("truncated transcript stored") {
            await harness.orchestrator.waitUntilSettled()
            return harness.recording?.stored.first { $0.speaker == .agent }?.text == "The Golden Gate Bridge"
        }
        #expect(harness.recording?.stored.first { $0.speaker == .agent }?.id == agent.id)
        #expect(harness.recording?.stored.map(\.speaker) == [.user, .agent, .user])
        #expect(harness.recording?.stored.last?.id == followUp.id)
    }

    @Test func aReplyStillPlayingAfterResponseDoneIsCutToo() async throws {
        let harness = TurnHarness()
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hi", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in ServerEvents.reply(
            "Hello and welcome back.", response: "resp_1", item: "item_1", turn: socket.turnTag(),
            audioMilliseconds: 2000)
        {
            socket.push(event)
        }
        try await waitUntil("done") { await harness.snapshot().completedTurns == 1 }
        #expect(await harness.orchestrator.state == .agentSpeaking)
        harness.audio.setPlayed(PlaybackItemID(itemID: "item_1"), milliseconds: 1000)

        await harness.orchestrator.handle(.final(harness.utterance("Thanks", from: 4, to: 5)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        // The response was already done: nothing to cancel, only to cut.
        #expect(!socket.sentEvents.contains { $0.type == "response.cancel" })
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 1000)))
        await harness.orchestrator.waitUntilSettled()
        let agent = try #require(harness.recording?.stored.first { $0.speaker == .agent })
        #expect(agent.text == "Hello and")
    }

    // MARK: Connection

    @Test func utterancesWaitForTheConnectionAndGoOutAfterTheSessionIsConfigured() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()

        // The connection drops; the reconnect fails once and waits 0.5 s.
        connector.enqueue(.fail(.network(code: URLError.networkConnectionLost.rawValue)))
        first.fail()
        try await waitUntil("waiting to retry") { harness.clock.sleeperCount > 0 }
        try await waitUntil("connection lost") { await !harness.snapshot().connection.isConnected }

        await harness.orchestrator.handle(.final(harness.utterance("Are you there?", from: 10, to: 11)))
        await harness.orchestrator.handle(.final(harness.utterance("Hello?", from: 14, to: 15)))
        #expect(await harness.snapshot().queuedUtterances == 2)
        #expect(await harness.orchestrator.state == .listening)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Are you there?", "Hello?"])

        harness.clock.advance(by: .milliseconds(500))
        let second = try await connector.socket(1)
        try await harness.waitForSent("response.create", on: second)
        #expect(
            second.sentEvents.map(\.type) == [
                "session.update", "conversation.item.create", "conversation.item.create", "response.create",
            ])
        #expect(second.sentUserTexts == ["Are you there?", "Hello?"])
        #expect(await harness.snapshot().queuedUtterances == 0)

        // A turn that waited out an outage isn't a latency sample.
        harness.clock.advance(by: .milliseconds(300))
        for event in ServerEvents.reply("Yes.", response: "resp_9", item: "item_9", turn: second.turnTag()) {
            second.push(event)
        }
        try await harness.waitForState(.listening)
        #expect(await harness.snapshot().latency.firstAudio.totalCount == 0)
        #expect(await harness.snapshot().completedTurns == 1)
    }

    @Test func aTurnLostBeforeItsReplyStartedIsSentAgain() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("What's the weather?", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: first)
        first.push(ServerEvents.responseCreated("resp_1", turn: first.turnTag()))

        // The drop happens before any audio; the reconnect is immediate.
        first.fail()
        let second = try await connector.socket(1)
        try await harness.waitForSent("response.create", on: second)
        #expect(second.sentEvents.map(\.type) == ["session.update", "conversation.item.create", "response.create"])
        #expect(second.sentUserTexts == ["What's the weather?"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["requeued"])
        await harness.orchestrator.waitUntilSettled()
        // Stored once.
        #expect(harness.recording?.stored.map(\.text) == ["What's the weather?"])
    }

    @Test func aReplyCutOffByADropKeepsWhatArrived() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Tell me a story", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: first)
        first.push(ServerEvents.responseCreated("resp_1", turn: first.turnTag()))
        first.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 300))
        first.push(ServerEvents.transcript("item_1", response: "resp_1", "Once upon a time"))
        try await waitUntil("transcript") { await harness.snapshot().agentText == "Once upon a time" }

        first.fail()
        _ = try await connector.socket(1)
        try await harness.waitForState(.listening)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Tell me a story", "Once upon a time"])
        #expect(harness.audio.finished.contains(PlaybackItemID(itemID: "item_1")))
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["dropped"])
    }

    @Test func startingWithoutWaitingQueuesUntilTheSessionIsReady() async throws {
        let connector = FakeConnector(script: [.fail(.network(code: URLError.notConnectedToInternet.rawValue))])
        let harness = TurnHarness(connector: connector)
        try await harness.orchestrator.start(conversationID: harness.conversationID, waitsForConnection: false)
        #expect(await harness.orchestrator.state == .listening)
        try await waitUntil("retry scheduled") { harness.clock.sleeperCount > 0 }

        await harness.orchestrator.handle(.final(harness.utterance("Hello?", from: 0, to: 1)))
        #expect(await harness.snapshot().queuedUtterances == 1)
        harness.clock.advance(by: .seconds(1))
        let socket = try await connector.socket(0)
        try await harness.waitForSent("response.create", on: socket)
        #expect(socket.sentEvents.map(\.type) == ["session.update", "conversation.item.create", "response.create"])
    }

    @Test func aConnectionThatCantOpenReportsAnError() async throws {
        let connector = FakeConnector(script: [.fail(.handshakeFailed(status: 400))])
        let harness = TurnHarness(connector: connector)
        await #expect(throws: TurnOrchestrator.OrchestratorError.self) {
            try await harness.orchestrator.start()
        }
        guard case .error(let failure) = await harness.orchestrator.state else {
            Issue.record("Expected an error state")
            return
        }
        #expect(failure.kind == .connection)
        // Still recording: `connect()` retries.
        try await harness.orchestrator.connect()
        _ = try await connector.socket(0)
        try await harness.waitForState(.listening)
    }

    // MARK: Failures and timeouts

    @Test func aFailedResponseIsReported() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(ServerEvents.responseDone("resp_1", status: .failed))
        try await waitUntil("error") {
            if case .error(let failure) = await harness.orchestrator.state { failure.kind == .response } else { false }
        }
        // The user speaking again moves on.
        await harness.orchestrator.handle(.partial(text: "Hel", range: .instant(.seconds(3))))
        try await harness.waitForState(.userSpeaking)
    }

    @Test func aResponseThatNeverStartsTimesOut() async throws {
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
        try await harness.waitForSent("response.cancel", on: socket)
    }

    // MARK: Lifecycle

    @Test func stoppingCancelsTheReplyAndClosesTheConversation() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Long question", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 400))
        try await harness.waitForState(.agentSpeaking)

        await harness.orchestrator.stop()
        #expect(socket.sentEvents.contains(.responseCancel(responseID: "resp_1")))
        #expect(socket.closeCode == .normalClosure)
        #expect(await harness.orchestrator.state == .paused)
        #expect(await harness.snapshot().conversationID == nil)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["stopped"])
        let calls = try #require(harness.recording?.calls)
        #expect(calls.first == .begin(harness.conversationID))
        #expect(calls.suffix(2) == [.finish(harness.conversationID), .flush])

        // Events after the stop are ignored, and a new conversation starts.
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 100))
        let next = ConversationID()
        try await harness.orchestrator.start(conversationID: next)
        _ = try await harness.connector.socket(1)
        #expect(await harness.snapshot().conversationID == next)
        #expect(await harness.snapshot().usage == RealtimeUsageTotals())
    }

    @Test func settingsChangesFollowTheSession() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        harness.settings.update { $0.voice = .rex }
        try await waitUntil("debounce armed") { harness.clock.sleeperCount > 0 }
        harness.clock.advance(by: .milliseconds(400))
        try await harness.waitForSent("session.update", count: 2, on: socket)
    }

    @Test func leavingTheForegroundFlushesTheTranscript() async throws {
        let harness = TurnHarness()
        _ = try await harness.start()
        await harness.orchestrator.appPhaseDidChange(AppPhaseTransition(from: .active, to: .background))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.calls.last == .flush)
    }
}

// MARK: - Helpers

@Suite("Turn helpers")
struct TurnHelperTests {
    @Test(arguments: [
        (0.0, ""),
        (0.5, "The Golden Gate"),
        (0.4, "The Golden"),
        (0.26, "The"),
        (1.0, "The Golden Gate Bridge opened."),
        (0.02, ""),
    ])
    func heardPrefixCutsAtAWordBoundary(fraction: Double, expected: String) {
        let text = "The Golden Gate Bridge opened."
        #expect(TurnOrchestrator.heardPrefix(of: text, fraction: fraction) == expected)
    }

    @Test func rollingLatencyKeepsTheLatestWindow() throws {
        var latency = RollingLatency(capacity: 3)
        #expect(latency.p50 == nil)
        for milliseconds in [100, 200, 300, 900] {
            latency.add(.milliseconds(milliseconds))
        }
        #expect(latency.samples == [.milliseconds(200), .milliseconds(300), .milliseconds(900)])
        #expect(latency.totalCount == 4)
        #expect(latency.last == .milliseconds(900))
        #expect(latency.p50 == .milliseconds(300))
        let p95 = try #require(latency.p95)
        #expect(abs(p95.milliseconds - 840) < 0.001)
    }

    @Test func theHUDShowsLatencyPercentilesAndUsage() {
        var snapshot = TurnSnapshot(state: .agentSpeaking, connection: .connected, queuedUtterances: 0)
        var readout = TurnHUDReadout(snapshot)
        #expect(readout.value(for: "EOU → audio") == "–")
        #expect(readout.value(for: "Turn") == "agentSpeaking")

        var latency = TurnLatencyStatistics()
        for milliseconds in [600, 700, 650, 900] {
            latency.recordFirstAudio(.milliseconds(milliseconds))
        }
        latency.recordTurn(.milliseconds(2_400))
        snapshot.latency = latency
        snapshot.usage.add(.init(inputTokens: 412, outputTokens: 96, totalTokens: 508))
        snapshot.queuedUtterances = 2
        snapshot.connection = .reconnecting(attempt: 3)
        readout = TurnHUDReadout(snapshot)
        #expect(readout.value(for: "EOU → audio") == "last 900 · p50 675 · p95 870 ms (n=4)")
        #expect(readout.value(for: "Turn time") == "last 2400 · p50 2400 · p95 2400 ms (n=1)")
        #expect(readout.value(for: "Tokens") == "412 in · 96 out · 1 resp")
        #expect(readout.value(for: "Turn") == "agentSpeaking (2 queued)")
        #expect(readout.value(for: "Realtime") == "reconnecting (3)")
    }

    @Test func usageTotalsAddUp() {
        var totals = RealtimeUsageTotals()
        totals.add(.init(inputTokens: 10, outputTokens: 5, totalTokens: 15))
        totals.add(.init(inputTokens: 1, outputTokens: 2))
        totals.add(nil)
        #expect(totals.responses == 3)
        #expect(totals.inputTokens == 11)
        #expect(totals.outputTokens == 7)
        #expect(totals.totalTokens == 18)
    }
}

extension RealtimeClient.ConnectionState {
    fileprivate var isConnected: Bool { self == .connected }
}
