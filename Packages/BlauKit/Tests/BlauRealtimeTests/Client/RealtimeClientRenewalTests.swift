import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

@Suite("RealtimeClient: renewing a session")
struct RealtimeClientRenewalTests {
    @Test func reconnectClosesTheOpenConnectionAndOpensTheNewEndpoint() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        let first = try await harness.connector.socket(0)
        #expect(await harness.client.connectionURL == .realtimeTest)

        let resumed = RealtimeEndpoint.url(.realtimeTest, conversationID: "conv_1")
        try await harness.client.reconnect(to: resumed)
        let second = try await harness.connector.socket(1)

        #expect(first.closeCode == .normalClosure)
        #expect(second.url == resumed)
        #expect(await harness.client.endpoint == resumed)
        #expect(await harness.client.connectionURL == resumed)
        try await harness.states.waitFor(.reconnecting(attempt: 1))
        try await waitUntil("connected again") { harness.states.values.last == .connected }
        // The renewal is announced as a reconnect, never as a disconnect.
        #expect(!harness.states.values.contains(.disconnected(nil)))
        // Events of the new connection still arrive on the same stream.
        second.push(TestEvents.sessionCreated)
        try await waitUntil("event") { harness.events.values.contains { $0.type == "session.created" } }
    }

    @Test func reconnectRetriesLikeAReconnectAfterADrop() async throws {
        let harness = ClientHarness()
        try await harness.client.connect()
        harness.connector.enqueue(.fail(.network(code: URLError.networkConnectionLost.rawValue)))
        let client = harness.client
        let renewal = Task { try await client.reconnect() }
        try await waitUntil("backing off") { harness.clock.sleeperCount > 0 }
        harness.clock.advance(by: .seconds(1))
        try await renewal.value
        #expect(harness.connector.attempts == 3)
        #expect(await harness.state() == .connected)
    }

    @Test func prepareClientSecretMintsAheadOfTheConnection() async throws {
        let harness = ClientHarness()
        #expect(await harness.client.prepareClientSecret())
        #expect(harness.tokens.minted == 1)
        try await harness.client.connect()
        // The connection used the secret prepared for it.
        #expect(harness.tokens.minted == 1)
        #expect(harness.connector.subprotocols == [["xai-client-secret.secret-1"]])
    }

    @Test func prepareClientSecretReportsAFailureWithoutThrowing() async throws {
        let harness = ClientHarness(tokenErrors: [XAIError.rateLimited(retryAfter: nil)])
        #expect(await harness.client.prepareClientSecret() == false)
        #expect(await harness.state() == .disconnected(nil))
    }

    @Test func endpointsAddAndRemoveTheConversationID() throws {
        let base = URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")!
        let resumed = RealtimeEndpoint.url(base, conversationID: "conv_77")
        #expect(
            resumed.absoluteString
                == "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0&conversation_id=conv_77")
        #expect(RealtimeEndpoint.conversationID(in: resumed) == "conv_77")
        #expect(RealtimeEndpoint.conversationID(in: base) == nil)
        // Replacing and removing keep the other parameters.
        let other = RealtimeEndpoint.url(resumed, conversationID: "conv_78")
        #expect(other.absoluteString.hasSuffix("?model=grok-voice-think-fast-2.0&conversation_id=conv_78"))
        #expect(RealtimeEndpoint.url(other, conversationID: nil) == base)
        #expect(RealtimeEndpoint.url(URL(string: "wss://h/v1")!, conversationID: nil).absoluteString == "wss://h/v1")
    }
}
