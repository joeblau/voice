import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

@Suite struct ScriptedRealtimeServerTests {
    /// A real `RealtimeClient` and `TurnOrchestrator` talking to the
    /// scripted server, the way the performance suite's replay runs them.
    struct Harness {
        let server: ScriptedRealtimeServer
        let audio = DiscardingAgentAudioOutput()
        let transcript = RecordingTranscript()
        let orchestrator: TurnOrchestrator

        init(pacing: ScriptedRealtimeServer.Pacing = .immediate) {
            server = ScriptedRealtimeServer(pacing: pacing) { request in
                .init(text: "Reply \(request.index + 1) to \(request.userText.split(separator: " ").count) words.")
            }
            let client = RealtimeClient(
                endpoint: .realtimeTest, tokenProvider: ScriptedRealtimeServer.TokenProvider(), connector: server,
                configuration: .init(keepAliveInterval: nil), signposter: .disabled(.realtime))
            orchestrator = TurnOrchestrator(
                client: client, configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore()),
                audio: audio, transcript: transcript, signposter: .disabled(.realtime))
        }

        func agentUtterances() -> [Utterance] {
            transcript.stored.filter { $0.speaker == .agent }
        }
    }

    @Test func everyTurnGetsASpokenReply() async throws {
        let harness = Harness()
        let lines = ["What should I focus on this week", "And after that what comes next", "Thanks that helps"]
        let script = TranscriptScript.speaking(
            // Seconds apart on the audio timeline, so no line continues the
            // previous one (the orchestrator merges finals 400 ms apart).
            lines, wordDuration: .milliseconds(200), endOfUtteranceDelay: .milliseconds(600),
            pauseBetweenLines: .seconds(2))
        try await harness.orchestrator.start()
        for (index, final) in script.finals.enumerated() {
            await harness.orchestrator.handle(.final(final))
            // The transcript can be written before response.done arrives.
            // Finish the response before feeding another final or stopping,
            // so this test never interrupts its own last measured reply.
            try await waitUntil("reply \(index + 1)") {
                let completed = await harness.orchestrator.snapshot.completedTurns
                return completed == index + 1 && harness.agentUtterances().count == index + 1
            }
        }
        await harness.orchestrator.stop()

        let agent = harness.agentUtterances().map(\.text)
        #expect(agent == ["Reply 1 to 7 words.", "Reply 2 to 6 words.", "Reply 3 to 3 words."])
        #expect(harness.transcript.stored.filter { $0.speaker == .user }.map(\.text) == lines)
        // About 0.34 s of 24 kHz PCM16 per word.
        #expect(harness.audio.receivedItems.count == 3)
        #expect(harness.audio.receivedBytes > 3 * 4 * 8_000)
        let snapshot = await harness.orchestrator.snapshot
        #expect(snapshot.latency.turn.totalCount == 3)
        #expect(harness.server.sockets.count == 1)
        #expect(harness.server.sockets[0].clientCloseCode != nil)
    }

    @Test func cancelStopsTheReply() async throws {
        // Slow audio, so the reply is still streaming when it is cancelled.
        let harness = Harness(pacing: .init(audioSpeed: 1, audioChunk: .milliseconds(100)))
        try await harness.orchestrator.start()
        let first = TranscriptScript.speaking(["Tell me a long story"], wordDuration: .milliseconds(5)).finals[0]
        await harness.orchestrator.handle(.final(first))
        try await waitUntil("reply audio") { harness.audio.receivedBytes >= 3 * 4_800 }
        // A new turn while Grok is answering interrupts the reply.
        let second = Utterance(
            conversationID: first.conversationID, speaker: .user, text: "Actually stop",
            timeRange: TimeRange(start: first.timeRange.end + .seconds(5), duration: .seconds(1)),
            startedAt: first.startedAt.addingTimeInterval(6), speakerDecision: .accept)
        await harness.orchestrator.handle(.final(second))
        try await waitUntil("second response", timeout: .seconds(20)) { harness.server.responseCount == 2 }
        try await waitUntil("second reply", timeout: .seconds(20)) {
            harness.agentUtterances().contains { $0.text == "Reply 2 to 2 words." }
        }
        await harness.orchestrator.stop()
        #expect(harness.agentUtterances().count == 2)
        let interrupted = await harness.orchestrator.snapshot.interruptedAgentUtterances
        #expect(interrupted.count == 1)
    }

    @Test func toneIsPCM16() {
        let data = ScriptedRealtimeSocket.tone(samples: 240, offset: 0)
        #expect(data.count == 480)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples[0] == 0)
        #expect(samples.map { abs(Int($0)) }.max()! > 2_500)
    }
}
