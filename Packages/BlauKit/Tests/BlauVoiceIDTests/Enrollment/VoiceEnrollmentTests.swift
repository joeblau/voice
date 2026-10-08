import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// The guided enrollment end to end, on synthetic audio and the scripted
/// embedder (no microphone, no model).
@Suite("Voice enrollment")
@MainActor
struct VoiceEnrollmentTests {
    struct Failure: Error, Hashable {}

    let store = InMemoryVoiceprintStore()
    let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM

    func enrollment(
        plan: EnrollmentPlan = .enrollment,
        voices: [ScriptedEnrollmentAudio.Voice] = [.owner],
        audio: ScriptedEnrollmentAudio? = nil,
        embedder: (@Sendable () async throws -> any SpeakerEmbedder)? = nil,
        clock: any BlauClock = SystemClock()
    ) -> (VoiceEnrollment, ScriptedEnrollmentAudio) {
        let audio = audio ?? ScriptedEnrollmentAudio(voices: voices, speed: nil)
        let session = VoiceEnrollment(
            plan: plan, audio: audio, loadEmbedder: embedder ?? { ScriptedSpeakerEmbedder() }, store: store,
            deviceModel: "iPhone18,1", clock: clock)
        return (session, audio)
    }

    /// The issues and restart flag of a `.rejected` phase.
    func rejection(_ phase: VoiceEnrollment.Phase) -> (issues: [EnrollmentClipIssue], restarted: Bool)? {
        if case .rejected(let issues, let restarted) = phase { return (issues, restarted) }
        return nil
    }

    @Test func aCleanEnrollmentStoresTheVoiceprintWellInsideAMinute() async throws {
        let (session, audio) = enrollment()
        #expect(session.phase == .notStarted)
        #expect(session.clipNumber == 1)
        await session.start()

        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(voiceprint.modelIdentifier == model.identifier)
        #expect(voiceprint.sets.map(\.deviceModel) == ["iPhone18,1"])
        #expect(voiceprint.clipCount == 4)
        #expect(await store.status(for: model) == .enrolled(voiceprint))

        // Every prompt was accepted once, with its quality measured.
        #expect(session.results.count == 4)
        for prompt in EnrollmentPlan.enrollment.prompts {
            let result = try #require(session.results[prompt])
            #expect(result.isAccepted)
            #expect(result.analysis.speechDuration >= .seconds(5))
            #expect(result.analysis.signalToNoise > 20)
        }
        #expect(session.results[.readSentence]?.similarity == nil)  // nothing to compare with yet
        #expect((session.results[.armsLength]?.similarity ?? 0) > 0.8)

        // ~7 s per clip: the speaking part is well under the 60 s budget.
        #expect(session.recordedDuration < .seconds(32), "\(session.recordedDuration)")
        #expect(session.recordedDuration > .seconds(24))
        #expect(session.duration != nil)

        // The microphone ran once, for the whole capture, and is off again.
        #expect(audio.startCount == 1)
        #expect(audio.stopCount == 1)
        #expect(!audio.isStarted)
    }

    @Test func theEmbeddingsSkipTheSilenceAroundTheSpeech() async throws {
        let embedder = ScriptedSpeakerEmbedder()
        let (session, _) = enrollment(embedder: { embedder })
        await session.start()
        let segments = embedder.embeddedSegments
        #expect(segments.count == 4)
        for segment in segments {
            // 6 s of speech plus 100 ms each side, not the 7.1 s clip.
            #expect(abs(segment.duration.timeInterval - 6.2) < 0.15, "\(segment.duration)")
        }
    }

    @Test func aSilentClipIsRejectedAndRetried() async throws {
        let (session, _) = enrollment(voices: [.owner, .silence, .owner])
        await session.start()
        guard case (let issues, let restarted)? = rejection(session.phase), case .tooShort? = issues.first else {
            Issue.record("Expected a short clip, got \(session.phase)")
            return
        }
        #expect(!restarted)
        #expect(session.currentPrompt == .answerQuestion)
        #expect(session.acceptedCount == 1)
        #expect(session.clipNumber == 2)
        #expect(session.lastResult?.isAccepted == false)
        // The silent clip ran to the time limit.
        #expect(session.recordedDuration > .seconds(18))

        await session.retry()
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(voiceprint.clipCount == 4)
    }

    @Test func anotherSpeakerIsRejectedAsInconsistent() async throws {
        let (session, _) = enrollment(voices: [.owner, .owner, .other, .owner])
        await session.start()
        guard case (let issues, false)? = rejection(session.phase),
            case .inconsistent(let similarity, _)? = issues.first
        else {
            Issue.record("Expected an inconsistent clip, got \(session.phase)")
            return
        }
        #expect(similarity < 0.4)
        #expect(session.currentPrompt == .speakQuietly)
        await session.retry()
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(voiceprint.clipCount == 4)
    }

    /// The first clip was someone else: nothing to compare it with, so it is
    /// accepted; the owner's next clip fails against it twice, and with one
    /// clip there's no telling which is wrong, so the capture starts over.
    @Test func twoClipsThatDisagreeStartOver() async throws {
        let (session, _) = enrollment(voices: [.other, .owner, .owner, .owner])
        await session.start()
        guard case (_, false)? = rejection(session.phase) else {
            Issue.record("Expected a rejected clip, got \(session.phase)")
            return
        }
        await session.retry()
        guard case (let issues, true)? = rejection(session.phase), case .inconsistent? = issues.first else {
            Issue.record("Expected a restart, got \(session.phase)")
            return
        }
        #expect(session.acceptedCount == 0)
        #expect(session.currentPrompt == .readSentence)
        #expect(session.results.count == 1)
        await session.retry()
        guard case .finished = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
    }

    @Test func aTopUpAddsThisDevicesSet() async throws {
        let iphone = VoiceprintDraft(
            model: model, deviceModel: "iPhone17,1",
            embeddings: try await ScriptedSpeakerEmbedder().embed(
                [EnrollmentAudio.clip(duration: .seconds(6)), EnrollmentAudio.clip(duration: .seconds(5))]),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.enroll(iphone)

        let (session, _) = enrollment(plan: .topUp)
        await session.start()
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(Set(voiceprint.sets.map(\.deviceModel)) == ["iPhone17,1", "iPhone18,1"])
        #expect(voiceprint.set(forDevice: "iPhone18,1")?.embeddings.count == 3)
        #expect(session.recordedDuration < .seconds(24))
    }

    @Test func aTopUpRejectsSomeoneElse() async throws {
        let embeddings = try await ScriptedSpeakerEmbedder().embed([EnrollmentAudio.clip(duration: .seconds(6))])
        try await store.enroll(
            VoiceprintDraft(model: model, deviceModel: "iPhone17,1", embeddings: embeddings, recordedAt: .now))
        let (session, _) = enrollment(plan: .topUp, voices: [.other])
        await session.start()
        guard case (let issues, false)? = rejection(session.phase), case .doesNotMatchVoiceprint? = issues.first else {
            Issue.record("Expected doesNotMatchVoiceprint, got \(session.phase)")
            return
        }
    }

    @Test func aTopUpWithoutAVoiceprintFails() async {
        let (session, audio) = enrollment(plan: .topUp)
        await session.start()
        #expect(session.phase == .failed(.notEnrolled))
        #expect(!audio.isStarted)
    }

    @Test func aDeniedMicrophoneFails() async {
        let audio = ScriptedEnrollmentAudio(
            speed: nil, startError: VoiceEnrollmentError.microphoneUnavailable("denied"))
        let (session, _) = enrollment(audio: audio)
        await session.start()
        #expect(session.phase == .failed(.microphoneUnavailable("denied")))
    }

    @Test func aMissingModelFailsAndReleasesTheMicrophone() async {
        let (session, audio) = enrollment(embedder: { throw Failure() })
        await session.start()
        guard case .failed(.modelUnavailable) = session.phase else {
            Issue.record("Expected modelUnavailable, got \(session.phase)")
            return
        }
        #expect(audio.startCount == 1)
        #expect(!audio.isStarted)
        #expect(await store.status(for: model) == .notEnrolled)
    }

    @Test func cancellingStopsTheMicrophoneAndStoresNothing() async throws {
        let clock = ManualClock()
        // Real-time pacing on a clock that never moves: the first clip
        // records forever.
        let audio = ScriptedEnrollmentAudio(speed: 1, clock: clock)
        let (session, _) = enrollment(audio: audio, clock: clock)
        let run = Task { await session.start() }
        while session.phase == .notStarted || session.phase == .preparing { await Task.yield() }
        guard case .recording = session.phase else {
            Issue.record("Expected recording, got \(session.phase)")
            return
        }
        await session.cancel()
        await run.value
        #expect(session.phase == .cancelled)
        #expect(!audio.isStarted)
        #expect(await store.status(for: model) == .notEnrolled)
    }

    @Test func doneEndsTheClipEarly() async throws {
        let clock = ManualClock()
        let audio = ScriptedEnrollmentAudio(speed: 1, clock: clock)
        let (session, _) = enrollment(audio: audio, clock: clock)
        let run = Task { await session.start() }
        // Let about 2 s of speech through, then press Done.
        while session.phase == .notStarted || session.phase == .preparing { await Task.yield() }
        for _ in 0..<130 {
            clock.advance(by: .milliseconds(20))
            for _ in 0..<20 { await Task.yield() }
        }
        session.finishClip()
        while case .recording = session.phase {
            clock.advance(by: .milliseconds(20))
            await Task.yield()
        }
        await run.value
        guard case (let issues, false)? = rejection(session.phase), case .tooShort? = issues.first else {
            Issue.record("Expected a short clip, got \(session.phase)")
            return
        }
        await session.cancel()
    }
}
