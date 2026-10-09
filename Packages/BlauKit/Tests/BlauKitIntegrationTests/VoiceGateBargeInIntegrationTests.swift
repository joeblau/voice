import BlauAudio
import BlauCore
import BlauRealtime
import BlauVoiceID
import Foundation
import Synchronization
import Testing

/// What the app's composition root wires (`VoiceIDBargeInGate`): the voice
/// ID gate (#47) as the barge-in monitor's speaker gate (#37).
struct GateForBargeIn: BargeInSpeakerGate {
    let gate: VerificationGate

    func bargeInDecision(for onset: SpeechOnset) async -> SpeakerDecision? {
        await gate.bargeInDecision(for: onset)
    }
}

/// Barge-in with voice ID (#47): the user talking over Grok cuts it off, a
/// TV or someone else in the room doesn't. The real `BargeInMonitor` asks the
/// real `VerificationGate`, whose verifier scores the speech as scripted.
@Suite("Voice ID gate: barge-in integration")
struct VoiceGateBargeInIntegrationTests {
    /// Scores every stretch of speech the same.
    struct FixedVerifier: SpeechVerifying {
        let score: Float

        func verify(_ speech: AudioFrame) async throws -> SpeakerScore {
            let thresholds = VoiceIDConfig.calibrated.thresholds(forAudioDuration: speech.duration)
            return SpeakerScore(
                score: score, decision: thresholds.decision(for: score), audioDuration: speech.duration,
                thresholds: thresholds)
        }
    }

    /// Grok, speaking until it is cut off.
    final class SpeakingAgent: BargeInTarget {
        private let triggers = Mutex<[BargeInTrigger]>([])

        var received: [BargeInTrigger] { triggers.withLock { $0 } }

        var isAgentSpeaking: Bool {
            get async { triggers.withLock { $0.isEmpty } }
        }

        func bargeIn(_ trigger: BargeInTrigger) async -> BargeInRecord? {
            triggers.withLock { $0.append(trigger) }
            return BargeInRecord(turn: 1, trigger: trigger, cut: [], cancelledResponse: true, reactionTime: .zero)
        }
    }

    static let rate = AudioFrame.captureSampleRate

    /// VAD's onset of speech starting at 2 s, confirmed 300 ms later.
    static let onset = SpeechOnset(
        segmentID: 7, startOffset: Int64(2 * rate), sampleRate: rate, isContinuation: false,
        detectedAt: Int64(2.3 * Double(rate)))

    /// The speech's audio as VAD's speech stream delivers it: `seconds` of
    /// it in 100 ms frames.
    static func speech(seconds: Double) -> [SpeechAudioEvent] {
        let frames = Int(seconds * 10)
        return [.started(onset)]
            + (0..<frames).map { index in
                .audio(
                    AudioFrame(
                        samples: [Float](repeating: 0.1, count: rate / 10),
                        sampleOffset: onset.startOffset + Int64(index * rate / 10)))
            }
    }

    static func run(score: Float) async -> (BargeInOutcome?, SpeakingAgent) {
        let gate = VerificationGate(verifier: FixedVerifier(score: score))
        let agent = SpeakingAgent()
        let monitor = BargeInMonitor(target: agent, speakerGate: GateForBargeIn(gate: gate))
        let outcome = Task { await monitor.handle(.speechStarted(onset)) }
        // The 1.5 s of speech the first score needs arrives after the onset.
        for event in speech(seconds: 1.6) {
            await gate.handle(event)
        }
        return (await outcome.value, agent)
    }

    @Test func theOwnerBargesIn() async throws {
        let (outcome, agent) = await Self.run(score: 0.7)
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
        #expect(agent.received.map(\.speakerDecision) == [.accept])
    }

    @Test func uncertainSpeechStillBargesIn() async throws {
        let (outcome, agent) = await Self.run(score: 0.3)
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
        #expect(agent.received.map(\.speakerDecision) == [.uncertain])
    }

    @Test func aTVDoesNotBargeIn() async throws {
        let (outcome, agent) = await Self.run(score: 0.05)
        #expect(outcome == .suppressed(.otherSpeaker))
        #expect(agent.received.isEmpty)
    }
}
