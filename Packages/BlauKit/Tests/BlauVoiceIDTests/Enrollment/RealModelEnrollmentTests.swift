import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

/// Plays prepared clips, one per subscription, then silence: real speech
/// through the enrollment flow without a microphone.
final class FixtureEnrollmentAudio: EnrollmentAudioSource {
    private let clips: [AudioFrame]
    private let subscriptions = Mutex(0)

    init(clips: [AudioFrame]) {
        self.clips = clips
    }

    func start() async throws {}
    func stop() async {}

    func frames() -> AsyncStream<AudioFrame> {
        let index = subscriptions.withLock { value in
            defer { value += 1 }
            return value
        }
        let samples = clips[min(index, clips.count - 1)].samples
        let position = Mutex(0)
        return AsyncStream(unfolding: {
            position.withLock { offset in
                defer { offset += 320 }
                let chunk: [Float] =
                    offset < samples.count
                    ? Array(samples[offset..<min(offset + 320, samples.count)])
                    : [Float](repeating: 0, count: 320)
                return AudioFrame(samples: chunk, sampleOffset: Int64(offset))
            }
        })
    }
}

/// The guided enrollment on the real WeSpeaker model and real speech (the
/// CMU ARCTIC fixtures). Off by default; point `BLAU_SPEAKER_MODEL_DIR` at
/// the installed model, as for `SpeakerEmbeddingModelTests`.
///
/// Checks that the consistency bar (the gate's accept threshold) accepts
/// one speaker's clips and rejects another speaker's, and reports how long
/// the analysis and embedding take beyond the speech itself.
@Suite(
    "Enrollment on the real model (opt-in)",
    .enabled(if: SpeakerModelEnvironment.modelDirectory != nil),
    .serialized
)
@MainActor
struct RealModelEnrollmentTests {
    /// Two of `speaker`'s sentences back to back (about 6 s of speech), with
    /// a little lead-in, as one enrollment clip.
    static func clip(_ speaker: String, _ first: String, _ second: String, in fixtures: [SpeakerFixtures.Clip])
        throws -> AudioFrame
    {
        func audio(_ utterance: String) throws -> [Float] {
            try #require(fixtures.first { $0.speaker == speaker && $0.utterance == utterance }).audio.samples
        }
        let leadIn = [Float](repeating: 0, count: 8_000)
        return AudioFrame(samples: leadIn + (try audio(first)) + (try audio(second)), sampleOffset: 0)
    }

    func run(_ clips: [AudioFrame]) async throws -> (VoiceEnrollment, Duration) {
        let directory = try #require(SpeakerModelEnvironment.modelDirectory)
        let session = VoiceEnrollment(
            plan: .enrollment, audio: FixtureEnrollmentAudio(clips: clips),
            loadEmbedder: { try await WeSpeakerEmbedder.load(modelDirectory: directory) },
            store: InMemoryVoiceprintStore(), deviceModel: "Mac")
        let clock = ContinuousClock()
        let started = clock.now
        await session.start()
        return (session, started.duration(to: clock.now))
    }

    @Test func oneSpeakersClipsEnroll() async throws {
        let fixtures = try SpeakerFixtures.load()
        for speaker in ["bdl", "clb", "rms", "slt"] {
            let clips = try [
                ("a0001", "a0002"), ("a0002", "a0003"), ("a0003", "a0001"), ("a0001", "a0003"),
            ].map { try Self.clip(speaker, $0.0, $0.1, in: fixtures) }
            let (session, elapsed) = try await run(clips)
            guard case .finished(let voiceprint) = session.phase else {
                Issue.record("\(speaker): expected finished, got \(session.phase)")
                continue
            }
            #expect(voiceprint.clipCount == 4)
            let similarities = EnrollmentPlan.enrollment.prompts.compactMap { session.results[$0]?.similarity }
            print(
                "\(speaker): enrolled in \(elapsed) of compute for \(session.recordedDuration) of audio; "
                    + "similarities \(similarities.map { String(format: "%.2f", $0) })")
            // Speaking takes ~25 s; analysis and embedding must leave room
            // for it inside the one-minute budget.
            #expect(elapsed < .seconds(15))
        }
    }

    @Test func anotherSpeakersClipIsRejected() async throws {
        let fixtures = try SpeakerFixtures.load()
        let clips = try [
            Self.clip("bdl", "a0001", "a0002", in: fixtures), Self.clip("bdl", "a0002", "a0003", in: fixtures),
            Self.clip("slt", "a0001", "a0002", in: fixtures),
        ]
        let (session, _) = try await run(clips)
        guard case .rejected(let issues, false) = session.phase, case .inconsistent(let similarity, _)? = issues.first
        else {
            Issue.record("Expected the other speaker's clip to be rejected, got \(session.phase)")
            return
        }
        print("Another speaker scored \(similarity) against the enrolled clips")
        #expect(session.currentPrompt == .speakQuietly)
    }
}
