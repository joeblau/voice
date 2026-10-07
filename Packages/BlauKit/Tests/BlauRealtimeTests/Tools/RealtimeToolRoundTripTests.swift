import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// A real ``RealtimeClient`` over a replayed fixture session, with a
/// ``RealtimeToolRunner`` fed from its events, as the turn orchestrator
/// (#36) wires them. The replay runs in lockstep, so the server's reply to
/// a tool output only arrives once the runner has actually sent it.
private struct ToolSessionHarness {
    let transcript: RealtimeTranscript
    let connector: RealtimeReplayConnector
    let client: RealtimeClient
    let runner: RealtimeToolRunner
    let signposts = RecordingSignpostBackend()
    let received = CallLog<RealtimeServerEvent>()
    let pump: Task<Void, Never>

    init(fixture: String, tools: [any RealtimeFunctionTool]) throws {
        transcript = try Fixtures.transcript(fixture)
        connector = RealtimeReplayConnector(transcript: transcript)
        var configuration = ClientHarness.configuration
        configuration.reconnectsAutomatically = false
        let clock = ManualClock()
        client = RealtimeClient(
            endpoint: .realtimeTest, tokenProvider: FakeTokenProvider(), connector: connector, clock: clock,
            configuration: configuration, signposter: .disabled(.realtime))
        runner = RealtimeToolRunner(
            registry: try RealtimeToolRegistry(tools), sender: client, clock: clock,
            signposter: Signposter(category: .realtime, backend: signposts))
        let (client, runner, received) = (client, runner, received)
        pump = Task {
            for await event in client.events {
                received.append(event)
                await runner.handle(event)
            }
        }
    }

    var socket: RealtimeReplaySocket {
        get throws { try #require(connector.sockets.first) }
    }

    func waitForSent(_ count: Int) async throws {
        try await waitUntil("\(count) client frames") {
            (connector.sockets.first?.sentMessages.count ?? 0) >= count
        }
    }

    func finish() async {
        await client.shutdown()
        pump.cancel()
    }
}

@Suite("Function calling: fixture round trips")
struct RealtimeToolRoundTripTests {
    /// Acceptance criterion: the echo tool round trip against the recorded
    /// (hand-written) fixture. Blau declares the tool from the registry,
    /// the user asks, Grok speaks a filler and calls `echo`, the runner
    /// answers with the output and exactly one `response.create`, and Grok
    /// answers. Every frame Blau sends matches the fixture.
    @Test func echoToolRoundTrip() async throws {
        let harness = try ToolSessionHarness(fixture: "echo-tool", tools: [EchoTool()])
        let activity = StreamCollector(harness.runner.activity)
        let registry = await harness.runner.registry
        try await harness.client.connect()

        try await harness.client.send(.sessionUpdate(RealtimeSession(tools: registry.definitions)))
        try await harness.client.send(
            .conversationItemCreate(.userText("Test the echo tool with the words blue harbor.")))
        try await harness.client.send(.responseCreate())

        let expectedClient = try harness.transcript.clientEvents
        try await harness.waitForSent(expectedClient.count)
        let expectedServer = harness.transcript.serverEvents
        try await waitUntil("every server event") { harness.received.values.count >= expectedServer.count }

        let socket = try harness.socket
        #expect(socket.sentEvents == expectedClient)
        #expect(socket.isExhausted)
        #expect(harness.received.values == expectedServer)
        #expect(
            socket.sentEvents.suffix(2) == [
                .conversationItemCreate(.functionOutput(callID: "call_echo_001", output: #"{"text":"blue harbor"}"#)),
                .responseCreate(),
            ])
        try await activity.waitForCount(3)
        #expect(
            activity.values == [
                .started(callID: "call_echo_001", name: "echo"),
                .finished(callID: "call_echo_001", name: "echo", outcome: .succeeded),
                .followUpRequested(responseID: "resp_001"),
            ])
        #expect(harness.signposts.endMessages(of: "realtime.toolCall") == ["echo succeeded"])
        // The reply that used the result.
        let answer = harness.received.values.compactMap { event -> String? in
            if case .responseOutputAudioTranscriptDone(let done) = event, done.responseID == "resp_002" {
                done.transcript
            } else {
                nil
            }
        }
        #expect(answer == ["It came back as blue harbor, so the echo tool works."])
        #expect(await harness.runner.isIdle)
        await harness.finish()
    }

    /// Acceptance criterion: two parallel calls in one response get two
    /// outputs and a single `response.create`, against the `function-call`
    /// fixture.
    @Test func parallelCallsRoundTrip() async throws {
        let search = FakeSearchMemoryTool(results: [
            "launch": ["Launch is on the 14th"], "budget": ["Budget is capped at 20k"],
        ])
        let harness = try ToolSessionHarness(fixture: "function-call", tools: [search])
        let expectedClient = try harness.transcript.clientEvents
        try await harness.client.connect()

        // The fixture's own session.update and user turn.
        for event in expectedClient.prefix(3) {
            try await harness.client.send(event)
        }
        // Two outputs and one response.create, all sent by the runner.
        try await harness.waitForSent(6)
        // The follow-up reply (resp_002) arrives in response.
        try await waitUntil("follow-up reply") {
            harness.received.values.contains { event in
                if case .responseDone(let done) = event { done.response.id == "resp_002" } else { false }
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        let sent = try harness.socket.sentEvents
        #expect(sent.count == 6)
        #expect(Array(sent.prefix(3)) == Array(expectedClient.prefix(3)))
        #expect(Set(sent[3..<5]) == Set(expectedClient[3..<5]))
        #expect(sent[5] == .responseCreate())
        #expect(sent.count { $0 == .responseCreate() } == 2)  // the user's turn and the single follow-up
        #expect(Set(search.calls.values) == ["launch", "budget"])
        #expect(search.calls.values.count == 2)
        await harness.finish()
    }
}
