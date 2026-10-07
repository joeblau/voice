import BlauAudio
import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import BlauRealtime

/// The orchestrator against the real pieces around it: `ConversationStore`
/// over SwiftData, the recorded fixture sessions replayed through a real
/// `RealtimeClient`, and the real playback engine.
@Suite("Turn orchestrator integration")
struct TurnOrchestratorIntegrationTests {
    /// The acceptance criterion "transcript persisted for both roles",
    /// through `ConversationStore` into a SwiftData store.
    @Test func bothRolesArePersistedThroughTheConversationStore() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let store = ConversationStore(modelContainer: container, savePolicy: .immediate)
        let harness = TurnHarness(transcript: store)
        let socket = try await harness.start()

        let question = harness.utterance("What should I focus on this week?", from: 0, to: 2)
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)
        harness.clock.advance(by: .seconds(3))
        for event in ServerEvents.reply(
            "Start with the launch checklist.", response: "resp_1", item: "item_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("turn done") { await harness.snapshot().completedTurns == 1 }
        await harness.orchestrator.stop()

        let context = ModelContext(container)
        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.count == 1)
        let conversation = try #require(conversations.first)
        #expect(conversation.id == harness.conversationID.rawValue)
        #expect(conversation.endedAt != nil)
        let utterances = conversation.orderedUtterances
        #expect(utterances.map(\.role) == [.user, .agent])
        #expect(utterances.map(\.text) == ["What should I focus on this week?", "Start with the launch checklist."])
        #expect(utterances.map(\.source) == [.parakeet, .grok])
        #expect(utterances.allSatisfy { $0.isFinal })
        #expect(utterances[0].id == question.id)
    }

    /// A rapid follow-up and an interruption, as the store ends up holding
    /// them: one merged user row, the agent's cut reply, the new question.
    @Test func mergedAndInterruptedTurnsAreStoredOnce() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let store = ConversationStore(modelContainer: container, savePolicy: .immediate)
        let harness = TurnHarness(transcript: store)
        harness.audio.setIdle(false)
        let socket = try await harness.start()

        await harness.orchestrator.handle(.final(harness.utterance("Tell me about", from: 0, to: 1)))
        await harness.orchestrator.handle(.final(harness.utterance("the bridge", from: 1.1, to: 1.6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        // The merged turn's response, cancelled; then the continuation's.
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag(0)))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        harness.clock.advance(by: .seconds(2))
        socket.push(ServerEvents.responseCreated("resp_2", turn: socket.turnTag(1)))
        socket.push(ServerEvents.audio("item_2", response: "resp_2", milliseconds: 1000))
        socket.push(ServerEvents.transcript("item_2", response: "resp_2", "It opened in 1937 after four years."))
        try await waitUntil("speaking") { await !harness.snapshot().agentText.isEmpty }
        harness.audio.setPlayed(PlaybackItemID(itemID: "item_2"), milliseconds: 600)

        await harness.orchestrator.handle(.final(harness.utterance("Who built it?", from: 5, to: 6)))
        try await harness.waitForSent("conversation.item.create", count: 3, on: socket)
        socket.push(ServerEvents.responseDone("resp_2", status: .cancelled))
        try await harness.waitForSent("response.create", count: 3, on: socket)
        await harness.orchestrator.stop()

        let rows = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
            .orderedUtterances
        #expect(rows.map(\.role) == [.user, .agent, .user])
        #expect(rows[0].text == "Tell me about the bridge")
        #expect(rows[1].text == "It opened in 1937")
        #expect(rows[2].text == "Who built it?")
    }

    /// The hand-written `manual-text-turn` session (xAI's reference
    /// examples), replayed in lockstep through a real client: the
    /// orchestrator's frames line up with the recorded ones and the reply is
    /// played and stored.
    ///
    /// The fixture's `response.created` echoes `metadata: {"turn": "1"}`,
    /// not the orchestrator's `blau_turn` key, so this replays the untagged
    /// path: the response is matched to the turn by order. Whether xAI
    /// echoes `metadata` at all is unverified until a live recording exists.
    @Test func replaysTheManualTextTurnFixtureMatchingByOrder() async throws {
        let transcript = try Fixtures.transcript("manual-text-turn")
        let connector = RealtimeReplayConnector(transcript: transcript)
        let clock = ManualClock(now: turnT0)
        let client = RealtimeClient(
            endpoint: .realtimeTest, tokenProvider: FakeTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let audio = FakeAudioOutput()
        let recording = RecordingTranscript()
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore(), clock: clock),
            audio: audio, transcript: recording, clock: clock, signposter: .disabled(.realtime))

        try await orchestrator.start()
        try await orchestrator.send(
            Utterance(
                conversationID: ConversationID(), speaker: .user, text: "What should I focus on this week?",
                timeRange: TimeRange(start: .zero, duration: .seconds(2)), startedAt: turnT0))
        try await waitUntil("reply done") { await orchestrator.snapshot.completedTurns == 1 }
        try await waitUntil("listening") { await orchestrator.state == .listening }
        await orchestrator.waitUntilSettled()

        let sent = try #require(connector.sockets.first).sentEvents
        #expect(sent.map(\.type) == ["session.update", "conversation.item.create", "response.create"])
        #expect(audio.enqueued.count == 3)
        #expect(Set(audio.enqueued.map(\.item)) == [PlaybackItemID(itemID: "item_002")])
        #expect(recording.stored.map(\.speaker) == [.user, .agent])
        #expect(recording.stored.last?.text == "Start with the launch checklist.")
        #expect(await orchestrator.snapshot.usage.totalTokens == 508)
        await orchestrator.shutdown()
    }

    /// The real playback engine behind the orchestrator: the reply's audio
    /// is queued sample for sample and the turn ends once it has been
    /// rendered.
    @Test func aReplyPlaysThroughTheStreamingPlayer() async throws {
        let player = StreamingAudioPlayer(clock: SystemClock(), signposter: .disabled(.audio))
        let connector = FakeConnector()
        let clock = ManualClock(now: turnT0)
        let client = RealtimeClient(
            endpoint: .realtimeTest, tokenProvider: FakeTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore(), clock: clock),
            audio: player, transcript: RecordingTranscript(), clock: clock, signposter: .disabled(.realtime))
        try await orchestrator.start()
        let socket = try await connector.socket(0)
        try await orchestrator.send(
            Utterance(
                conversationID: ConversationID(), speaker: .user, text: "Hi",
                timeRange: TimeRange(start: .zero, duration: .seconds(1)), startedAt: turnT0))
        try await waitUntil("requested") { socket.sentEvents.contains { $0.type == "response.create" } }
        for event in ServerEvents.reply(
            "Hello there.", response: "resp_1", item: "item_1", turn: socket.turnTag(), audioMilliseconds: 200)
        {
            socket.push(event)
        }
        try await waitUntil("done") { await orchestrator.snapshot.completedTurns == 1 }
        #expect(await orchestrator.state == .agentSpeaking)
        #expect(player.snapshot.bufferedDuration == .milliseconds(200))

        // Render it, as the audio engine would, 20 ms at a time.
        var buffer = [Float](repeating: 0, count: 480)
        for _ in 0..<15 {
            buffer.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
        }
        let played = try #require(player.playedItem(for: PlaybackItemID(itemID: "item_1")))
        #expect(played.playedDuration == .milliseconds(200))
        try await waitUntil("listening", timeout: .seconds(5)) { await orchestrator.state == .listening }
        await orchestrator.shutdown()
    }
}
