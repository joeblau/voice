import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// The real `URLSessionWebSocketTask` transport against a WebSocket server
/// on 127.0.0.1: the subprotocol handshake, frames both ways, pings, a
/// refused upgrade, and a connection killed without a close frame. Loopback
/// only; nothing leaves the machine.
@Suite("URLSession WebSocket over loopback", .serialized, .timeLimit(.minutes(1)))
struct URLSessionRealtimeSocketTests {
    @Test func offersTheSecretAsSubprotocolAndExchangesFrames() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let url = try await server.start()
        let connector = URLSessionRealtimeSocketConnector()

        let socket = try await connector.connect(to: url, subprotocols: ["xai-client-secret.abc123"])
        defer { socket.close(code: .normalClosure, reason: nil) }
        #expect(server.offeredSubprotocols == [["xai-client-secret.abc123"]])

        server.send(TestEvents.sessionCreated, on: 0)
        #expect(try await socket.receive() == .text(TestEvents.sessionCreated))
        server.send(binary: Data([1, 2, 3]), on: 0)
        #expect(try await socket.receive() == .binary(Data([1, 2, 3])))

        let sent = Mutex<(any Error)?>(nil)
        socket.send(.text(#"{"type":"response.create"}"#)) { error in sent.withLock { $0 = error } }
        socket.send(.binary(Data([4, 5]))) { _ in }
        try await waitUntil("server received two frames") { server.received.count == 2 }
        #expect(
            server.received == [
                .init(connection: 0, message: .text(#"{"type":"response.create"}"#)),
                .init(connection: 0, message: .binary(Data([4, 5]))),
            ])

        // The pong is only read while a receive is outstanding, as in the
        // client's receive loop.
        let pending = Task { try await socket.receive() }
        try await socket.ping()
        pending.cancel()
    }

    /// Real pings over a live socket get their pongs: an idle connection is
    /// not mistaken for a dead one.
    @Test func keepaliveKeepsAHealthyConnection() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let url = try await server.start()
        // The keepalive's timers run on a manual clock, so a slow machine
        // can't run out the pong timeout while the real pong is on its way
        // (#180); the pings and pongs go over the real socket.
        let clock = ManualClock()
        let interval = Duration.milliseconds(100)
        let client = RealtimeClient(
            endpoint: url, tokenProvider: FakeTokenProvider(), clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: interval, pongTimeout: .seconds(2)))
        defer { Task { await client.shutdown() } }

        try await client.connect()
        for _ in 0..<5 {
            // Only the next interval asleep: the last ping's pong came back
            // (the client stops its pong timeout, then sleeps again).
            try await waitUntil("next ping scheduled") { clock.sleeperDeadlines == [clock.uptime + interval] }
            clock.advance(by: interval)
        }
        try await waitUntil("last pong") { clock.sleeperDeadlines == [clock.uptime + interval] }

        #expect(server.connectionCount == 1)
        #expect(await client.state == .connected)
    }

    /// A server that stops answering pings (a connection that died without
    /// an error) is detected by keepalive and replaced.
    @Test func keepaliveReplacesASilentConnection() async throws {
        let server = try LoopbackWebSocketServer(answersPings: false)
        defer { server.stop() }
        let url = try await server.start()
        let client = RealtimeClient(
            endpoint: url, tokenProvider: FakeTokenProvider(),
            configuration: .init(keepAliveInterval: .milliseconds(100), pongTimeout: .milliseconds(300)))
        let states = StreamCollector(client.states)
        defer { Task { await client.shutdown() } }

        try await client.connect()
        try await waitUntil("a second connection") { server.connectionCount >= 2 }

        try await states.waitFor(.reconnecting(attempt: 1))
    }

    @Test(arguments: [(401, "Unauthorized"), (503, "Service Unavailable")])
    func aRefusedUpgradeReportsTheHTTPStatus(status: Int, reason: String) async throws {
        let server = try LoopbackHTTPResponder(status: status, reason: reason)
        defer { server.stop() }
        let url = try await server.start()

        await #expect(throws: RealtimeClientError.handshakeFailed(status: status)) {
            _ = try await URLSessionRealtimeSocketConnector().connect(to: url, subprotocols: ["xai-client-secret.x"])
        }
    }

    /// A secret the server refuses is thrown away and one fresh secret is
    /// tried before giving up with `unauthorized`.
    @Test func clientRetriesARefusedSecretOnceThenReportsUnauthorized() async throws {
        let server = try LoopbackHTTPResponder(status: 401, reason: "Unauthorized")
        defer { server.stop() }
        let url = try await server.start()
        let tokens = FakeTokenProvider()
        let client = RealtimeClient(endpoint: url, tokenProvider: tokens)

        await #expect(throws: RealtimeClientError.unauthorized(status: 401)) {
            try await client.connect()
        }
        #expect(server.requests == 2)
        #expect(tokens.invalidations == 2)
        #expect(tokens.minted == 2)
    }

    @Test func nothingListeningIsANetworkError() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try await server.start()
        server.stop()
        try await waitUntil("listener closed") { server.isCancelled }

        await #expect {
            _ = try await URLSessionRealtimeSocketConnector().connect(to: url, subprotocols: [])
        } throws: { error in
            guard case .network = error as? RealtimeClientError else { return false }
            return true
        }
    }

    @Test func aDroppedConnectionFailsReceive() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let url = try await server.start()
        let socket = try await URLSessionRealtimeSocketConnector().connect(to: url, subprotocols: [])
        try await waitUntil("server accepted") { server.connectionCount == 1 }

        server.drop(0)

        await #expect {
            _ = try await socket.receive()
        } throws: { error in
            (error as? RealtimeClientError)?.isRetryable == true
        }
    }

    /// The acceptance criterion end to end: the real client over a real
    /// socket reconnects after the connection dies without a close frame,
    /// with a new upgrade carrying the secret, and keeps delivering events.
    @Test func clientReconnectsAfterANetworkDrop() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let url = try await server.start()
        let signposts = RecordingSignpostBackend()
        let client = RealtimeClient(
            endpoint: url,
            tokenProvider: FakeTokenProvider(),
            configuration: .init(keepAliveInterval: .seconds(5)),
            signposter: Signposter(category: .realtime, backend: signposts))
        let events = StreamCollector(client.events)
        let states = StreamCollector(client.states)
        defer { Task { await client.shutdown() } }

        try await client.connect()
        try await waitUntil("first connection") { server.connectionCount == 1 }
        server.send(TestEvents.sessionCreated, on: 0)
        try await events.waitForCount(1)

        server.drop(0)

        try await waitUntil("second connection") { server.connectionCount == 2 }
        try await waitUntil("connected again") { await client.state == .connected }
        try await states.waitFor(.reconnecting(attempt: 1))
        #expect(server.offeredSubprotocols == [["xai-client-secret.secret-1"], ["xai-client-secret.secret-1"]])

        server.send(TestEvents.responseDone, on: 1)
        try await events.waitForCount(2)
        #expect(events.values.map(\.type) == ["session.created", "response.done"])

        try await client.send(.responseCreate())
        try await waitUntil("server got the send") { server.received.contains { $0.connection == 1 } }
        #expect(server.received.last == .init(connection: 1, message: .text(#"{"type":"response.create"}"#)))
        #expect(signposts.endMessages(of: "realtime.connect") == ["connected", "connected"])
        #expect(signposts.events.contains("realtime.drop"))
    }
}
