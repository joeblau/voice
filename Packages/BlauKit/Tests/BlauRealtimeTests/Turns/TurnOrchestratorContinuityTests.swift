import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// Long sessions (#39): resuming after a drop, renewing before the
/// 120-minute limit, reseeding a new server conversation. Everything runs on
/// the harness's `ManualClock`, so hours pass in milliseconds.
@Suite("Turn orchestrator: long sessions")
struct TurnOrchestratorContinuityTests {
    /// Sessions renewed after 10 minutes (deadline 12), so the timing tests
    /// stay readable.
    static let shortSessions = TurnOrchestrator.Configuration(
        continuity: .init(
            rolloverAfter: .seconds(600), rolloverDeadline: .seconds(720), tokenRefreshLead: .seconds(60),
            rolloverRetryInterval: .seconds(60)))

    // MARK: The 120-minute limit

    @Test func aTwoAndAHalfHourSessionRollsOverSeamlessly() async throws {
        let harness = TurnHarness(sessionTimers: true)
        let updates = StreamCollector(harness.orchestrator.updates(bufferingPolicy: .unbounded))
        defer { updates.cancel() }
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")

        // A question every five minutes for two and a half hours.
        var minute = 0
        var turn = 0
        var renewedAtMinute: Int?
        while minute < 150 {
            turn += 1
            try await harness.converse(
                "Question \(turn)", at: Double(minute * 60), reply: "Answer \(turn).", id: "\(turn)")
            let next = minute + 5
            if minute < 108, next >= 108 {
                // Two minutes before the renewal a fresh client secret is
                // minted, while the session is still in use.
                let requests = harness.tokens.requests
                harness.clock.advance(by: .seconds((108 - minute) * 60))
                minute = 108
                try await waitUntil("secret minted ahead") { harness.tokens.requests > requests }
                #expect(harness.connector.sockets.count == 1)
            }
            harness.clock.advance(by: .seconds((next - minute) * 60))
            minute = next
            if renewedAtMinute == nil, minute >= 110 {
                // Renewed at 110 minutes, between turns.
                let second = try await harness.connector.socket(1)
                try await harness.waitForSent("session.update", on: second)
                try await waitUntil("renewed") { await harness.snapshot().session.phase == .live }
                renewedAtMinute = minute
                second.push(ServerEvents.conversationCreated("conv_2"))
                try await harness.waitForEndpoint(conversation: "conv_2")
            }
        }

        let snapshot = await harness.snapshot()
        #expect(turn == 30)
        #expect(snapshot.completedTurns == 30)
        #expect(renewedAtMinute == 110)
        #expect(snapshot.session.rollovers == 1)
        #expect(snapshot.session.reseeds == 1)
        #expect(snapshot.session.resumptions == 0)
        #expect(snapshot.session.phase == .live)
        // The current session started at 110 minutes.
        #expect(snapshot.session.sessionAge == .seconds(40 * 60))
        // Never an error, never a lost utterance: every question was
        // answered, and the transcript has all 60 utterances in order.
        #expect(!updates.states.contains { if case .error = $0 { true } else { false } })
        #expect(snapshot.queuedUtterances == 0)
        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored.map(\.text))
        #expect(stored.count == 60)
        #expect(stored.prefix(2) == ["Question 1", "Answer 1."])
        #expect(stored.suffix(2) == ["Question 30", "Answer 30."])

        // The old connection was closed by Blau, not by the server's limit,
        // and the new one started a new conversation.
        #expect(first.closeCode == .normalClosure)
        #expect(harness.connector.urls == [.realtimeTest, .realtimeTest])
        let second = try await harness.connector.socket(1)
        // It was given the conversation again: the session (instructions,
        // ProfileBlock), a note, then the last 8 exchanges, then turn 23.
        let types = second.sentEvents.map(\.type)
        #expect(types.prefix(1) == ["session.update"])
        #expect(types.dropFirst().prefix(17).allSatisfy { $0 == "conversation.item.create" })
        guard case .conversationItemCreate(.message(let note), _) = second.sentEvents[1] else {
            Issue.record("Expected the reseed note")
            return
        }
        #expect(note.role == .system)
        #expect(second.sentUserTexts.prefix(9) == ArraySlice((15...23).map { "Question \($0)" }))
        #expect(second.sentAssistantTexts.prefix(8) == ArraySlice((15...22).map { "Answer \($0)." }))
        if case .sessionUpdate(let session) = second.sentEvents[0] {
            #expect(session.resumption == .init(enabled: true))
        }
        #expect(harness.signposts.events.filter { $0 == "realtime.rollover" }.count == 1)
    }

    @Test func renewalsCanResumeTheSameConversationInstead() async throws {
        var configuration = Self.shortSessions
        configuration.continuity.resumesAtRollover = true
        let harness = TurnHarness(configuration: configuration, sessionTimers: true)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")

        // Turns every five minutes for 25 minutes: renewed at 10 and 20.
        var turn = 0
        var handled = 0
        for minute in stride(from: 0, to: 25, by: 5) {
            turn += 1
            try await harness.converse("Q\(turn)", at: Double(minute * 60), reply: "A\(turn).", id: "\(turn)")
            harness.clock.advance(by: .seconds(5 * 60))
            let renewals = (minute + 5) / 10
            if renewals > handled {
                handled = renewals
                let socket = try await harness.connector.socket(renewals)
                try await harness.waitForSent("session.update", on: socket)
                #expect(await harness.snapshot().session.phase == .resuming)
                socket.push(ServerEvents.conversationCreated("conv_1"))
                socket.push(ServerEvents.replayed(.userText("Q\(turn)", id: "item_q\(turn)")))
                socket.push(ServerEvents.replayed(.assistantText("A\(turn).", id: "item_a\(turn)")))
                socket.push(ServerEvents.sessionUpdated)
                try await waitUntil("resumed") { await harness.snapshot().session.phase == .live }
            }
        }
        let snapshot = await harness.snapshot()
        #expect(snapshot.completedTurns == 5)
        #expect(snapshot.session.rollovers == 2)
        #expect(snapshot.session.resumptions == 2)
        #expect(snapshot.session.reseeds == 0)
        let resumed = RealtimeEndpoint.url(.realtimeTest, conversationID: "conv_1")
        #expect(harness.connector.urls == [.realtimeTest, resumed, resumed])
        // Nothing replayed by the server is sent again.
        let last = try await harness.connector.socket(2)
        #expect(
            last.sentEvents.map(\.type).prefix(3) == ["session.update", "conversation.item.create", "response.create"])
        #expect(last.sentUserTexts == ["Q5"])
    }

    @Test func theRenewalWaitsForTheTurnInProgress() async throws {
        let harness = TurnHarness(configuration: Self.shortSessions, sessionTimers: true)
        let first = try await harness.start()
        harness.clock.advance(by: .seconds(570))

        harness.audio.setIdle(false)
        await harness.orchestrator.handle(.final(harness.utterance("Tell me a story", from: 570, to: 572)))
        try await harness.waitForSent("response.create", on: first)
        let tag = first.turnTag()
        first.push(ServerEvents.responseCreated("resp_1", turn: tag))
        first.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        first.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 400))
        first.push(ServerEvents.transcript("item_1", response: "resp_1", "Once upon a time"))
        try await harness.waitForState(.agentSpeaking)

        // Ten minutes: due, but Grok is talking.
        harness.clock.advance(by: .seconds(60))
        try await waitUntil("due") { await harness.orchestrator.rolloverDue }
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.connector.sockets.count == 1)

        // The reply finishes and plays out: now it goes.
        first.push(ServerEvents.audioDone("item_1", response: "resp_1"))
        first.push(ServerEvents.transcriptDone("item_1", response: "resp_1", "Once upon a time"))
        first.push(ServerEvents.responseDone("resp_1"))
        try await waitUntil("response done") { await harness.snapshot().completedTurns == 1 }
        #expect(harness.connector.sockets.count == 1)
        harness.audio.setIdle(true)
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        #expect(first.cancelledResponses.isEmpty)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["completed"])
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Tell me a story", "Once upon a time"])
    }

    @Test func atTheDeadlineTheRenewalCutsTheTurnShort() async throws {
        let harness = TurnHarness(configuration: Self.shortSessions, sessionTimers: true)
        let first = try await harness.start()
        harness.clock.advance(by: .seconds(590))
        harness.audio.setIdle(false)
        await harness.orchestrator.handle(.final(harness.utterance("Keep talking", from: 590, to: 592)))
        try await harness.waitForSent("response.create", on: first)
        first.push(ServerEvents.responseCreated("resp_1", turn: first.turnTag()))
        first.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        first.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 400))
        first.push(ServerEvents.transcript("item_1", response: "resp_1", "Here is a very long answer"))
        try await harness.waitForState(.agentSpeaking)

        // Still talking at 12 minutes: renewed anyway, before the server's
        // own limit; what arrived of the reply is kept.
        harness.clock.advance(by: .seconds(140))
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        #expect(first.closeCode == .normalClosure)
        try await waitUntil("dropped") { harness.signposts.endMessages(of: "realtime.turn") == ["dropped"] }
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Keep talking", "Here is a very long answer"])
        // The new conversation knows the cut exchange.
        try await waitUntil("reseeded") { second.sentUserTexts == ["Keep talking"] }
        #expect(second.sentAssistantTexts == ["Here is a very long answer"])
        #expect(await harness.snapshot().session.rollovers == 1)
    }

    @Test func noClientSecretMeansTheOldSessionIsKeptForNow() async throws {
        let harness = TurnHarness(configuration: Self.shortSessions, sessionTimers: true)
        _ = try await harness.start()
        harness.tokens.failNext(XAIError.rateLimited(retryAfter: nil), XAIError.rateLimited(retryAfter: nil))

        harness.clock.advance(by: .seconds(540))
        try await waitUntil("refresh tried") { harness.tokens.requests == 2 }
        harness.clock.advance(by: .seconds(60))
        try await waitUntil("renewal tried") { harness.tokens.requests == 3 }
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.connector.sockets.count == 1)
        #expect(await harness.snapshot().session.phase == .live)

        // A minute later the secret can be minted: renewed.
        try await waitUntil("retry armed") { harness.clock.sleeperCount >= 2 }
        harness.clock.advance(by: .seconds(60))
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        #expect(await harness.snapshot().session.rollovers == 1)
    }

    @Test func maxDurationRenewsAtOnceWithANewConversation() async throws {
        let harness = TurnHarness()
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Hello", at: 0, reply: "Hi.", id: "1")

        first.push(ServerEvents.maxDuration)
        let second = try await harness.connector.socket(1)
        // Never resumes the conversation the server ended.
        #expect(second.url == .realtimeTest)
        try await waitUntil("reseeded") { second.sentAssistantTexts == ["Hi."] }
        #expect(second.sentUserTexts == ["Hello"])
        let snapshot = await harness.snapshot()
        #expect(snapshot.session.rollovers == 1)
        #expect(snapshot.session.reseeds == 1)
        try await harness.converse("Still there?", at: 30, reply: "Yes.", id: "2")
        if case .error = await harness.orchestrator.state { Issue.record("Unexpected error state") }
    }

    // MARK: Dropped connections

    @Test func aDropMidResponseResumesAndDeliversTheQueuedTurns() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Remember the launch is on the 14th", at: 0, reply: "Noted.", id: "1")

        // A reply is playing when the network drops.
        await harness.orchestrator.handle(.final(harness.utterance("What's the plan?", from: 10, to: 11)))
        try await harness.waitForSent("response.create", count: 2, on: first)
        first.push(ServerEvents.responseCreated("resp_2", turn: first.turnTag(1)))
        first.push(ServerEvents.itemAdded("item_2", response: "resp_2"))
        first.push(ServerEvents.audio("item_2", response: "resp_2", milliseconds: 300))
        first.push(ServerEvents.transcript("item_2", response: "resp_2", "First we"))
        try await harness.waitForState(.agentSpeaking)
        connector.enqueue(.fail(.network(code: URLError.networkConnectionLost.rawValue)))
        first.fail()

        // "Reconnecting…", without losing the transcript.
        try await waitUntil("reconnecting") { await harness.snapshot().session.phase == .reconnecting }
        #expect(await harness.snapshot().session.isReconnecting)
        try await harness.waitForState(.listening)

        // ASR keeps going: what the user says is stored and queued.
        await harness.orchestrator.handle(.final(harness.utterance("Are you still there?", from: 20, to: 21)))
        await harness.orchestrator.handle(.final(harness.utterance("And what about the budget?", from: 25, to: 27)))
        #expect(await harness.snapshot().queuedUtterances == 2)

        // The reconnect resumes the conversation.
        try await waitUntil("backing off") { harness.clock.sleeperCount > 0 }
        harness.clock.advance(by: .milliseconds(500))
        let second = try await connector.socket(1)
        #expect(second.url == RealtimeEndpoint.url(.realtimeTest, conversationID: "conv_1"))
        try await harness.waitForSent("session.update", on: second)
        try await waitUntil("resuming") { await harness.snapshot().session.phase == .resuming }
        #expect(await harness.snapshot().session.isReconnecting)
        // Nothing goes out until the server shows what it kept.
        #expect(second.sentEvents.map(\.type) == ["session.update"])

        second.push(ServerEvents.conversationCreated("conv_1"))
        second.push(ServerEvents.replayed(.userText("Remember the launch is on the 14th", id: "i1")))
        second.push(ServerEvents.replayed(.assistantText("Noted.", id: "i2")))
        second.push(ServerEvents.replayed(.userText("What's the plan?", id: "i3")))
        second.push(ServerEvents.replayed(.assistantText("First we", id: "i4")))
        second.push(ServerEvents.sessionUpdated)

        // The queued turns go out, in order, with one response; no reseed.
        try await harness.waitForSent("response.create", on: second)
        #expect(
            second.sentEvents.map(\.type) == [
                "session.update", "conversation.item.create", "conversation.item.create", "response.create",
            ])
        #expect(second.sentUserTexts == ["Are you still there?", "And what about the budget?"])
        for event in ServerEvents.reply(
            "Yes, and the budget is fine.", response: "resp_3", item: "item_3", turn: second.turnTag())
        {
            second.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 2 }
        try await harness.waitForState(.listening)

        let snapshot = await harness.snapshot()
        #expect(snapshot.session.phase == .live)
        #expect(snapshot.session.resumptions == 1)
        #expect(snapshot.session.reseeds == 0)
        #expect(snapshot.queuedUtterances == 0)
        #expect(TurnHUDReadout(snapshot).value(for: "Session") == "live · 0 min · 1 resumed")
        await harness.orchestrator.waitUntilSettled()
        #expect(
            harness.recording?.stored.map(\.text) == [
                "Remember the launch is on the 14th", "Noted.", "What's the plan?", "First we",
                "Are you still there?", "And what about the budget?", "Yes, and the budget is fine.",
            ])
    }

    @Test func aTurnLostBeforeItsReplyIsntSentTwiceToAResumedConversation() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        await harness.orchestrator.handle(.final(harness.utterance("What's the weather?", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: first)
        first.push(ServerEvents.responseCreated("resp_1", turn: first.turnTag()))
        first.fail()

        let second = try await connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        // The server had the question, and a reply that never reached us.
        second.push(ServerEvents.conversationCreated("conv_1"))
        second.push(ServerEvents.replayed(.userText("What's the weather?", id: "item_1")))
        second.push(ServerEvents.replayed(.assistantText("It's sunny.", id: "item_2")))
        second.push(ServerEvents.sessionUpdated)

        try await harness.waitForSent("response.create", on: second)
        #expect(second.sentEvents.map(\.type) == ["session.update", "conversation.item.delete", "response.create"])
        #expect(second.sentEvents.contains(.conversationItemDelete(itemID: "item_2")))
        #expect(second.sentUserTexts.isEmpty)
        for event in ServerEvents.reply(
            "Sunny, 24 degrees.", response: "resp_2", item: "item_3", turn: second.turnTag())
        {
            second.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 1 }
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["What's the weather?", "Sunny, 24 degrees."])
    }

    @Test func aRefusedResumptionReseedsBeforeTheQueuedTurns() async throws {
        let connector = FakeConnector()
        let topic = RealtimeTopicContext(title: "Launch plan", summary: "- Launch on the 14th")
        let harness = TurnHarness(connector: connector, reseedContext: StaticRealtimeReseedContext(topic))
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("When is the launch?", at: 0, reply: "On the 14th.", id: "1")

        connector.enqueue(.fail(.network(code: URLError.networkConnectionLost.rawValue)))
        first.fail()
        try await waitUntil("backing off") { harness.clock.sleeperCount > 0 }
        await harness.orchestrator.handle(.final(harness.utterance("Can we move it?", from: 20, to: 21)))
        harness.clock.advance(by: .milliseconds(500))
        let second = try await connector.socket(1)
        try await harness.waitForSent("session.update", on: second)

        // The history expired: the server starts a new conversation.
        second.push(ServerEvents.conversationCreated("conv_9"))
        try await harness.waitForSent("response.create", on: second)
        #expect(
            second.sentEvents.map(\.type) == [
                "session.update", "conversation.item.create", "conversation.item.create",
                "conversation.item.create", "conversation.item.create", "response.create",
            ])
        guard case .conversationItemCreate(.message(let note), _) = second.sentEvents[1] else {
            Issue.record("Expected the reseed note")
            return
        }
        #expect(note.role == .system)
        #expect(note.text.contains("Current topic: Launch plan"))
        #expect(note.text.contains("- Launch on the 14th"))
        // The last exchange, then the queued utterance as the new turn.
        #expect(second.sentUserTexts == ["When is the launch?", "Can we move it?"])
        #expect(second.sentAssistantTexts == ["On the 14th."])
        try await harness.waitForEndpoint(conversation: "conv_9")
        let snapshot = await harness.snapshot()
        #expect(snapshot.session.reseeds == 1)
        #expect(snapshot.session.resumptions == 0)
        #expect(snapshot.session.phase == .live)
        // The HUD's cost estimate (#71) bills every user text Grok received:
        // the first turn, the reseeded copy of it and the queued turn.
        try await waitUntil("text inputs counted") { await harness.snapshot().usage.textInputs == 3 }
    }

    @Test func aResumptionThatIsNeverConfirmedTimesOutAndReseeds() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Hello", at: 0, reply: "Hi.", id: "1")

        first.fail()
        let second = try await connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        try await waitUntil("resuming") { await harness.snapshot().session.phase == .resuming }
        await harness.elapse(.seconds(5))
        try await waitUntil("reseeded") { second.sentAssistantTexts == ["Hi."] }
        #expect(await harness.snapshot().session.phase == .live)
        #expect(await harness.snapshot().session.reseeds == 1)
    }

    @Test func anUpgradeRefusedForTheConversationStartsANewOne() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Hello", at: 0, reply: "Hi.", id: "1")

        // The server doesn't know the conversation any more.
        connector.enqueue(.fail(.handshakeFailed(status: 404)))
        first.fail()
        let second = try await connector.socket(1)
        #expect(second.url == .realtimeTest)
        #expect(connector.urls[1] == RealtimeEndpoint.url(.realtimeTest, conversationID: "conv_1"))
        try await waitUntil("reseeded") { second.sentAssistantTexts == ["Hi."] }
        try await harness.converse("Are you back?", at: 30, reply: "Yes.", id: "2")
        #expect(await harness.snapshot().session.reseeds == 1)
    }

    @Test func aConversationIdleTooLongIsntResumed() async throws {
        let connector = FakeConnector()
        let harness = TurnHarness(connector: connector)
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Hello", at: 0, reply: "Hi.", id: "1")

        // Half an hour without a word, then the connection drops.
        harness.clock.advance(by: .seconds(30 * 60))
        connector.enqueue(.fail(.network(code: URLError.notConnectedToInternet.rawValue)))
        first.fail()
        try await waitUntil("backing off") { harness.clock.sleeperCount > 0 }
        try await harness.waitForEndpoint(conversation: nil)
        harness.clock.advance(by: .milliseconds(500))
        let second = try await connector.socket(1)
        #expect(second.url == .realtimeTest)
        try await waitUntil("reseeded") { second.sentAssistantTexts == ["Hi."] }
    }

    @Test func aNewConversationNeverResumesThePreviousOne() async throws {
        let harness = TurnHarness()
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        try await harness.converse("Hello", at: 0, reply: "Hi.", id: "1")
        await harness.orchestrator.stop()

        try await harness.orchestrator.start()
        let second = try await harness.connector.socket(1)
        #expect(second.url == .realtimeTest)
        try await harness.waitForSent("session.update", on: second)
        // A new conversation starts empty: no reseed.
        await harness.orchestrator.waitUntilSettled()
        #expect(second.sentEvents.map(\.type) == ["session.update"])
        #expect(await harness.snapshot().session == RealtimeSessionContinuity(phase: .live))
    }
}

// MARK: - Helpers

extension ServerEvents {
    static func conversationCreated(_ id: String) -> RealtimeServerEvent {
        .conversationCreated(.init(conversation: .init(id: id, object: "realtime.conversation")))
    }

    /// History a resumed connection replays.
    static func replayed(_ item: RealtimeItem) -> RealtimeServerEvent {
        .conversationItemCreated(.init(item: item))
    }

    static let sessionUpdated = RealtimeServerEvent.sessionUpdated(
        .init(session: RealtimeSession(turnDetection: .manual, resumption: .init(enabled: true))))

    static let maxDuration = RealtimeServerEvent.error(
        .init(
            error: .init(type: .maxDuration, code: "max_duration", message: "Maximum conversation duration exceeded.")))
}

extension FakeSocket {
    /// The assistant texts sent with `conversation.item.create` (a reseed).
    var sentAssistantTexts: [String] {
        sentEvents.compactMap { event in
            guard case .conversationItemCreate(.message(let message), _) = event, message.role == .assistant else {
                return nil
            }
            return message.text
        }
    }
}

extension TurnHarness {
    /// One whole exchange on the newest connection: the user's final, then
    /// a complete spoken reply, played out.
    func converse(_ text: String, at seconds: Double, reply: String, id: String) async throws {
        let socket = try #require(connector.sockets.last)
        let requests = socket.sentEvents.filter { $0.type == "response.create" }.count
        let completed = await snapshot().completedTurns
        await orchestrator.handle(.final(utterance(text, from: seconds, to: seconds + 1.5)))
        try await waitForSent("response.create", count: requests + 1, on: socket)
        for event in ServerEvents.reply(
            reply, response: "resp_\(id)", item: "item_\(id)", turn: socket.turnTag(requests))
        {
            socket.push(event)
        }
        try await waitUntil("turn \(id) answered") { await snapshot().completedTurns == completed + 1 }
        try await waitForState(.listening)
    }

    /// Waits until the client's next connection resumes `conversation`
    /// (or starts a new one, for `nil`).
    func waitForEndpoint(
        conversation: String?, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("endpoint \(conversation ?? "new")", sourceLocation: sourceLocation) {
            await RealtimeEndpoint.conversationID(in: client.endpoint) == conversation
        }
    }
}
