import BlauAudio
import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

/// Offline mode (#80): the transcript keeps going while the network is
/// gone, utterances queue with a visible state, and everything recovers on
/// reconnect, or is discarded at the user's request. The airplane-mode
/// acceptance test runs here against a real `RealtimeClient` over fake
/// sockets on a manual clock (no network): the device loses its connection
/// mid-conversation, the client's retries run out, the user keeps talking,
/// and the network comes back.
@Suite("Turn orchestrator: offline mode")
struct TurnOrchestratorOfflineTests {
    static let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)

    /// Advances the manual clock through the client's reconnect backoff
    /// until it gives up (`disconnected(error)`).
    static func driveUntilTheClientGivesUp(_ harness: TurnHarness) async throws {
        for _ in 0..<20 {
            if case .disconnected(_?) = await harness.client.state { return }
            try await waitUntil("a reconnect attempt waiting, or given up") {
                if case .disconnected(_?) = await harness.client.state { return true }
                return harness.clock.sleeperCount > 0
            }
            if case .disconnected(_?) = await harness.client.state { return }
            harness.clock.advance(by: .seconds(10))
        }
        Issue.record("The client never gave up")
    }

    // MARK: Airplane mode

    @Test func airplaneModeKeepsTheTranscriptGoingAndRecoversOnReconnect() async throws {
        let harness = TurnHarness()
        let first = try await harness.start()
        first.push(ServerEvents.conversationCreated("conv_1"))
        try await harness.waitForEndpoint(conversation: "conv_1")
        await harness.orchestrator.networkReachabilityChanged(true)
        try await harness.converse("Before the flight", at: 0, reply: "Have a good flight.", id: "1")
        #expect(await harness.snapshot().connectivity == .online)
        #expect(await harness.snapshot().issue == nil)

        // Airplane mode: the path goes away and the socket dies. Every
        // reconnect attempt fails until the client gives up.
        await harness.orchestrator.networkReachabilityChanged(false)
        for _ in 0..<RetryPolicy.realtimeReconnect.maximumAttempts {
            harness.connector.enqueue(.fail(Self.offline))
        }
        first.fail(Self.offline)
        try await waitUntil("connection lost") { await harness.snapshot().connection != .connected }
        #expect(await harness.snapshot().connectivity == .offline)

        // The user keeps talking: every utterance is stored and queued.
        let offlineTexts = ["First thought on the plane", "Second thought", "Third thought"]
        for (index, text) in offlineTexts.enumerated() {
            let start = 30 + Double(index) * 10
            await harness.orchestrator.handle(
                .partial(text: text, range: TimeRange(start: .seconds(start), end: .seconds(start + 1))))
            #expect(await harness.orchestrator.state == .userSpeaking)
            await harness.orchestrator.handle(.final(harness.utterance(text, from: start, to: start + 2)))
            #expect(await harness.orchestrator.state == .listening)
        }
        try await Self.driveUntilTheClientGivesUp(harness)

        var snapshot = await harness.snapshot()
        #expect(snapshot.queuedUtterances == 3)
        #expect(snapshot.connectivity == .offline)
        let issue = try #require(snapshot.issue)
        #expect(issue.code == .offline)
        #expect(issue.message.hasSuffix("3 messages are waiting to send."))
        #expect(issue.actions == [.discardQueued])
        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.text) == ["Before the flight", "Have a good flight."] + offlineTexts)
        #expect(snapshot.queuedUtteranceIDs == Array(stored.suffix(3).map(\.id)))
        #expect(harness.recording?.deferrals == [true])
        let attemptsWhileOffline = harness.connector.attempts

        // Airplane mode off: the orchestrator reconnects at once, resumes
        // the conversation and sends what waited, as one turn.
        await harness.orchestrator.networkReachabilityChanged(true)
        let second = try await harness.connector.socket(1)
        #expect(harness.connector.attempts == attemptsWhileOffline + 1)
        try await harness.waitForSent("session.update", on: second)
        #expect(second.url.absoluteString.contains("conversation_id=conv_1"))
        second.push(ServerEvents.conversationCreated("conv_1"))
        second.push(ServerEvents.sessionUpdated)
        try await harness.waitForSent("response.create", on: second)
        #expect(second.sentUserTexts == offlineTexts)
        #expect(second.sentEvents.filter { $0.type == "response.create" }.count == 1)
        for event in ServerEvents.reply(
            "Welcome back. Three thoughts noted.", response: "resp_2", item: "item_2", turn: second.turnTag())
        {
            second.push(event)
        }
        try await waitUntil("answered") { await harness.snapshot().completedTurns == 2 }
        try await harness.waitForState(.listening)

        snapshot = await harness.snapshot()
        #expect(snapshot.connectivity == .online)
        #expect(snapshot.issue == nil)
        #expect(snapshot.queuedUtterances == 0)
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.deferrals == [true, false])
        #expect(
            harness.recording?.stored.map(\.text)
                == ["Before the flight", "Have a good flight."] + offlineTexts + ["Welcome back. Three thoughts noted."]
        )
    }

    @Test func aDropWithTheNetworkStillThereShowsReconnecting() async throws {
        let harness = TurnHarness()
        let first = try await harness.start()
        await harness.orchestrator.networkReachabilityChanged(true)
        harness.connector.enqueue(.fail(.network(code: URLError.networkConnectionLost.rawValue)))
        first.fail()
        try await waitUntil("reconnecting") { await harness.snapshot().connectivity == .reconnecting }
        await harness.orchestrator.handle(.final(harness.utterance("Still there?", from: 5, to: 6)))
        let snapshot = await harness.snapshot()
        #expect(snapshot.issue?.code == .reconnecting)
        #expect(snapshot.issue?.message.hasSuffix("1 message is waiting to send.") == true)
        #expect(snapshot.issue?.actions == [.discardQueued])

        harness.clock.advance(by: .milliseconds(500))
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("response.create", on: second)
        #expect(await harness.snapshot().connectivity == .online)
        #expect(await harness.snapshot().issue == nil)
    }

    // MARK: Discarding

    @Test func discardedUtterancesStayInTheTranscriptButAreNeverSent() async throws {
        let connector = FakeConnector(script: [.fail(Self.offline)])
        let harness = TurnHarness(connector: connector)
        try await harness.orchestrator.start(conversationID: harness.conversationID, waitsForConnection: false)
        try await waitUntil("retry scheduled") { harness.clock.sleeperCount > 0 }

        await harness.orchestrator.handle(.final(harness.utterance("Note to self", from: 0, to: 1)))
        await harness.orchestrator.handle(.final(harness.utterance("Buy milk", from: 5, to: 6)))
        #expect(await harness.snapshot().queuedUtterances == 2)
        #expect(await harness.orchestrator.discardQueued() == 2)
        #expect(await harness.orchestrator.discardQueued() == 0)

        let snapshot = await harness.snapshot()
        #expect(snapshot.queuedUtterances == 0)
        #expect(snapshot.queuedUtteranceIDs.isEmpty)
        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(harness.recording?.stored)
        #expect(stored.map(\.text) == ["Note to self", "Buy milk"])
        #expect(snapshot.discardedUtteranceIDs == Set(stored.map(\.id)))

        // The connection comes back: nothing is sent for them.
        harness.clock.advance(by: .seconds(1))
        let socket = try await connector.socket(0)
        try await harness.waitForSent("session.update", on: socket)
        try await waitUntil("live") { await harness.snapshot().connectivity == .online }
        await harness.orchestrator.waitUntilSettled()
        #expect(socket.sentEvents.map(\.type) == ["session.update"])

        // The next thing the user says is answered on its own.
        await harness.orchestrator.handle(.final(harness.utterance("What's the time?", from: 20, to: 21)))
        try await harness.waitForSent("response.create", on: socket)
        #expect(socket.sentUserTexts == ["What's the time?"])
    }

    @Test func aReseedLeavesDiscardedUtterancesOut() async throws {
        let harness = TurnHarness()
        let first = try await harness.start()
        try await harness.converse("Plan the trip", at: 0, reply: "Sure, where to?", id: "1")
        await harness.orchestrator.networkReachabilityChanged(false)
        harness.connector.enqueue(.fail(Self.offline))
        first.fail(Self.offline)
        try await waitUntil("waiting to retry") { harness.clock.sleeperCount > 0 }
        await harness.orchestrator.handle(.final(harness.utterance("Never mind this", from: 20, to: 21)))
        #expect(await harness.orchestrator.discardQueued() == 1)

        harness.clock.advance(by: .seconds(1))
        let second = try await harness.connector.socket(1)
        try await waitUntil("live") { await harness.snapshot().session.phase == .live }
        await harness.orchestrator.waitUntilSettled()
        // A new server conversation, reseeded with the earlier exchange only.
        #expect(second.sentUserTexts == ["Plan the trip"])
        #expect(second.sentAssistantTexts == ["Sure, where to?"])
        #expect(!second.sentEvents.contains { $0.type == "response.create" })
    }

    // MARK: Retrying after giving up

    @Test func theConnectionIsTriedAgainAfterGivingUpWhileOnline() async throws {
        let harness = TurnHarness(retriesAfterGivingUp: true)
        let first = try await harness.start()
        await harness.orchestrator.networkReachabilityChanged(true)
        for _ in 0..<RetryPolicy.realtimeReconnect.maximumAttempts {
            harness.connector.enqueue(.fail(.handshakeFailed(status: 503)))
        }
        first.fail()
        try await Self.driveUntilTheClientGivesUp(harness)

        let snapshot = await harness.snapshot()
        guard case .unavailable(let issue) = snapshot.connectivity else {
            Issue.record("Expected unavailable, got \(snapshot.connectivity)")
            return
        }
        #expect(issue.code == .xaiServerError)
        #expect(issue.detail == "HTTP 503")
        #expect(snapshot.issue?.actions == [.retry])
        let attempts = harness.connector.attempts

        // The orchestrator's own retry, 30 s later.
        try await waitUntil("retry armed") { harness.clock.sleeperCount > 0 }
        harness.clock.advance(by: .seconds(30))
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        #expect(harness.connector.attempts == attempts + 1)
        try await waitUntil("online") { await harness.snapshot().connectivity == .online }
    }

    @Test func aKeyProblemWaitsForTheUser() async throws {
        let tokens = FakeTokenProvider(errors: [XAIError.invalidAPIKey(message: "Incorrect API key provided")])
        let harness = TurnHarness(tokens: tokens, retriesAfterGivingUp: true)
        await #expect(throws: TurnOrchestrator.OrchestratorError.self) {
            try await harness.orchestrator.start(conversationID: harness.conversationID)
        }
        let snapshot = await harness.snapshot()
        guard case .unavailable(let issue) = snapshot.connectivity else {
            Issue.record("Expected unavailable, got \(snapshot.connectivity)")
            return
        }
        #expect(issue.code == .invalidAPIKey)
        #expect(issue.severity == .blocking)
        #expect(issue.actions == [.updateAPIKey, .openXAIConsole])

        // Neither the network coming back nor time passing retries a key
        // problem: only the user can fix it.
        await harness.orchestrator.networkReachabilityChanged(false)
        await harness.orchestrator.networkReachabilityChanged(true)
        harness.clock.advance(by: .seconds(120))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.connector.attempts == 0)

        // Once the key is fixed, Try Again (`connect()`) works.
        try await harness.orchestrator.connect()
        _ = try await harness.connector.socket(0)
        try await waitUntil("online") { await harness.snapshot().connectivity == .online }
    }

    // MARK: Failures carry their catalog entries

    @Test func aFailedResponseReportsTheServersReason() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(
            .responseDone(
                .init(
                    response: RealtimeResponse(
                        id: "resp_1", status: .failed,
                        statusDetails: [
                            "type": "failed",
                            "error": [
                                "type": "rate_limit_error", "code": "rate_limit_exceeded", "message": "Slow down",
                            ],
                        ]))))
        try await waitUntil("failed") {
            if case .error = await harness.orchestrator.state { return true }
            return false
        }
        let issue = try #require(await harness.snapshot().issue)
        #expect(issue.code == .rateLimited)
        #expect(issue.detail == "Slow down")
    }

    @Test func aTimedOutResponseIsCataloged() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hello", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        await harness.elapse(.seconds(15))
        try await waitUntil("timed out") {
            if case .error = await harness.orchestrator.state { return true }
            return false
        }
        #expect(await harness.snapshot().issue?.code == .replyTimedOut)
    }
}
