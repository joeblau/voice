import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// A client wired to fakes: a `ManualClock`, scripted sockets, a fake token
/// provider and a recording signpost backend. No network, no real waiting.
struct ClientHarness {
    /// Backoff 1 s, 2 s, 4 s with no jitter; no keepalive or connect timeout
    /// unless a test turns them on.
    static let configuration = RealtimeClient.Configuration(
        connectTimeout: nil,
        keepAliveInterval: nil,
        reconnect: RetryPolicy(maximumAttempts: 4, initialDelay: .seconds(1), multiplier: 2, maximumDelay: .seconds(8))
    )

    let clock = ManualClock()
    let tokens: FakeTokenProvider
    let connector: FakeConnector
    let signposts = RecordingSignpostBackend()
    let recorder: RealtimeTranscriptRecorder
    let client: RealtimeClient
    let events: StreamCollector<RealtimeServerEvent>
    let states: StreamCollector<RealtimeClient.ConnectionState>

    init(
        configuration: RealtimeClient.Configuration = Self.configuration,
        script: [FakeConnector.Outcome] = [],
        tokenErrors: [any Error] = [],
        connector: (any RealtimeSocketConnecting)? = nil
    ) {
        tokens = FakeTokenProvider(errors: tokenErrors)
        self.connector = FakeConnector(script: script)
        recorder = RealtimeTranscriptRecorder(clock: clock)
        client = RealtimeClient(
            endpoint: .realtimeTest,
            tokenProvider: tokens,
            connector: connector ?? self.connector,
            clock: clock,
            configuration: configuration,
            signposter: Signposter(category: .realtime, backend: signposts),
            recorder: recorder,
            unitRandom: { 0.5 })
        events = StreamCollector(client.events)
        states = StreamCollector(client.states)
    }

    func state() async -> RealtimeClient.ConnectionState {
        await client.state
    }

    func waitForState(
        _ expected: RealtimeClient.ConnectionState, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("state \(expected)", sourceLocation: sourceLocation) { await client.state == expected }
    }

    /// Lets detached tasks (receive loops, reconnects) run until they settle.
    func settle() async throws {
        for _ in 0..<50 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("RealtimeClient: connecting and events")
struct RealtimeClientConnectionTests {
    @Test func connectsWithTheClientSecretAsSubprotocol() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()

        #expect(harness.connector.subprotocols == [["xai-client-secret.secret-1"]])
        #expect(harness.connector.urls == [.realtimeTest])
        #expect(await harness.state() == .connected)
        try await harness.states.waitForCount(2)
        #expect(harness.states.values == [.connecting(attempt: 1), .connected])
    }

    @Test func connectIsIdempotent() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        try await harness.client.connect()
        #expect(harness.connector.attempts == 1)
    }

    @Test func deliversServerEventsInOrderIncludingUnknownTypes() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        socket.push(TestEvents.conversationCreated)
        socket.push(TestEvents.future)
        socket.push(TestEvents.sessionCreated)
        try await harness.events.waitForCount(3)

        #expect(
            harness.events.values.map(\.type) == ["conversation.created", "response.hologram.delta", "session.created"])
        #expect(harness.events.values[1].isUnknown)
        #expect(await harness.state() == .connected)
    }

    @Test func sendsJSONTextFrames() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        try await harness.client.send(.conversationItemCreate(.userText("What's next?")))
        try await harness.client.send(.responseCreate())

        #expect(socket.sentEvents == [.conversationItemCreate(.userText("What's next?")), .responseCreate()])
        guard case .text(let text) = socket.sent.first else {
            Issue.record("Expected a text frame")
            return
        }
        #expect(try json(text)["type"] == "conversation.item.create")
    }

    @Test func audioGoesAsBase64JSONByDefault() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        try await harness.client.send(.inputAudioBufferAppend(Data([1, 2, 3])))

        #expect(socket.sent == [.text(#"{"audio":"AQID","type":"input_audio_buffer.append"}"#)])
    }

    @Test func audioGoesAsBinaryFramesWithBinaryTransport() async throws {
        var configuration = ClientHarness.configuration
        configuration.inputAudioTransport = .binary
        let harness = ClientHarness(configuration: configuration)
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        try await harness.client.send(.inputAudioBufferAppend(Data([1, 2, 3])))
        try await harness.client.send(.inputAudioBufferCommit)

        #expect(socket.sent == [.binary(Data([1, 2, 3])), .text(#"{"type":"input_audio_buffer.commit"}"#)])
    }

    @Test func binaryFramesFromTheServerBecomeAttributedAudioDeltas() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        socket.push(TestEvents.responseCreated)
        socket.push(
            #"{"type":"response.output_item.added","response_id":"resp_1","output_index":0,"item":{"id":"item_9","type":"message","role":"assistant","content":[]}}"#
        )
        socket.push(
            #"{"type":"response.content_part.added","response_id":"resp_1","item_id":"item_9","output_index":0,"content_index":0,"part":{"type":"audio"}}"#
        )
        socket.push(binary: Data([9, 8, 7, 6]))
        try await harness.events.waitForCount(4)

        #expect(
            harness.events.values[3]
                == .responseOutputAudioDelta(
                    .init(
                        responseID: "resp_1", itemID: "item_9", outputIndex: 0, contentIndex: 0,
                        audio: Data([9, 8, 7, 6]), isBinaryFrame: true)))
    }

    @Test func sendBeforeConnectThrowsNotConnected() async {
        let harness = ClientHarness()
        await #expect(throws: RealtimeClientError.notConnected) {
            try await harness.client.send(.responseCreate())
        }
    }

    @Test func disconnectClosesNormallyAndAllowsReconnecting() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        await harness.client.disconnect()

        #expect(socket.closeCode == .normalClosure)
        #expect(await harness.state() == .disconnected(nil))
        await #expect(throws: RealtimeClientError.notConnected) {
            try await harness.client.send(.responseCreate())
        }
        try await harness.client.connect()
        #expect(harness.connector.attempts == 2)
    }

    @Test func shutdownFinishesTheStreams() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let client = harness.client
        await client.shutdown()
        try await waitUntil("events finished") { harness.events.isFinished }
        try await waitUntil("states finished") { harness.states.isFinished }
        await #expect(throws: RealtimeClientError.cancelled) {
            try await client.connect()
        }
    }

    @Test func setEndpointAppliesToTheNextConnection() async throws {
        let harness = ClientHarness()
        let resumed = URL(string: "wss://api.x.ai/v1/realtime?model=m&conversation_id=conv_1")!
        await harness.client.setEndpoint(resumed)
        try await harness.client.connect()
        #expect(harness.connector.urls == [resumed])
    }
}

@Suite("RealtimeClient: auth and failures")
struct RealtimeClientAuthTests {
    @Test func refusedSecretIsInvalidatedAndAFreshOneTried() async throws {
        let harness = ClientHarness(script: [.fail(.handshakeFailed(status: 401)), .open])
        try await harness.client.connect()

        #expect(harness.tokens.invalidations == 1)
        #expect(harness.connector.subprotocols == [["xai-client-secret.secret-1"], ["xai-client-secret.secret-2"]])
        #expect(await harness.state() == .connected)
    }

    @Test func refusedTwiceIsUnauthorizedAndNotRetried() async throws {
        let harness = ClientHarness(script: [
            .fail(.handshakeFailed(status: 403)), .fail(.handshakeFailed(status: 403)),
        ])
        await #expect(throws: RealtimeClientError.unauthorized(status: 403)) {
            try await harness.client.connect()
        }
        #expect(harness.connector.attempts == 2)
        #expect(await harness.state() == .disconnected(.unauthorized(status: 403)))
        #expect(RealtimeClientError.unauthorized(status: 403).requiresUserAction)
    }

    @Test func keyProblemsFailAtOnceWithoutOpeningASocket() async throws {
        let harness = ClientHarness(tokenErrors: [XAIError.invalidAPIKey(message: nil)])
        await #expect(throws: RealtimeClientError.token(.invalidAPIKey(message: nil))) {
            try await harness.client.connect()
        }
        #expect(harness.connector.attempts == 0)
        #expect(RealtimeClientError.token(.invalidAPIKey(message: nil)).requiresUserAction)
    }

    @Test func transientTokenFailuresAreRetriedWithBackoff() async throws {
        let harness = ClientHarness(tokenErrors: [XAIError.network(code: URLError.notConnectedToInternet.rawValue)])
        let client = harness.client
        let connecting = Task { try await client.connect() }

        await harness.clock.waitForSleepers()
        #expect(harness.connector.attempts == 0)
        harness.clock.advance(by: .seconds(1))
        try await connecting.value

        #expect(harness.connector.attempts == 1)
        try await harness.states.waitFor(.connecting(attempt: 2))
    }

    @Test func aStalledUpgradeTimesOutAndIsRetried() async throws {
        var configuration = ClientHarness.configuration
        configuration.connectTimeout = .seconds(10)
        let harness = ClientHarness(configuration: configuration, script: [.hang, .open])
        let client = harness.client
        let connecting = Task { try await client.connect() }

        await harness.clock.waitForSleepers()  // the connect timeout
        harness.clock.advance(by: .seconds(10))
        await harness.clock.waitForSleepers()  // the backoff
        harness.clock.advance(by: .seconds(1))
        try await connecting.value

        #expect(harness.connector.attempts == 2)
        #expect(await harness.state() == .connected)
    }

    @Test func connectGivesUpAfterTheLastAttempt() async throws {
        var configuration = ClientHarness.configuration
        configuration.reconnect = RetryPolicy(maximumAttempts: 2, initialDelay: .seconds(1), maximumDelay: .seconds(1))
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(configuration: configuration, script: [.fail(offline), .fail(offline)])
        let client = harness.client
        let connecting = Task { try await client.connect() }

        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(1))

        await #expect(throws: offline) { try await connecting.value }
        #expect(harness.connector.attempts == 2)
        #expect(await harness.state() == .disconnected(offline))
    }
}

@Suite("RealtimeClient: reconnecting")
struct RealtimeClientReconnectTests {
    /// The acceptance criterion: after a network drop the client reconnects
    /// on its own, and events keep flowing on the same stream.
    @Test func reconnectsAfterANetworkDrop() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let first = try await harness.connector.socket(0)
        first.push(TestEvents.sessionCreated)
        try await harness.events.waitForCount(1)

        first.fail(.network(code: URLError.networkConnectionLost.rawValue))

        let second = try await harness.connector.socket(1)
        try await harness.waitForState(.connected)
        #expect(first.closeCode == .goingAway)
        try await harness.states.waitForCount(4)
        #expect(
            harness.states.values == [
                .connecting(attempt: 1), .connected, .reconnecting(attempt: 1), .connected,
            ])

        second.push(TestEvents.sessionCreated)
        try await harness.events.waitForCount(2)
        try await harness.client.send(.responseCreate())
        #expect(second.sentEvents == [.responseCreate()])
        #expect(first.sentEvents.isEmpty)

        #expect(harness.signposts.events.contains("realtime.drop"))
        #expect(harness.signposts.events.contains("realtime.reconnected"))
    }

    @Test func reconnectsWhenTheServerClosesTheSocket() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        try await harness.connector.socket(0).fail(.closed(code: .internalServerError, reason: "bye"))
        _ = try await harness.connector.socket(1)
        try await harness.waitForState(.connected)
    }

    @Test func sendsDuringAReconnectFailWithNotConnected() async throws {
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(script: [.open, .fail(offline)])
        try await harness.client.connect()
        try await harness.connector.socket(0).fail()
        await harness.clock.waitForSleepers()

        await #expect(throws: RealtimeClientError.notConnected) {
            try await harness.client.send(.responseCreate())
        }
    }

    @Test func backsOffExponentiallyBetweenFailedAttempts() async throws {
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(script: [.open, .fail(offline), .fail(offline), .open])
        try await harness.client.connect()
        try await harness.connector.socket(0).fail()

        // Attempt 1 is immediate and fails; attempt 2 waits 1 s.
        await harness.clock.waitForSleepers()
        #expect(harness.connector.attempts == 2)
        harness.clock.advance(by: .milliseconds(999))
        try await harness.settle()
        #expect(harness.connector.attempts == 2)
        harness.clock.advance(by: .milliseconds(1))

        // Attempt 2 fails; attempt 3 waits 2 s.
        try await waitUntil("attempt 3 scheduled") { harness.connector.attempts == 3 }
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(2))

        _ = try await harness.connector.socket(1)
        try await harness.waitForState(.connected)
        #expect(harness.connector.attempts == 4)
        try await harness.states.waitForCount(6)
        #expect(
            harness.states.values == [
                .connecting(attempt: 1), .connected, .reconnecting(attempt: 1), .reconnecting(attempt: 2),
                .reconnecting(attempt: 3), .connected,
            ])
    }

    @Test func reportsTheDropWhenReconnectingFails() async throws {
        var configuration = ClientHarness.configuration
        configuration.reconnect = RetryPolicy(maximumAttempts: 2, initialDelay: .seconds(1), maximumDelay: .seconds(1))
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(configuration: configuration, script: [.open, .fail(offline), .fail(offline)])
        try await harness.client.connect()
        try await harness.connector.socket(0).fail()

        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(1))
        try await harness.waitForState(.disconnected(offline))

        // A later connect starts over.
        try await harness.client.connect()
        #expect(await harness.state() == .connected)
    }

    @Test func doesNotReconnectWhenTurnedOff() async throws {
        var configuration = ClientHarness.configuration
        configuration.reconnectsAutomatically = false
        let harness = ClientHarness(configuration: configuration)
        try await harness.client.connect()
        let lost = RealtimeClientError.network(code: URLError.networkConnectionLost.rawValue)
        try await harness.connector.socket(0).fail(lost)

        try await harness.waitForState(.disconnected(lost))
        try await harness.settle()
        #expect(harness.connector.attempts == 1)
    }

    @Test func disconnectStopsAReconnectInProgress() async throws {
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(script: [.open, .fail(offline)])
        try await harness.client.connect()
        try await harness.connector.socket(0).fail()
        await harness.clock.waitForSleepers()

        await harness.client.disconnect()
        harness.clock.advance(by: .seconds(60))
        try await harness.settle()

        #expect(harness.connector.attempts == 2)
        #expect(await harness.state() == .disconnected(nil))
    }

    @Test func connectJoinsAReconnectInProgress() async throws {
        let offline = RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        let harness = ClientHarness(script: [.open, .fail(offline), .open])
        try await harness.client.connect()
        try await harness.connector.socket(0).fail()
        await harness.clock.waitForSleepers()

        let client = harness.client
        let joining = Task { try await client.connect() }
        try await harness.settle()
        harness.clock.advance(by: .seconds(1))
        try await joining.value

        #expect(harness.connector.attempts == 3)
        #expect(await harness.state() == .connected)
    }
}

@Suite("RealtimeClient: keepalive")
struct RealtimeClientKeepAliveTests {
    static var configuration: RealtimeClient.Configuration {
        var configuration = ClientHarness.configuration
        configuration.keepAliveInterval = .seconds(15)
        configuration.pongTimeout = .seconds(10)
        return configuration
    }

    @Test func pingsAnIdleConnection() async throws {
        let harness = ClientHarness(configuration: Self.configuration)
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        for expected in 1...3 {
            // Wait until the only timer is the next keepalive interval: the
            // previous ping's 10 s pong timeout is gone (the client waits for
            // it to stop before sleeping again). Moving the clock while that
            // timeout is still the sleeper would skip the interval.
            let clock = harness.clock
            try await waitUntil("next ping scheduled") { clock.sleeperDeadlines == [clock.uptime + .seconds(15)] }
            harness.clock.advance(by: .seconds(15))
            try await waitUntil("ping \(expected)") { socket.pings == expected }
        }
        #expect(harness.connector.attempts == 1)
        #expect(await harness.state() == .connected)
    }

    /// A connection that died without an error (no pong) is detected and
    /// replaced.
    @Test func aMissingPongCountsAsADrop() async throws {
        let harness = ClientHarness(configuration: Self.configuration)
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)
        socket.setPingBehavior(.ignore)

        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(15))
        try await waitUntil("ping sent") { socket.pings == 1 }
        await harness.clock.waitForSleepers()  // the pong timeout
        harness.clock.advance(by: .seconds(10))

        _ = try await harness.connector.socket(1)
        try await harness.waitForState(.connected)
        #expect(socket.closeCode == .goingAway)
        #expect(harness.recorder.transcript.entries.contains { $0.payload == .close(code: 1006, reason: nil) })
    }
}

@Suite("RealtimeClient: signposts")
struct RealtimeClientSignpostTests {
    @Test func connectIsAnInterval() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()

        #expect(harness.signposts.completedIntervals == ["realtime.connect"])
        #expect(harness.signposts.endMessages(of: "realtime.connect") == ["connected"])
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func failedConnectEndsTheInterval() async throws {
        let harness = ClientHarness(tokenErrors: [XAIError.missingAPIKey])
        _ = try? await harness.client.connect()

        #expect(harness.signposts.endMessages(of: "realtime.connect") == ["failed"])
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func eachReceivedEventIsAnIntervalNamedByItsType() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)

        socket.push(TestEvents.sessionCreated)
        socket.push(TestEvents.future)
        socket.push(binary: Data([1, 2]))
        try await harness.events.waitForCount(3)
        try await waitUntil("three event intervals") {
            harness.signposts.endMessages(of: "realtime.event").count == 3
        }

        #expect(
            harness.signposts.endMessages(of: "realtime.event") == [
                "session.created", "response.hologram.delta", "response.output_audio.delta",
            ])
        #expect(harness.signposts.openIntervals.isEmpty)
    }
}

@Suite("RealtimeClient: record and replay")
struct RealtimeClientReplayTests {
    @Test func recordsEveryFrameWithoutTheSecret() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let socket = try await harness.connector.socket(0)
        socket.push(TestEvents.sessionCreated)
        try await harness.events.waitForCount(1)
        try await harness.client.send(.conversationItemCreate(.userText("hi")))
        socket.push(binary: Data([1]))
        try await harness.events.waitForCount(2)
        await harness.client.disconnect()

        let transcript = harness.recorder.transcript
        #expect(transcript.entries.map(\.direction) == [.client, .server, .client, .server, .client])
        #expect(transcript.entries.first?.payload == .connect(url: URL.realtimeTest.absoluteString))
        #expect(transcript.entries.last?.payload == .close(code: 1000, reason: nil))
        let file = String(decoding: transcript.jsonLines(), as: UTF8.self)
        #expect(!file.contains("secret-1"))
        #expect(try transcript.clientEvents == [.conversationItemCreate(.userText("hi"))])
        #expect(transcript.serverEvents == harness.events.values)
    }

    /// A fixture session replays through the real client: in lockstep, each
    /// server frame waits for the client frames that preceded it.
    @Test(arguments: ["manual-text-turn", "function-call", "barge-in", "binary-audio", "mcp-tools"])
    func replaysAFixtureSession(fixture: String) async throws {
        let transcript = try Fixtures.transcript(fixture)
        var configuration = ClientHarness.configuration
        configuration.reconnectsAutomatically = false
        if fixture == "binary-audio" {
            configuration.inputAudioTransport = .binary
        }
        let connector = RealtimeReplayConnector(transcript: transcript)
        let harness = ClientHarness(configuration: configuration, connector: connector)
        try await harness.client.connect()

        for event in try transcript.clientEvents {
            try await harness.client.send(event)
        }
        let expected = transcript.serverEvents
        try await harness.events.waitForCount(expected.count)

        #expect(harness.events.values == expected)
        let socket = try #require(connector.sockets.first)
        #expect(socket.isExhausted)
        #expect(socket.sentEvents == (try transcript.clientEvents))
    }

    /// The drop in the fixture's first connection triggers a reconnect,
    /// which the replay answers with the second recorded connection.
    @Test func replaysADropAndAReconnect() async throws {
        let transcript = try Fixtures.transcript("drop-and-resume")
        let connections = transcript.connections
        let connector = RealtimeReplayConnector(transcript: transcript)
        let harness = ClientHarness(connector: connector)
        try await harness.client.connect()

        for event in try connections[0].clientEvents {
            try await harness.client.send(event)
        }
        try await waitUntil("second connection") { connector.sockets.count == 2 }
        try await harness.waitForState(.connected)
        for event in try connections[1].clientEvents {
            try await harness.client.send(event)
        }

        let expected = connections[0].serverEvents + connections[1].serverEvents
        try await harness.events.waitForCount(expected.count)
        #expect(harness.events.values == expected)
        try await harness.states.waitFor(.reconnecting(attempt: 1))
        #expect(connector.offeredSubprotocols == [["xai-client-secret.secret-1"], ["xai-client-secret.secret-1"]])
    }

    @Test func aRecordingReplaysToTheSameEvents() async throws {
        let original = ClientHarness()
        try await original.client.connect()
        let socket = try await original.connector.socket(0)
        try await original.client.send(.sessionUpdate(RealtimeSession(turnDetection: .manual)))
        socket.push(TestEvents.sessionCreated)
        try await original.events.waitForCount(1)
        try await original.client.send(.responseCreate())
        socket.push(TestEvents.responseCreated)
        socket.push(TestEvents.responseDone)
        try await original.events.waitForCount(3)
        await original.client.disconnect()

        let recorded = try RealtimeTranscript(jsonLines: original.recorder.transcript.jsonLines())
        var configuration = ClientHarness.configuration
        configuration.reconnectsAutomatically = false
        let replay = ClientHarness(
            configuration: configuration, connector: RealtimeReplayConnector(transcript: recorded))
        try await replay.client.connect()
        try await replay.client.send(.sessionUpdate(RealtimeSession(turnDetection: .manual)))
        try await replay.client.send(.responseCreate())
        try await replay.events.waitForCount(3)

        #expect(replay.events.values == original.events.values)
    }
}
