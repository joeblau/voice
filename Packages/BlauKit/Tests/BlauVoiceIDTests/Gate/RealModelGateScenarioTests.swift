import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

/// The gate's acceptance scenarios on the real WeSpeaker model and real
/// speech (the CMU ARCTIC fixtures). Off by default; point
/// `BLAU_SPEAKER_MODEL_DIR` at the installed model, as for
/// `SpeakerEmbeddingModelTests`.
///
/// The owner (`bdl`) enrolls with two sentences. The scene then plays a
/// third sentence of theirs, close and across a small room, between other
/// speakers' sentences played through a simulated TV loudspeaker across a
/// living room, a podcast on the same speaker, and another person in the
/// room. None of the others may reach Grok, even with the turn active the
/// whole time (the uncertain policy's worst case).
@Suite(
    "Verification gate on the real model (opt-in)",
    .enabled(if: SpeakerModelEnvironment.modelDirectory != nil),
    .serialized
)
struct RealModelGateScenarioTests {
    static func clip(_ speaker: String, _ utterance: String, in fixtures: [SpeakerFixtures.Clip]) throws -> [Float] {
        try #require(fixtures.first { $0.speaker == speaker && $0.utterance == utterance }).audio.samples
    }

    static func line(
        _ text: String, _ audio: [Float], at start: Double, isOwner: Bool, condition: VoiceIDCondition = .clean
    ) throws -> GateScenario.Line {
        let degraded = try #require(
            condition.apply(to: audio, seed: EvaluationDSP.stableHash(text, condition.name), interferers: []))
        return GateScenario.Line(
            text: text, start: start, end: start + Double(degraded.count) / 16_000, isOwner: isOwner, audio: degraded)
    }

    @Test(arguments: [false, true])
    func onlyTheOwnerReachesGrok(activeTurn: Bool) async throws {
        let directory = try #require(SpeakerModelEnvironment.modelDirectory)
        let fixtures = try SpeakerFixtures.load()
        let embedder = try await WeSpeakerEmbedder.load(modelDirectory: directory)

        let enrollment = try await embedder.embed([
            AudioFrame(samples: try Self.clip("bdl", "a0001", in: fixtures), sampleOffset: 0),
            AudioFrame(samples: try Self.clip("bdl", "a0002", in: fixtures), sampleOffset: 0),
        ])
        let voiceprint = SpeakerVerifierTests.voiceprint(enrollment)
        let verifier = try SpeakerVerifier(embedder: embedder, voiceprint: voiceprint, gauges: PerformanceGauges())
        let gate = VerificationGate(verifier: verifier)
        if activeTurn { gate.turnActivity.agentActivityChanged(true) }

        var lines: [GateScenario.Line] = []
        var time = 0.5
        func add(_ text: String, _ audio: [Float], isOwner: Bool, condition: VoiceIDCondition = .clean) throws {
            let line = try Self.line(text, audio, at: time, isOwner: isOwner, condition: condition)
            lines.append(line)
            time = line.end + 1.5
        }
        try add("owner, close", Self.clip("bdl", "a0003", in: fixtures), isOwner: true)
        try add("TV", Self.clip("rms", "a0001", in: fixtures), isOwner: false, condition: .loudspeaker)
        try add("owner, small room", Self.clip("bdl", "a0003", in: fixtures), isOwner: true, condition: .roomNear)
        try add("podcast", Self.clip("clb", "a0002", in: fixtures), isOwner: false, condition: .loudspeaker)
        try add("another person", Self.clip("slt", "a0003", in: fixtures), isOwner: false, condition: .roomNear)
        try add("another person, close", Self.clip("rms", "a0002", in: fixtures), isOwner: false)
        try add("TV, a woman", Self.clip("slt", "a0001", in: fixtures), isOwner: false, condition: .loudspeaker)

        let (sent, verdicts) = await GateScenario(lines: lines).run(through: gate)

        for verdict in verdicts {
            let score = verdict.representativeScore.map { String(format: "%.3f", $0) } ?? "–"
            print(
                "\(verdict.utterance.text): \(verdict.decision.rawValue), \(verdict.disposition.rawValue), score \(score), "
                    + "held \(verdict.delay)")
        }
        // The criterion: nobody but the owner reaches Grok.
        #expect(Set(sent).isSubset(of: Set(lines.filter(\.isOwner).map(\.text))))
        // And the owner, close to the phone, does.
        #expect(sent.contains("owner, close"))
    }

    /// The gate's hold on a final that arrives the moment VAD ends its
    /// segment (the worst case: the end-of-segment re-score has only just
    /// started), on this Mac. The target is under 100 ms beyond end of
    /// utterance; the iPhone number is pending (docs/voice-id.md).
    @Test func theHoldBeyondEndOfUtteranceIsOneEmbedding() async throws {
        let directory = try #require(SpeakerModelEnvironment.modelDirectory)
        let fixtures = try SpeakerFixtures.load()
        let embedder = try await WeSpeakerEmbedder.load(modelDirectory: directory)
        let enrollment = try await embedder.embed([
            AudioFrame(samples: try Self.clip("bdl", "a0001", in: fixtures), sampleOffset: 0),
            AudioFrame(samples: try Self.clip("bdl", "a0002", in: fixtures), sampleOffset: 0),
        ])
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: SpeakerVerifierTests.voiceprint(enrollment), gauges: PerformanceGauges())
        // Warm the model up.
        _ = try await verifier.verify(AudioFrame(samples: try Self.clip("bdl", "a0003", in: fixtures), sampleOffset: 0))

        var holds: [Duration] = []
        for (index, (speaker, utterance)) in [("bdl", "a0003"), ("rms", "a0001"), ("slt", "a0002")].enumerated() {
            let gate = VerificationGate(verifier: verifier)
            // 2.4 s of speech: scored at 1.5 s, then again over all of it
            // when the segment ends.
            let audio = Array(try Self.clip(speaker, utterance, in: fixtures).prefix(38_400))
            let end = Double(audio.count) / 16_000
            let samples: @Sendable (Int64) -> Float = { $0 < audio.count ? audio[Int($0)] : 0 }
            await gate.feed(
                [.started(SpeechScript.onset(index, at: 0))]
                    + SpeechScript.audio(from: 0, to: end + 0.3, samples: samples))
            let ending = Task { await gate.feed([.ended(SpeechScript.ended(index, from: 0, to: end))]) }
            let gated = await gate.decide(finalUtterance(utterance, from: 0, to: end))
            await ending.value
            holds.append(gated.delay)
            print(
                "\(speaker)_\(utterance) (\(String(format: "%.2f", end)) s): \(gated.decision.rawValue), held \(gated.delay)"
            )
        }
        #expect(holds.allSatisfy { $0 < .milliseconds(100) })
    }
}
