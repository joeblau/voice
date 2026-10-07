import BlauAudio
import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import BlauRealtime

/// `TurnOrchestrator.bargeIn(_:)` (#37): what the orchestrator stops, sends,
/// stores and reports when the user talks over Grok; and the whole path
/// from a VAD onset through `BargeInMonitor` to the real playback engine.
@Suite("Barge-in")
struct TurnOrchestratorBargeInTests {
    static let item = PlaybackItemID(itemID: "item_1")
    static let reply = "The Golden Gate Bridge opened in 1937 after four years of work."

    /// Starts a turn and has Grok speak `milliseconds` of audio and the
    /// reply's transcript; the response is still in progress.
    static func speakingTurn(
        _ harness: TurnHarness, milliseconds: Int = 1000
    ) async throws -> FakeSocket {
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Tell me about the bridge", from: 0, to: 2)))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: milliseconds))
        socket.push(ServerEvents.transcript("item_1", response: "resp_1", reply))
        try await harness.waitForState(.agentSpeaking)
        try await waitUntil("transcript") { await harness.snapshot().agentText == reply }
        return socket
    }

    static func trigger(at uptime: Duration) -> BargeInTrigger {
        BargeInTrigger(onset: .at(3.0, detected: 3.3, segment: 7), receivedAt: uptime)
    }

    // MARK: Cutting the reply

    @Test func bargingInCutsTheReplyAtWhatWasHeard() async throws {
        let harness = TurnHarness()
        let socket = try await Self.speakingTurn(harness)
        harness.audio.setPlayed(Self.item, milliseconds: 400)

        let record = try #require(await harness.orchestrator.bargeIn(Self.trigger(at: harness.clock.uptime)))

        // Silence first, then Grok is told what was heard.
        #expect(harness.audio.flushes == 1)
        try await harness.waitForSent("conversation.item.truncate", on: socket)
        #expect(Array(socket.sentEvents.map(\.type).suffix(2)) == ["response.cancel", "conversation.item.truncate"])
        #expect(socket.cancelledResponses == ["resp_1"])
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 400)))

        #expect(record.turn == 1)
        #expect(record.cancelledResponse)
        #expect(record.reactionTime == .zero)  // manual clock: no time passes
        #expect(record.cut.map(\.itemID) == ["item_1"])
        #expect(record.cut.first?.heardMilliseconds == 400)
        #expect(record.cut.first?.receivedMilliseconds == 1000)

        let snapshot = await harness.snapshot()
        #expect(snapshot.state == .listening)
        #expect(snapshot.agentText.isEmpty)
        #expect(snapshot.bargeIns == 1)
        #expect(snapshot.lastBargeIn == record)
        let utteranceID = try #require(record.cut.first?.utteranceID)
        #expect(snapshot.interruptedAgentUtterances == [utteranceID])
        #expect(harness.signposts.events == ["realtime.bargeIn"])
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["bargedIn"])
        #expect(harness.signposts.openIntervals.isEmpty)

        // The stored agent row holds the heard share of the text, under the
        // id the snapshot marks; the server's cut then corrects it.
        await harness.orchestrator.waitUntilSettled()
        let agent = try #require(harness.recording?.stored.first { $0.speaker == .agent })
        #expect(agent.id == utteranceID)
        #expect(agent.text == "The Golden Gate Bridge")
        #expect(agent.timeRange.duration == .milliseconds(400))
        socket.push(
            .conversationItemTruncated(
                .init(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 400, transcript: "The Golden Gate")))
        try await waitUntil("server transcript stored") {
            await harness.orchestrator.waitUntilSettled()
            return harness.recording?.stored.first { $0.speaker == .agent }?.text == "The Golden Gate"
        }
    }

    /// The acceptance criterion "the model's next reply reflects only what
    /// was actually heard", at the protocol level: before the user's next
    /// item and `response.create`, Grok's copy of the reply is truncated to
    /// the played milliseconds and the cancelled response has finished.
    @Test func theNextTurnFollowsTheTruncatedReply() async throws {
        let harness = TurnHarness()
        let socket = try await Self.speakingTurn(harness)
        harness.audio.setPlayed(Self.item, milliseconds: 650)
        await harness.orchestrator.bargeIn(Self.trigger(at: harness.clock.uptime))

        // The user's words arrive as partials, then a final.
        await harness.orchestrator.handle(
            .partial(text: "Actually", range: TimeRange(start: .seconds(3), duration: .milliseconds(500))))
        try await harness.waitForState(.userSpeaking)
        let followUp = harness.utterance("Actually, just the year it opened", from: 3, to: 5)
        await harness.orchestrator.handle(.final(followUp))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        // Its response.create waits for the cancelled response to finish.
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 1)
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await harness.waitForSent("response.create", count: 2, on: socket)

        let afterQuestion = socket.sentEvents.map(\.type).drop(while: { $0 != "response.cancel" })
        #expect(
            Array(afterQuestion) == [
                "response.cancel", "conversation.item.truncate", "conversation.item.create", "response.create",
            ])
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 650)))
        #expect(socket.sentUserTexts == ["Tell me about the bridge", "Actually, just the year it opened"])
        try await harness.waitForState(.agentThinking)

        // The new reply plays as usual.
        for event in ServerEvents.reply("In 1937.", response: "resp_2", item: "item_2", turn: socket.turnTag(1)) {
            socket.push(event)
        }
        try await waitUntil("second reply") { await harness.snapshot().completedTurns == 1 }
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.speaker) == [.user, .agent, .user, .agent])
        #expect(harness.recording?.stored.last?.text == "In 1937.")
        // Only the cut reply is marked.
        let cutReply = try #require(harness.recording?.stored[1])
        #expect(await harness.snapshot().interruptedAgentUtterances == [cutReply.id])
    }

    @Test func aReplyNoneOfWhichWasHeardIsRemovedFromGroksHistory() async throws {
        let harness = TurnHarness()
        let socket = try await Self.speakingTurn(harness)
        // Still in the jitter buffer: nothing played yet.
        let record = try #require(await harness.orchestrator.bargeIn(Self.trigger(at: harness.clock.uptime)))
        try await harness.waitForSent("conversation.item.delete", on: socket)
        #expect(!socket.sentEvents.contains { $0.type == "conversation.item.truncate" })
        #expect(
            record.cut == [.init(itemID: "item_1", utteranceID: nil, heardMilliseconds: 0, receivedMilliseconds: 1000)])
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.speaker) == [.user])
        #expect(await harness.snapshot().interruptedAgentUtterances.isEmpty)
    }

    @Test func aReplyStillPlayingAfterResponseDoneIsTruncatedWithoutACancel() async throws {
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
        harness.audio.setPlayed(Self.item, milliseconds: 1000)

        let record = try #require(await harness.orchestrator.bargeIn(Self.trigger(at: harness.clock.uptime)))
        try await harness.waitForSent("conversation.item.truncate", on: socket)
        #expect(!record.cancelledResponse)
        #expect(!socket.sentEvents.contains { $0.type == "response.cancel" })
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 1000)))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.last?.text == "Hello and")
        #expect(await harness.orchestrator.state == .listening)
    }

    @Test func nothingIsCutUnlessGrokIsSpeaking() async throws {
        let harness = TurnHarness()
        #expect(await harness.orchestrator.bargeIn(Self.trigger(at: .zero)) == nil)  // paused
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        #expect(await harness.orchestrator.bargeIn(Self.trigger(at: .zero)) == nil)  // listening

        await harness.orchestrator.handle(.final(harness.utterance("Hi", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        try await harness.waitForState(.agentThinking)
        #expect(await harness.orchestrator.bargeIn(Self.trigger(at: .zero)) == nil)  // thinking: no audio yet

        await harness.orchestrator.waitUntilSettled()
        #expect(harness.audio.flushes == 0)
        #expect(!socket.sentEvents.contains { $0.type == "response.cancel" })
        #expect(await harness.snapshot().bargeIns == 0)
        #expect(await harness.orchestrator.isAgentSpeaking == false)
    }

    @Test func aNewUtteranceMarksTheReplyItCutAsInterruptedToo() async throws {
        let harness = TurnHarness()
        let socket = try await Self.speakingTurn(harness)
        harness.audio.setPlayed(Self.item, milliseconds: 500)
        await harness.orchestrator.handle(.final(harness.utterance("Wait", from: 5, to: 6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        await harness.orchestrator.waitUntilSettled()
        let agent = try #require(harness.recording?.stored.first { $0.speaker == .agent })
        let snapshot = await harness.snapshot()
        #expect(snapshot.interruptedAgentUtterances == [agent.id])
        #expect(snapshot.bargeIns == 0)
    }

    @Test func theHUDShowsBargeIns() {
        var snapshot = TurnSnapshot(state: .listening)
        #expect(TurnHUDReadout(snapshot).value(for: "Barge-in") == "–")
        snapshot.bargeIns = 2
        snapshot.lastBargeIn = BargeInRecord(
            turn: 3, trigger: BargeInTrigger(onset: .at(1.0, detected: 1.29), receivedAt: .seconds(4)), cut: [],
            cancelledResponse: true, reactionTime: .microseconds(420))
        #expect(TurnHUDReadout(snapshot).value(for: "Barge-in") == "2 · last 0.4 ms to flush (VAD +290 ms)")
    }

    // MARK: End to end

    /// A VAD onset over the reply, through `BargeInMonitor`, the real
    /// orchestrator and the real `StreamingAudioPlayer` rendered as the
    /// audio engine would: the acceptance criterion "interrupt → silence
    /// < 150 ms" measured from the onset reaching the monitor to the last
    /// non-silent sample, and the truncate at exactly what was rendered.
    @Test func aVADOnsetSilencesTheRealPlayerWithinOneRenderCycle() async throws {
        let player = StreamingAudioPlayer(clock: SystemClock(), signposter: .disabled(.audio))
        let clock = SystemClock()
        let connector = FakeConnector()
        let client = RealtimeClient(
            endpoint: .realtimeTest, tokenProvider: FakeTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let signposts = RecordingSignpostBackend()
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore(), clock: clock),
            audio: player, transcript: RecordingTranscript(), clock: clock,
            signposter: Signposter(category: .realtime, backend: signposts))
        try await orchestrator.start()
        let socket = try await connector.socket(0)
        try await orchestrator.send(
            Utterance(
                conversationID: ConversationID(), speaker: .user, text: "Tell me about the bridge",
                timeRange: TimeRange(start: .zero, duration: .seconds(2)), startedAt: turnT0))
        try await waitUntil("requested") { socket.sentEvents.contains { $0.type == "response.create" } }

        // One second of audible (non-zero) speech.
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(ServerEvents.itemAdded("item_1", response: "resp_1"))
        var pcm = Data()
        for _ in 0..<24_000 {
            withUnsafeBytes(of: Int16(8_192).littleEndian) { pcm.append(contentsOf: $0) }
        }
        socket.push(
            .responseOutputAudioDelta(
                .init(responseID: "resp_1", itemID: "item_1", outputIndex: 0, contentIndex: 0, audio: pcm)))
        try await waitUntil("speaking") { await orchestrator.state == .agentSpeaking }

        // 800 ms of it plays, 20 ms per render cycle.
        var buffer = [Float](repeating: 0, count: 480)
        for _ in 0..<40 {
            buffer.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
        }
        #expect(buffer.allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(player.audibleDuration == .milliseconds(800))

        // The user speaks up, well past the grace period; the microphone
        // hears them over a faint echo.
        let mic = MicSignal.tone(-60, seconds: 2.5) + MicSignal.tone(-22, seconds: 1)
        let monitor = BargeInMonitor(
            target: orchestrator, playback: player, microphone: FakeMicrophone(mic), clock: clock,
            signposter: .disabled(.realtime))
        let outcome = await monitor.handle(.speechStarted(.at(2.5, detected: 2.8)))
        guard case .bargedIn(let record) = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }

        // The very next render cycle fades out over 5 ms, then silence; and
        // nothing after it makes a sound.
        buffer.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
        let fade = 120  // 5 ms at 24 kHz
        #expect(buffer[0] > 0)
        #expect(buffer[fade...].allSatisfy { $0 == 0 })
        for _ in 0..<10 {
            buffer.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
            #expect(buffer.allSatisfy { $0 == 0 })
        }
        #expect(player.snapshot.state == .idle)

        // Interrupt → silence: the flush plus at most one 20 ms render cycle.
        let silence = record.reactionTime + .milliseconds(20)
        #expect(silence < .milliseconds(150))
        #expect(record.reactionTime < .milliseconds(50))

        // Grok is told exactly what was rendered, fade included.
        try await waitUntil("truncate") { socket.sentEvents.contains { $0.type == "conversation.item.truncate" } }
        let heard = try #require(record.cut.first?.heardMilliseconds)
        #expect(heard == 805)
        #expect(
            socket.sentEvents.contains(
                .conversationItemTruncate(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: heard)))
        #expect(socket.cancelledResponses == ["resp_1"])
        #expect(signposts.events == ["realtime.bargeIn"])

        // Deltas still in flight for the cancelled response are dropped.
        socket.push(ServerEvents.audio("item_1", response: "resp_1", milliseconds: 200))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await waitUntil("cancelled response done") { await orchestrator.snapshot.usage.responses == 1 }
        #expect(player.snapshot.bufferedDuration == .zero)
        await orchestrator.shutdown()
    }

    /// The real `ConversationStore`: the cut reply is stored once, with the
    /// heard text, under the id the snapshot marks as interrupted.
    @Test func theCutReplyIsStoredOnceWithWhatWasHeard() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let store = ConversationStore(modelContainer: container, savePolicy: .immediate)
        let harness = TurnHarness(transcript: store)
        let socket = try await Self.speakingTurn(harness)
        harness.audio.setPlayed(Self.item, milliseconds: 400)
        let record = try #require(await harness.orchestrator.bargeIn(Self.trigger(at: harness.clock.uptime)))
        socket.push(
            .conversationItemTruncated(
                .init(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 400, transcript: "The Golden Gate")))
        socket.push(ServerEvents.responseDone("resp_1", status: .cancelled))
        try await waitUntil("cancelled") { await harness.snapshot().usage.responses == 1 }
        await harness.orchestrator.stop()

        let rows = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
            .orderedUtterances
        #expect(rows.map(\.role) == [.user, .agent])
        #expect(rows[1].text == "The Golden Gate")
        #expect(rows[1].id == record.cut.first?.utteranceID)
    }
}
