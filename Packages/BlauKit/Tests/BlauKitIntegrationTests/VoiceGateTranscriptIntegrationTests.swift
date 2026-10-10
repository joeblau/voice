import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauVoiceID
import Foundation
import Synchronization
import Testing

/// The voice ID gate (#47) between the transcriber and the turn orchestrator
/// (#36), as `LiveVoicePipeline` wires them: `gate.filter(transcriber.events)`
/// is what the orchestrator reads. The real orchestrator runs a replayed
/// realtime session.
@Suite("Voice ID gate: transcript integration")
struct VoiceGateTranscriptIntegrationTests {
    /// The utterances the orchestrator stores.
    final class RecordedUtterances: TurnTranscriptRecording {
        private let stored = Mutex<[Utterance]>([])

        var utterances: [Utterance] { stored.withLock { $0 } }

        func beginConversation(_ id: ConversationID, at date: Date) async throws {}
        func record(_ utterance: Utterance) async throws { stored.withLock { $0.append(utterance) } }
        func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws {}
        func finishConversation(_ id: ConversationID, at date: Date) async throws {}
        func flush() async throws {}
    }

    static let rate = AudioFrame.captureSampleRate

    /// VAD's speech audio for one segment from `start` to `end` seconds,
    /// with its 300 ms hangover.
    static func segment(_ id: Int, from start: Double, to end: Double) -> [SpeechAudioEvent] {
        let first = Int64(start * Double(rate))
        let speechEnd = Int64(end * Double(rate))
        let stop = speechEnd + Int64(0.3 * Double(rate))
        var events: [SpeechAudioEvent] = [
            .started(
                SpeechOnset(
                    segmentID: id, startOffset: first, sampleRate: rate, isContinuation: false,
                    detectedAt: first + Int64(0.3 * Double(rate))))
        ]
        var position = first
        while position < stop {
            let count = Int(min(Int64(rate / 10), stop - position))
            events.append(.audio(AudioFrame(samples: [Float](repeating: 0.1, count: count), sampleOffset: position)))
            position += Int64(count)
        }
        events.append(
            .ended(
                SpeechSegment(
                    id: id, sampleRange: first..<speechEnd, sampleRate: rate, endReason: .silence,
                    detectedAt: stop, peakProbability: 0.9, meanProbability: 0.8)))
        return events
    }

    /// A TV's line: its partials reach the orchestrator before voice ID has
    /// scored it (the first score needs 1.5 s), then its final is rejected.
    /// The orchestrator must not be left showing the TV's words as the
    /// user's, in `userSpeaking`.
    @Test func aRejectedFinalEndsTheUserSpeakingStateTheTVsPartialsStarted() async throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../BlauRealtimeTests/Fixtures/manual-text-turn.jsonl").standardized
        let connector = RealtimeReplayConnector(transcript: try RealtimeTranscript(contentsOf: fixture))
        let clock = ManualClock()
        let client = RealtimeClient(
            endpoint: URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")!,
            tokenProvider: MemoryToolIntegrationTests.StaticTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let recorded = RecordedUtterances()
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore(), clock: clock),
            audio: MemoryToolIntegrationTests.SilentAudioOutput(), transcript: recorded, clock: clock,
            signposter: .disabled(.realtime))
        try await orchestrator.start()
        try await MemoryToolIntegrationTests.waitUntil("listening") { await orchestrator.state == .listening }

        let gate = VerificationGate(verifier: VoiceGateBargeInIntegrationTests.FixedVerifier(score: 0.05))
        let (transcriber, input) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let reading = Task { await orchestrator.run(transcript: gate.filter(transcriber)) }

        // The TV's first words, before the gate has heard enough to score.
        input.yield(.partial(text: "And now", range: TimeRange(start: .zero, end: .seconds(0.8))))
        try await MemoryToolIntegrationTests.waitUntil("userSpeaking") {
            await orchestrator.snapshot.userPartial == "And now"
        }
        #expect(await orchestrator.state == .userSpeaking)

        // VAD's speech reaches the gate; the final is rejected.
        for event in Self.segment(0, from: 0, to: 3) {
            await gate.handle(event)
        }
        let tv = Utterance(
            conversationID: ConversationID(), speaker: .user, text: "And now the weather",
            timeRange: TimeRange(start: .zero, end: .seconds(3)), startedAt: clock.now)
        input.yield(.final(tv))
        input.finish()
        await reading.value

        let snapshot = await orchestrator.snapshot
        #expect(snapshot.state == .listening)
        #expect(snapshot.userPartial == nil)
        #expect(recorded.utterances.isEmpty)
        let sent = try #require(connector.sockets.first).sentEvents
        #expect(!sent.contains { $0.type == "conversation.item.create" })
        #expect(gate.statistics.discarded == 1)
        await orchestrator.shutdown()
    }
}
