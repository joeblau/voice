import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// The soak test's renewal (#76): xAI's session schedule scaled down so a
/// replay renews its session part-way through, against the scripted server,
/// with the real client and orchestrator.
@Suite struct ScriptedServerRolloverTests {
    @Test func scalingDividesEverySessionAgeLimit() {
        let standard = SessionContinuityConfiguration.standard
        let scaled = standard.scaled(by: 10)
        #expect(scaled.maximumSessionDuration == .seconds(12 * 60))
        #expect(scaled.rolloverAfter == .seconds(11 * 60))
        #expect(scaled.rolloverDeadline == .seconds(118 * 6))
        #expect(scaled.tokenRefreshLead == .seconds(12))
        #expect(scaled.rolloverRetryInterval == .seconds(6))
        #expect(scaled.resumptionIdleLimit == .seconds(150))
        // The server's own pace doesn't change.
        #expect(scaled.resumeConfirmationTimeout == standard.resumeConfirmationTimeout)
        #expect(scaled.resumption == standard.resumption)
        #expect(scaled.resumesAtRollover == standard.resumesAtRollover)
        #expect(scaled.reseed == standard.reseed)

        var off = standard
        off.rolloverAfter = nil
        #expect(off.scaled(by: 4).rolloverAfter == nil)
        #expect(standard.scaled(by: 1) == standard)
    }

    @Test(.timeLimit(.minutes(1)))
    func aScaledSessionRenewsAndTheConversationGoesOn() async throws {
        // 110 minutes in 0.6 s of the clock: the renewal comes after the
        // first few turns. The client, configurator and orchestrator share a
        // manual clock, so how long the machine takes to run a turn doesn't
        // move the renewal (#180).
        let continuity = SessionContinuityConfiguration.standard.scaled(by: 110 * 60 / 0.6)
        let clock = ManualClock()
        let server = ScriptedRealtimeServer { request in
            .init(text: "Reply \(request.index + 1).", audioDuration: .milliseconds(100))
        }
        let transcript = RecordingTranscript()
        let orchestrator = TurnOrchestrator(
            client: RealtimeClient(
                endpoint: .realtimeTest, tokenProvider: ScriptedRealtimeServer.TokenProvider(), connector: server,
                clock: clock, configuration: .init(keepAliveInterval: nil), signposter: .disabled(.realtime)),
            configurator: RealtimeSessionConfigurator(settings: RealtimeVoiceSettingsStore(), clock: clock),
            audio: DiscardingAgentAudioOutput(), transcript: transcript, clock: clock,
            signposter: .disabled(.realtime), configuration: .init(continuity: continuity))

        let lines = (1...8).map { "Question number \($0) about the plan" }
        let script = TranscriptScript.speaking(
            lines, wordDuration: .milliseconds(200), endOfUtteranceDelay: .milliseconds(600),
            pauseBetweenLines: .seconds(2))
        try await orchestrator.start()
        for (index, final) in script.finals.enumerated() {
            await orchestrator.handle(.final(final))
            try await waitUntil("reply \(index + 1)") {
                transcript.stored.filter { $0.speaker == .agent }.count == index + 1
            }
            // Turns 150 ms apart, over 1.05 s: the session passes its
            // (scaled) renewal age once, between two of them, and the new
            // session is never old enough to renew again.
            if index < script.finals.count - 1 {
                clock.advance(by: .milliseconds(150))
            }
        }
        try await waitUntil("a renewal") { await orchestrator.snapshot.session.rollovers >= 1 }
        let snapshot = await orchestrator.snapshot
        await orchestrator.stop()

        #expect(transcript.stored.filter { $0.speaker == .agent }.count == lines.count)
        #expect(snapshot.session.rollovers == 1)
        #expect(snapshot.session.reseeds == 1)
        #expect(server.sockets.count == 2)
        // The old session was closed cleanly by the client, not dropped.
        #expect(server.sockets[0].clientCloseCode == .normalClosure)
    }
}
