import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

/// A spoken scene: who talks when, rendered to one capture track, and what
/// should reach Grok.
struct GateScenario {
    struct Line {
        let text: String
        let start: Double
        let end: Double
        /// Whether it is the owner talking to Blau (and should be sent).
        let isOwner: Bool
        /// The audio, `end - start` long.
        let audio: [Float]
    }

    let lines: [Line]

    /// The whole track at 16 kHz: silence (a faint room tone) between lines.
    var track: [Float] {
        let length = Int(((lines.map(\.end).max() ?? 0) + 1) * 16_000)
        var track = (0..<length).map { Float(($0 * 7_919) % 23 - 11) * 0.000_02 }
        for line in lines {
            let start = Int(SpeechScript.offset(line.start))
            for (index, sample) in line.audio.enumerated() where start + index < track.count {
                track[start + index] += sample
            }
        }
        return track
    }

    /// Runs the scene through `gate` the way the pipeline does: each line's
    /// VAD segment, then its final utterance through ``VerificationGate/filter(_:)``.
    /// Returns the texts that reached Grok and the gate's verdicts.
    func run(through gate: VerificationGate) async -> (sent: [String], verdicts: [GatedUtterance]) {
        let track = track
        let samples: @Sendable (Int64) -> Float = { index in index < track.count ? track[Int(index)] : 0 }
        let (input, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let output = gate.filter(input)
        let reader = Task {
            var texts: [String] = []
            for await event in output {
                if case .final(let utterance) = event { texts.append(utterance.text) }
            }
            return texts
        }
        for (id, line) in lines.enumerated() {
            await gate.feed(SpeechScript.segment(id, from: line.start, to: line.end, samples: samples))
            continuation.yield(.final(finalUtterance(line.text, from: line.start, to: line.end)))
        }
        continuation.finish()
        let sent = await reader.value
        var verdicts: [GatedUtterance] = []
        for await verdict in gate.verdicts {
            verdicts.append(verdict)
            if verdicts.count == lines.count { break }
        }
        return (sent, verdicts)
    }
}

/// The issue's acceptance scenarios on synthetic voices (hermetic): the
/// owner talks to Blau while a TV, a podcast and another person talk in the
/// room. Only the owner's lines may reach Grok. ``SpeakerVerifier`` runs
/// for real over ``ScriptedSpeakerEmbedder``, which tells the synthetic
/// voices apart by pitch (so levels and rooms don't matter here); the same
/// scenes on the real model, with real speech through simulated rooms and
/// loudspeakers, are in `RealModelGateScenarioTests`.
@Suite("Verification gate scenarios")
struct VerificationGateScenarioTests {
    typealias Voice = ScriptedEnrollmentAudio.Voice

    static let owner = Voice(fundamental: 140)
    static let tv = Voice(fundamental: 185, amplitude: 0.06)
    static let podcast = Voice(fundamental: 260, amplitude: 0.05)
    static let otherPerson = Voice(fundamental: 230)

    static func line(_ text: String, _ voice: Voice, from start: Double, to end: Double, isOwner: Bool)
        -> GateScenario.Line
    {
        let duration = Duration.seconds(end - start)
        var synthesizer = ScriptedEnrollmentAudio.Synthesizer(
            voice: Voice(
                fundamental: voice.fundamental, amplitude: voice.amplitude, noise: 0, leadIn: .zero, speech: duration),
            seed: UInt64(start * 10))
        var audio: [Float] = []
        let count = Int(duration.sampleCount(sampleRate: 16_000))
        while audio.count < count { audio += synthesizer.next().samples }
        return GateScenario.Line(
            text: text, start: start, end: end, isOwner: isOwner, audio: Array(audio.prefix(count)))
    }

    static func gate(configuration: VerificationGateConfiguration = .standard) async throws -> VerificationGate {
        let embedder = ScriptedSpeakerEmbedder()
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: try await SpeakerVerifierTests.ownerVoiceprint(embedder),
            gauges: PerformanceGauges())
        return VerificationGate(verifier: verifier, configuration: configuration)
    }

    static let livingRoom = GateScenario(lines: [
        line("What's on my calendar tomorrow?", owner, from: 0, to: 3.2, isOwner: true),
        line("Tonight on the news, a storm moves in.", tv, from: 5, to: 8, isOwner: false),
        line("Welcome back to the show, today we talk about sleep.", podcast, from: 9, to: 15.5, isOwner: false),
        line("Are you coming to dinner?", otherPerson, from: 16.5, to: 19, isOwner: false),
        line("Hello?", otherPerson, from: 19.5, to: 20.1, isOwner: false),
        line("Remind me to call mom at six.", owner, from: 22, to: 25, isOwner: true),
        line("Please.", owner, from: 25.4, to: 26, isOwner: true),
        line("Okay.", tv, from: 40, to: 40.6, isOwner: false),
    ])

    @Test func onlyTheOwnerReachesGrok() async throws {
        let gate = try await Self.gate()
        let (sent, verdicts) = await Self.livingRoom.run(through: gate)

        #expect(sent == Self.livingRoom.lines.filter(\.isOwner).map(\.text))
        for (line, verdict) in zip(Self.livingRoom.lines, verdicts) {
            #expect(verdict.disposition.isCommitted == line.isOwner, "\(line.text): \(verdict.disposition)")
        }
        #expect(
            verdicts.map(\.disposition) == [
                .accepted, .rejected, .rejected, .rejected, .rejected, .accepted, .accepted, .uncertainDiscarded,
            ])
    }

    /// Worst case for the uncertain policy: Grok is talking the whole time,
    /// so the turn is always active. Nothing but the owner gets through.
    @Test func nothingElseGetsThroughDuringAnActiveTurn() async throws {
        let gate = try await Self.gate()
        gate.turnActivity.agentActivityChanged(true)
        let (sent, _) = await Self.livingRoom.run(through: gate)
        #expect(sent == Self.livingRoom.lines.filter(\.isOwner).map(\.text))
    }
}
