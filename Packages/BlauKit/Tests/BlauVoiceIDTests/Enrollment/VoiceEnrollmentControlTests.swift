import BlauAudio
import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

// MARK: - Fakes

/// A microphone that behaves like the capture hub: it delivers `frames`,
/// then either goes quiet without finishing its stream (the hub only
/// finishes at deinit) or, with `finishesAfterFrames`, finishes it (the
/// microphone stopped underneath the enrollment).
final class HubLikeEnrollmentAudio: EnrollmentAudioSource {
    private struct State {
        var started = false
        var startCount = 0
        var continuations: [AsyncStream<AudioFrame>.Continuation] = []
    }

    private let script: [AudioFrame]
    private let finishesAfterFrames: Bool
    private let state = Mutex(State())

    init(frames: [AudioFrame], finishesAfterFrames: Bool = false) {
        self.script = frames
        self.finishesAfterFrames = finishesAfterFrames
    }

    var isStarted: Bool { state.withLock { $0.started } }
    var startCount: Int { state.withLock { $0.startCount } }

    func start() async throws {
        state.withLock {
            $0.started = true
            $0.startCount += 1
        }
    }

    func stop() async {
        state.withLock { $0.started = false }
    }

    func frames() -> AsyncStream<AudioFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioFrame.self)
        for frame in script { continuation.yield(frame) }
        if finishesAfterFrames {
            continuation.finish()
        } else {
            // Kept open: no more audio, and no end either.
            state.withLock { $0.continuations.append(continuation) }
        }
        return stream
    }
}

/// A store whose saves wait for ``release()``, to catch the enrollment
/// mid-save; or whose reads fail.
actor GatedVoiceprintStore: VoiceprintStoring {
    struct ReadFailure: Error {}

    let inner = InMemoryVoiceprintStore()
    private let failsReads: Bool
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(failsReads: Bool = false) {
        self.failsReads = failsReads
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    private func gate() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func status(for model: SpeakerEmbeddingModelInfo) async throws -> VoiceprintStatus {
        if failsReads { throw ReadFailure() }
        return await inner.status(for: model)
    }

    func enroll(_ draft: VoiceprintDraft) async throws -> Voiceprint {
        await gate()
        return try await inner.enroll(draft)
    }

    func saveDeviceSet(_ draft: VoiceprintDraft) async throws -> Voiceprint {
        await gate()
        return try await inner.saveDeviceSet(draft)
    }

    func saveAdaptedCentroid(_ update: AdaptedVoiceprintCentroid) async throws -> Voiceprint {
        try await inner.saveAdaptedCentroid(update)
    }

    func resetAdaptation(for model: SpeakerEmbeddingModelInfo, at date: Date) async throws -> Voiceprint {
        try await inner.resetAdaptation(for: model, at: date)
    }

    func deleteVoiceprint() async throws {
        await inner.deleteVoiceprint()
    }
}

// MARK: - Tests

/// The enrollment's controls against a live-like microphone: Done, a
/// microphone that stops underneath a clip, cancelling while saving, double
/// taps, and the idle microphone after a rejection (review of #46).
@Suite("Voice enrollment controls", .timeLimit(.minutes(1)))
@MainActor
struct VoiceEnrollmentControlTests {
    let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM

    func enrollment(
        plan: EnrollmentPlan = .enrollment, audio: any EnrollmentAudioSource,
        store: any VoiceprintStoring = InMemoryVoiceprintStore(), clock: any BlauClock = SystemClock()
    ) -> VoiceEnrollment {
        VoiceEnrollment(
            plan: plan, audio: audio, loadEmbedder: { ScriptedSpeakerEmbedder() }, store: store,
            deviceModel: "iPhone18,1", clock: clock)
    }

    /// `duration` of the owner talking, as 20 ms frames.
    func speech(_ duration: Duration) -> [AudioFrame] {
        EnrollmentAudio.frames(of: EnrollmentAudio.clip(duration: duration))
    }

    /// Yields until `condition` holds; `false` once the suite's time limit
    /// cancels the test, so a regression fails instead of hanging.
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        while !condition() {
            if Task.isCancelled { return false }
            await Task.yield()
        }
        return true
    }

    /// Awaits `run`; if the time limit cancels the test first, cancels the
    /// enrollment, so a regression fails instead of hanging the suite.
    func finish(_ run: Task<Void, Never>, _ session: VoiceEnrollment) async {
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            Task { @MainActor in await session.cancel() }
        }
    }

    /// Waits until the clip being recorded has taken in `elapsed` of audio.
    func waitUntilRecorded(_ session: VoiceEnrollment, _ elapsed: Duration) async -> Bool {
        await waitUntil {
            if case .recording(let meter) = session.phase { return meter.elapsed >= elapsed }
            return false
        }
    }

    func rejection(_ phase: VoiceEnrollment.Phase) -> [EnrollmentClipIssue]? {
        if case .rejected(let issues, _) = phase { return issues }
        return nil
    }

    // MARK: Done and a stopped microphone

    /// The capture hub stops delivering frames without finishing its
    /// stream when the microphone stops; Done must still end the clip.
    @Test func doneEndsAClipWhoseAudioStoppedArriving() async {
        let audio = HubLikeEnrollmentAudio(frames: speech(.seconds(2)))
        let session = enrollment(audio: audio)
        let run = Task { await session.start() }
        #expect(await waitUntilRecorded(session, .seconds(2)))

        session.finishClip()
        await finish(run, session)
        guard case .tooShort? = rejection(session.phase)?.first else {
            Issue.record("Expected a short clip, got \(session.phase)")
            return
        }
        #expect(session.recordedDuration == .seconds(2))
        await session.cancel()
        #expect(!audio.isStarted)
    }

    @Test func doneBeforeAnyAudioRejectsTheClipAsTooShort() async {
        let audio = HubLikeEnrollmentAudio(frames: [])
        let session = enrollment(audio: audio)
        let run = Task { await session.start() }
        #expect(
            await waitUntil {
                if case .recording = session.phase { return true }
                return false
            })
        session.finishClip()
        await finish(run, session)
        guard case .tooShort? = rejection(session.phase)?.first else {
            Issue.record("Expected a short clip, got \(session.phase)")
            return
        }
        await session.cancel()
    }

    /// An interruption or the Live Activity's Stop ends the frame stream
    /// mid-clip: the enrollment fails and lets go of the microphone
    /// instead of waiting on "Listening" forever.
    @Test func aMicrophoneThatStopsMidClipFailsTheEnrollment() async {
        let audio = HubLikeEnrollmentAudio(frames: speech(.seconds(2)), finishesAfterFrames: true)
        let session = enrollment(audio: audio)
        await session.start()
        #expect(session.phase == .failed(.microphoneStopped))
        #expect(!audio.isStarted)
        #expect(session.recordedDuration == .zero)
    }

    @Test func aMicrophoneThatStopsBeforeAnyAudioFailsTheEnrollment() async {
        let audio = HubLikeEnrollmentAudio(frames: [], finishesAfterFrames: true)
        let session = enrollment(audio: audio)
        await session.start()
        #expect(session.phase == .failed(.microphoneStopped))
        #expect(!audio.isStarted)
    }

    /// The live source's frames end when the keeper stops delivering audio.
    @Test func conversationFramesEndWhenTheKeeperStops() async {
        for stopped: AudioSessionKeeper.Status in [.inactive, .interrupted, .paused] {
            let (frames, frameSink) = AsyncStream.makeStream(of: AudioFrame.self)
            let (statuses, statusSink) = AsyncStream.makeStream(of: AudioSessionKeeper.Status.self)
            let stream = ConversationEnrollmentAudio.frames(frames, endingWhen: statuses)
            var iterator = stream.makeAsyncIterator()

            statusSink.yield(.live)
            let frame = AudioFrame(samples: [Float](repeating: 0.1, count: 320), sampleOffset: 0)
            frameSink.yield(frame)
            #expect(await iterator.next() == frame)

            // The hub's own stream never finishes; the keeper stopping does.
            statusSink.yield(stopped)
            #expect(await iterator.next() == nil, "\(stopped)")
            frameSink.finish()
            statusSink.finish()
        }
    }

    @Test func onlyStatusesWithoutAudioEndTheFrames() {
        let delivering: [AudioSessionKeeper.Status] = [.starting, .live, .recovering]
        let stopped: [AudioSessionKeeper.Status] = [
            .inactive, .interrupted, .paused, .failed(.microphonePermissionDenied),
        ]
        #expect(delivering.allSatisfy(ConversationEnrollmentAudio.isDeliveringAudio))
        #expect(!stopped.contains(where: ConversationEnrollmentAudio.isDeliveringAudio))
    }

    // MARK: Cancel while saving

    /// The save can't be taken back, so a cancel that lands while it runs
    /// does nothing and the enrollment reports what was stored.
    @Test func cancellingWhileSavingIsIgnoredAndTheVoiceprintIsReported() async throws {
        let store = GatedVoiceprintStore()
        let audio = ScriptedEnrollmentAudio(speed: nil)
        let session = enrollment(audio: audio, store: store)
        let run = Task { await session.start() }
        #expect(await waitUntil { session.phase == .saving })

        #expect(!session.canCancel)
        await session.cancel()
        #expect(session.phase == .saving)

        await store.release()
        await finish(run, session)
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(try await store.status(for: model) == .enrolled(voiceprint))
        #expect(!audio.isStarted)
    }

    @Test func cancelIsAvailableUntilSaving() async {
        let session = enrollment(audio: ScriptedEnrollmentAudio(speed: nil))
        #expect(session.canCancel)
        await session.start()
        guard case .finished = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(!session.canCancel)
    }

    // MARK: Double taps

    @Test func twoStartsRunOneEnrollment() async {
        let audio = ScriptedEnrollmentAudio(speed: nil)
        let session = enrollment(audio: audio)
        // Two taps queued back to back: both run before either suspends.
        let first = Task { await session.start() }
        let second = Task { await session.start() }
        await finish(first, session)
        await finish(second, session)
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(audio.startCount == 1)
        #expect(voiceprint.clipCount == 4)
        #expect(session.results.count == 4)
    }

    @Test func twoRetriesRecordThePromptOnce() async {
        let audio = ScriptedEnrollmentAudio(voices: [.owner, .silence, .owner], speed: nil)
        let session = enrollment(audio: audio)
        await session.start()
        #expect(rejection(session.phase) != nil)
        let recordedBefore = session.recordedDuration

        let first = Task { await session.retry() }
        let second = Task { await session.retry() }
        await finish(first, session)
        await finish(second, session)
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(voiceprint.clipCount == 4)
        // Three more clips (prompts 2-4) at about 7 s each, not six.
        #expect(session.recordedDuration - recordedBefore < .seconds(24), "\(session.recordedDuration)")
    }

    // MARK: Idle microphone

    /// A rejection nobody retries turns the microphone (and with it the
    /// recording indicator and background audio) off; Try Again turns it
    /// back on.
    @Test func anIdleRejectionTurnsTheMicrophoneOffUntilRetry() async {
        let clock = ManualClock()
        let audio = ScriptedEnrollmentAudio(voices: [.owner, .silence, .owner], speed: nil)
        let session = enrollment(audio: audio, clock: clock)
        await session.start()
        #expect(rejection(session.phase) != nil)
        #expect(audio.isStarted)

        #expect(await waitUntil { clock.sleeperCount > 0 })
        clock.advance(by: .seconds(29))
        for _ in 0..<50 { await Task.yield() }
        #expect(audio.isStarted, "Still within the timeout")

        clock.advance(by: .seconds(1))
        #expect(await waitUntil { !audio.isStarted })
        #expect(audio.stopCount == 1)
        #expect(rejection(session.phase) != nil, "Still waiting for Try Again")

        await session.retry()
        guard case .finished(let voiceprint) = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(voiceprint.clipCount == 4)
        #expect(audio.startCount == 2)
        #expect(!audio.isStarted)
    }

    @Test func aPromptRetryKeepsTheMicrophoneOn() async {
        let clock = ManualClock()
        let audio = ScriptedEnrollmentAudio(voices: [.owner, .silence, .owner], speed: nil)
        let session = enrollment(audio: audio, clock: clock)
        await session.start()
        await session.retry()
        guard case .finished = session.phase else {
            Issue.record("Expected finished, got \(session.phase)")
            return
        }
        #expect(audio.startCount == 1)
        // The idle timeout was called off: nothing is left sleeping.
        for _ in 0..<50 { await Task.yield() }
        #expect(clock.sleeperCount == 0)
    }

    // MARK: Store errors

    /// A store read error isn't "no voiceprint".
    @Test func aTopUpThatCantReadTheVoiceprintSaysSo() async {
        let audio = ScriptedEnrollmentAudio(speed: nil)
        let session = enrollment(plan: .topUp, audio: audio, store: GatedVoiceprintStore(failsReads: true))
        await session.start()
        guard case .failed(.voiceprintUnavailable) = session.phase else {
            Issue.record("Expected voiceprintUnavailable, got \(session.phase)")
            return
        }
        #expect(!audio.isStarted)
    }
}
