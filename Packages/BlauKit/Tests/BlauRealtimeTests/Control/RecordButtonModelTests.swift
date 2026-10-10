import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

@Suite("RecordButtonModel", .timeLimit(.minutes(1)))
@MainActor
struct RecordButtonModelTests {
    private struct MicDenied: LocalizedError {
        var errorDescription: String? { "Microphone access is off." }
    }

    private let clock = ManualClock()
    private let signposts = RecordingSignpostBackend()

    private func makeModel(_ session: FakeConversationSession) -> RecordButtonModel {
        RecordButtonModel(
            session: session, clock: clock, signposter: Signposter(category: .ui, backend: signposts))
    }

    /// Runs `model.run()` for the duration of `body`, once it follows
    /// `session`: muted-speech activity sent before it subscribes is never
    /// seen, however long a loaded runner takes to start it (#180).
    private func whileRunning(
        _ model: RecordButtonModel, on session: FakeConversationSession, _ body: () async throws -> Void
    ) async throws {
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await until("run() to subscribe") { session.mutedSpeechSubscriberCount > 0 }
        try await body()
    }

    /// Polls `condition` on the main actor until it holds, failing after
    /// 10 s worth of polls (everything runs in process, so it normally holds
    /// within a few yields). The limit counts polls, not wall time, so a
    /// loaded runner that keeps the process off the CPU can't run it out
    /// (#180).
    private func until(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let interval = Duration.microseconds(200)
        var polls = Int(Duration.seconds(10) / interval)
        while !condition() {
            polls -= 1
            if polls < 0 {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw TimedOut(description: what)
            }
            await Task.yield()
            try await Task.sleep(for: .microseconds(200))
        }
    }

    // MARK: Start and stop

    @Test func startsIdle() {
        let model = makeModel(FakeConversationSession())
        #expect(model.phase == .idle)
        #expect(model.state == .idle)
        #expect(model.feedback == nil)
        #expect(!model.canPauseOrResume)
    }

    @Test func picksUpAConversationAlreadyRunning() {
        let session = FakeConversationSession()
        session.update(.listening)
        let model = makeModel(session)
        #expect(model.phase == .running)
        #expect(model.state == .listening)
    }

    @Test func aTapStartsListeningAndPlaysTheStartHaptic() async {
        let audio = FakeAudioService()
        let session = FakeConversationSession(audio: audio)
        let model = makeModel(session)

        await model.tap()

        #expect(session.calls == [.start])
        #expect(audio.isCapturing)
        #expect(model.phase == .running)
        #expect(model.state == .listening)
        #expect(model.feedback?.kind == .started)
        #expect(model.canPauseOrResume)
    }

    @Test func showsConnectingWhileStartingAndIgnoresTaps() async throws {
        let session = FakeConversationSession(clock: clock, startDelay: .milliseconds(180))
        let model = makeModel(session)

        let start = Task { await model.tap() }
        await clock.waitForSleepers()
        #expect(model.phase == .starting)
        #expect(model.state == .connecting)

        await model.tap()  // ignored: a start is in flight
        #expect(session.calls == [.start])

        clock.advance(by: .milliseconds(180))
        await start.value
        #expect(model.state == .listening)
        #expect(session.calls == [.start])
    }

    /// `session.start` spans the tap to listening (docs/performance.md);
    /// the issue's budget is 500 ms warm.
    @Test func measuresTapToListening() async {
        let session = FakeConversationSession(clock: clock, startDelay: .milliseconds(320))
        let model = makeModel(session)

        let start = Task { await model.tap() }
        await clock.waitForSleepers()
        #expect(signposts.openIntervals == ["session.start"])
        clock.advance(by: .milliseconds(320))
        await start.value

        #expect(model.lastStartLatency == .milliseconds(320))
        #expect(signposts.completedIntervals == ["session.start"])
        #expect(signposts.openIntervals.isEmpty)
    }

    /// The start interval ends when the microphone is live, not when
    /// `start()` returns: audio still coming up keeps it open.
    @Test func startEndsWhenTheMicrophoneIsLive() async throws {
        let session = FakeConversationSession()
        var coming = ConversationStatus.listening
        coming.audio = .starting
        session.statusAfterStart = coming
        let model = makeModel(session)

        try await whileRunning(model, on: session) {
            await model.tap()
            // Running (a tap would end it), the microphone still coming up.
            #expect(model.state == .reconnecting)
            #expect(!model.isTransitioning)
            #expect(signposts.openIntervals == ["session.start"])
            #expect(model.feedback == nil)

            clock.advance(by: .milliseconds(90))
            session.update { $0.audio = .live }
            try await until("listening") { model.state == .listening }
            #expect(signposts.completedIntervals == ["session.start"])
            #expect(model.lastStartLatency == .milliseconds(90))
            #expect(model.feedback?.kind == .started)
        }
    }

    @Test func aTapWhileRunningEndsTheConversation() async {
        let audio = FakeAudioService()
        let session = FakeConversationSession(audio: audio)
        let model = makeModel(session)
        await model.tap()

        await model.tap()

        #expect(session.calls == [.start, .stop])
        #expect(!audio.isCapturing)
        #expect(model.phase == .idle)
        #expect(model.state == .idle)
        #expect(model.feedback?.kind == .stopped)
    }

    /// Taps are only ignored while the button's own start or stop is in
    /// flight; a running conversation can always be ended.
    @Test func transitioningOnlyWhileStartingOrStopping() async {
        let session = FakeConversationSession(clock: clock, startDelay: .milliseconds(100))
        let model = makeModel(session)
        #expect(!model.isTransitioning)

        let start = Task { await model.tap() }
        await clock.waitForSleepers()
        #expect(model.isTransitioning)
        clock.advance(by: .milliseconds(100))
        await start.value
        #expect(!model.isTransitioning)

        session.update { $0.audio = .recovering }
        model.synchronize()
        #expect(model.state == .reconnecting)
        #expect(!model.isTransitioning)
    }

    /// While the audio recovers (a stall, a route change, the return to the
    /// foreground) the conversation is still running, and a tap ends it.
    @Test func aTapWhileTheAudioRecoversEndsTheConversation() async throws {
        let audio = FakeAudioService()
        let session = FakeConversationSession(audio: audio)
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            #expect(model.state == .listening)

            for recovering in [AudioSessionKeeper.Status.recovering, .starting, .inactive] {
                session.update { $0.audio = recovering }
                try await until("reconnecting (\(recovering))") { model.state == .reconnecting }
                #expect(model.phase == .running)
                #expect(model.canPauseOrResume, "the long-press menu stays available")
            }

            await model.tap()
            #expect(session.calls == [.start, .stop])
            #expect(!audio.isCapturing)
            #expect(model.phase == .idle)
            #expect(model.state == .idle)
            #expect(model.feedback?.kind == .stopped)
        }
    }

    @Test func aFailedStartShowsTheErrorAndATapRetries() async throws {
        let session = FakeConversationSession()
        session.startError = MicDenied()
        let model = makeModel(session)

        await model.tap()

        #expect(model.phase == .idle)
        #expect(model.state == .error(.couldNotStart(message: "Microphone access is off.")))
        #expect(model.startFailureMessage == "Microphone access is off.")
        #expect(model.feedback?.kind == .failed)
        #expect(signposts.completedIntervals == ["session.start"], "a failed start still ends its interval")

        model.startFailureMessage = nil  // the alert is dismissed; the error glyph stays
        #expect(model.state == .error(.couldNotStart(message: "Microphone access is off.")))

        await model.tap()
        #expect(session.calls == [.start, .start])
        #expect(model.state == .listening)
        #expect(model.failure == nil)
    }

    /// The Live Activity's Stop while the conversation starts: the start
    /// ends, and the button goes back to idle (not `.running` /
    /// `reconnecting`) without an error, an alert or a haptic.
    @Test func aStopDuringTheStartGoesQuietlyIdle() async throws {
        let audio = FakeAudioService()
        let session = FakeConversationSession(audio: audio, clock: clock, startDelay: .milliseconds(400))
        let model = makeModel(session)

        try await whileRunning(model, on: session) {
            let start = Task { await model.tap() }
            await clock.waitForSleepers()
            #expect(model.phase == .starting)

            await session.stop()  // the Live Activity's Stop
            clock.advance(by: .milliseconds(400))
            await start.value

            #expect(model.phase == .idle)
            #expect(model.state == .idle)
            #expect(model.failure == nil)
            #expect(model.startFailureMessage == nil)
            #expect(model.feedback == nil, "no haptic for a stop the user asked for")
            #expect(!session.status.isRunning)
            #expect(!audio.isCapturing, "the microphone never came on")
            #expect(signposts.endMessages(of: "session.start") == ["cancelled"])
            #expect(!model.isTransitioning)

            // The next tap starts a conversation as usual.
            let again = Task { await model.tap() }
            await clock.waitForSleepers()
            clock.advance(by: .milliseconds(400))
            await again.value
            #expect(model.state == .listening)
            #expect(session.calls == [.start, .stop, .start])
        }
    }

    @Test func aMissingAudioServiceIsExplained() async {
        let session = FakeConversationSession(audio: UnavailableService(subsystem: "audio"))
        let model = makeModel(session)
        await model.tap()
        guard case .error(.couldNotStart(let message)) = model.state else {
            Issue.record("Expected a start failure, got \(model.state)")
            return
        }
        #expect(message == "Conversations aren't available in this build of Blau yet.")
    }

    // MARK: Pause listening

    @Test func pausingMutesWithoutEndingTheConversation() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.tap()

        await model.pauseListening()
        #expect(session.calls == [.start, .setListeningPaused(true)])
        #expect(model.state == .paused)
        #expect(model.phase == .running)
        #expect(model.feedback?.kind == .paused)

        await model.pauseListening()  // already paused
        #expect(session.calls.count == 2)

        await model.resumeListening()
        #expect(session.calls.last == .setListeningPaused(false))
        #expect(model.state == .listening)
        #expect(model.feedback?.kind == .resumed)
    }

    @Test func pauseAndResumeDoNothingWithoutAConversation() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.pauseListening()
        await model.resumeListening()
        #expect(session.calls.isEmpty)
        #expect(model.feedback == nil)
    }

    @Test func aTapWhilePausedEndsTheConversation() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.tap()
        await model.pauseListening()

        await model.tap()
        #expect(session.calls.last == .stop)
        #expect(model.state == .idle)
    }

    // MARK: "You're muted"

    @Test func talkingWhilePausedShowsTheHintUntilAfterTheyStop() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            await model.pauseListening()

            session.sendMutedSpeech(.started)
            try await until("the hint") { model.isMutedSpeechHintVisible }

            session.sendMutedSpeech(.ended)
            await clock.waitForSleepers()
            #expect(model.isMutedSpeechHintVisible, "it lingers after the speech ends")
            clock.advance(by: .seconds(3))
            try await until("the hint to hide") { !model.isMutedSpeechHintVisible }
        }
    }

    @Test func speakingAgainKeepsTheHintUp() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            await model.pauseListening()
            session.sendMutedSpeech(.started)
            try await until("the hint") { model.isMutedSpeechHintVisible }
            session.sendMutedSpeech(.ended)
            await clock.waitForSleepers()

            session.sendMutedSpeech(.started)
            try await until("the linger to be cancelled") { clock.sleeperCount == 0 }
            clock.advance(by: .seconds(10))
            for _ in 0..<20 { await Task.yield() }
            #expect(model.isMutedSpeechHintVisible)
        }
    }

    @Test func resumingHidesTheHintAtOnce() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            await model.pauseListening()
            session.sendMutedSpeech(.started)
            try await until("the hint") { model.isMutedSpeechHintVisible }

            await model.resumeListening()
            #expect(!model.isMutedSpeechHintVisible)
        }
    }

    @Test func speechWhileListeningIsNotAHint() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            session.sendMutedSpeech(.started)
            for _ in 0..<20 { await Task.yield() }
            #expect(!model.isMutedSpeechHintVisible)
        }
    }

    // MARK: Following the session

    @Test func followsTheConversationsStates() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()

            session.update { $0.turn = .agentSpeaking }
            try await until("agent speaking") { model.state == .agentSpeaking }

            session.update {
                $0.turn = .listening
                $0.connection = .reconnecting(attempt: 1)
            }
            try await until("listening") { model.state == .listening }
            #expect(model.isAwaitingConnection)

            session.update { $0.turn = .error(TurnFailure(kind: .connection, message: "gone")) }
            try await until("the connection error") {
                model.state == .error(.connection(requiresUserAction: false))
            }

            session.update {
                $0.turn = .listening
                $0.connection = .connected
                $0.audio = .interrupted
            }
            try await until("the interruption") { model.state == .error(.audioInterrupted) }

            // A tap in an error state while running ends the conversation.
            await model.tap()
            #expect(session.calls.last == .stop)
            #expect(model.state == .idle)
        }
    }

    /// The Live Activity's Stop ends the conversation without the button.
    @Test func aConversationEndedElsewhereGoesIdle() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            session.update(.idle)
            try await until("idle") { model.phase == .idle }
            #expect(model.state == .idle)
        }
    }

    /// The debug Voice Loop screen starts a conversation without the button.
    @Test func aConversationStartedElsewhereShowsAsRunning() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            session.update(.listening)
            try await until("running") { model.phase == .running }
            #expect(model.state == .listening)
            #expect(signposts.records.isEmpty, "no tap, no start interval")
        }
    }

    @Test func synchronizeReadsTheSessionWithoutRunning() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        session.update(.listening)
        model.synchronize()
        #expect(model.state == .listening)
        session.update(.idle)
        model.synchronize()
        #expect(model.state == .idle)
    }

    // MARK: Levels

    @Test func metersTheMicrophoneWhileListening() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            #expect(session.levelSubscriberCount == 0, "nothing to meter while idle")
            await model.tap()
            try await until("level subscriptions") { session.levelSubscriberCount == 2 }

            for _ in 0..<10 {
                clock.advance(by: .milliseconds(20))
                session.sendInputLevel(0.9)
                for _ in 0..<5 { await Task.yield() }
            }
            try await until("the ring to rise") { model.inputLevel > 0.5 }
            #expect(model.outputLevel == 0, "Grok isn't speaking")

            await model.tap()
            #expect(model.inputLevel == 0)
            try await until("level subscriptions to end") { session.levelSubscriberCount == 0 }
        }
    }

    @Test func metersTheReplyWhileGrokSpeaks() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            try await until("level subscriptions") { session.levelSubscriberCount == 2 }

            session.sendOutputLevel(1)  // not speaking yet: ignored
            for _ in 0..<10 { await Task.yield() }
            #expect(model.outputLevel == 0)

            session.update { $0.turn = .agentSpeaking }
            try await until("agent speaking") { model.state == .agentSpeaking }
            for _ in 0..<10 {
                clock.advance(by: .milliseconds(30))
                session.sendOutputLevel(0.8)
                for _ in 0..<5 { await Task.yield() }
            }
            try await until("the reply ring to rise") { model.outputLevel > 0.5 }
        }
    }

    @Test func aPausedMicrophoneReadsSilence() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            await model.pauseListening()
            try await until("level subscriptions") { session.levelSubscriberCount == 2 }
            for _ in 0..<5 {
                clock.advance(by: .milliseconds(20))
                session.sendInputLevel(1)
                for _ in 0..<5 { await Task.yield() }
            }
            #expect(model.inputLevel == 0)
        }
    }

    @Test func stopsMeteringOffScreen() async throws {
        let session = FakeConversationSession()
        let model = makeModel(session)
        try await whileRunning(model, on: session) {
            await model.tap()
            try await until("level subscriptions") { session.levelSubscriberCount == 2 }

            model.setVisible(false)
            try await until("level subscriptions to end") { session.levelSubscriberCount == 0 }

            model.setVisible(true)
            try await until("level subscriptions again") { session.levelSubscriberCount == 2 }
        }
    }

    @Test func feedbackSequenceGrowsForRepeatedKinds() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.tap()
        await model.tap()
        let first = model.feedback
        await model.tap()
        await model.tap()
        #expect(model.feedback?.kind == .stopped)
        #expect(model.feedback != first)
    }
}
