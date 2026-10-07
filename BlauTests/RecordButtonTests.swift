import BlauAudio
import BlauCore
import BlauRealtime
import Foundation
import SwiftUI
import Testing

@testable import Blau

/// The record button's VoiceOver text, haptics and wiring (#41). Its logic
/// is tested in BlauKit (`RecordButtonModelTests`, `RecordButtonStateTests`)
/// and its look in `RecordButtonSnapshotTests`.
@Suite("Record button")
@MainActor
struct RecordButtonTests {
    // MARK: VoiceOver

    private func spoken(_ state: RecordButtonState, awaitingConnection: Bool = false) -> RecordButtonAccessibility {
        RecordButtonAccessibility(state: state, isAwaitingConnection: awaitingConnection)
    }

    @Test func labelsSayWhatATapDoes() {
        #expect(spoken(.idle).label == "Start Conversation")
        #expect(spoken(.connecting).label == "Start Conversation")
        #expect(spoken(.error(.couldNotStart(message: "x"))).label == "Start Conversation")
        for state: RecordButtonState in [
            .listening, .agentSpeaking, .paused, .reconnecting, .stopping, .error(.audioInterrupted),
            .error(.audioUnavailable), .error(.connection(requiresUserAction: true)),
        ] {
            #expect(spoken(state).label == "End Conversation", "\(state)")
        }
    }

    @Test func valuesSayWhereTheConversationIs() {
        #expect(spoken(.idle).value == "Not listening")
        #expect(spoken(.connecting).value == "Connecting")
        #expect(spoken(.listening).value == "Listening")
        #expect(spoken(.listening, awaitingConnection: true).value == "Listening, connecting to Grok")
        #expect(spoken(.agentSpeaking).value == "Grok is speaking")
        #expect(spoken(.paused).value == "Paused, microphone muted")
        #expect(spoken(.reconnecting).value == "Reconnecting the microphone")
        #expect(spoken(.stopping).value == "Ending")
        #expect(spoken(.error(.couldNotStart(message: "x"))).value == "Couldn't start")
        #expect(spoken(.error(.connection(requiresUserAction: false))).value == "Lost the connection to Grok")
        #expect(
            spoken(.error(.connection(requiresUserAction: true))).value == "Can't reach Grok, check your xAI API key")
        #expect(spoken(.error(.audioInterrupted)).value == "Microphone in use by another app")
        #expect(spoken(.error(.audioUnavailable)).value == "Microphone unavailable")
    }

    @Test func hintsPointToPauseAndResume() {
        #expect(spoken(.listening).hint.contains("pause listening"))
        #expect(spoken(.agentSpeaking).hint.contains("pause listening"))
        #expect(spoken(.paused).hint.contains("resume listening"))
        #expect(spoken(.reconnecting).hint == "Ends the conversation.")
        #expect(spoken(.connecting).hint.isEmpty)
        #expect(spoken(.stopping).hint.isEmpty)
    }

    /// Every state has a distinct (value) description, so VoiceOver users
    /// can tell them apart.
    @Test func everyStateSoundsDifferent() {
        let states: [RecordButtonState] = [
            .idle, .connecting, .listening, .agentSpeaking, .paused, .reconnecting, .stopping,
            .error(.couldNotStart(message: "x")), .error(.connection(requiresUserAction: false)),
            .error(.connection(requiresUserAction: true)), .error(.audioInterrupted), .error(.audioUnavailable),
        ]
        let values = states.map { spoken($0).value }
        #expect(Set(values).count == values.count)
    }

    // MARK: Look and feel

    @Test func glyphsAndTints() {
        #expect(RecordButtonFace.systemImage(for: .idle) == "mic.fill")
        #expect(RecordButtonFace.systemImage(for: .listening) == "stop.fill")
        #expect(RecordButtonFace.systemImage(for: .agentSpeaking) == "speaker.wave.2.fill")
        #expect(RecordButtonFace.systemImage(for: .paused) == "mic.slash.fill")
        #expect(RecordButtonFace.systemImage(for: .error(.audioInterrupted)) == "exclamationmark.triangle.fill")
        #expect(RecordButtonFace.systemImage(for: .reconnecting) == "ellipsis")
        #expect(RecordButtonFace.tint(for: .listening) == .red)
        #expect(RecordButtonFace.tint(for: .reconnecting) == .red)
        #expect(RecordButtonFace.tint(for: .paused) == .gray)
        #expect(RecordButtonFace.tint(for: .error(.audioUnavailable)) == .orange)
        #expect(RecordButtonFace.tint(for: .idle) == .accentColor)
    }

    @Test func hapticsOnStartAndStop() {
        #expect(RecordButton.haptic(for: .started) == .start)
        #expect(RecordButton.haptic(for: .stopped) == .stop)
        #expect(RecordButton.haptic(for: .failed) == .error)
        #expect(RecordButton.haptic(for: .paused) == .impact(weight: .light))
        #expect(RecordButton.haptic(for: .resumed) == .impact(weight: .light))
    }

    // MARK: Wiring

    @Test func fakeEnvironmentsRunOnAFakeConversation() async throws {
        let environment = AppEnvironment.make(kind: .unitTest)
        let session = try #require(environment.conversation as? FakeConversationSession)
        let model = RecordButtonModel(session: session)
        await model.tap()
        #expect(model.state == .listening)
        #expect(await environment.audio.isCapturing, "the fake drives the environment's fake audio")
        await model.tap()
        #expect(model.state == .idle)
        #expect(await !environment.audio.isCapturing)
    }

    /// The live app's record button drives the voice loop (#36) over the
    /// conversation audio. Without installed speech models a start fails
    /// with a message for the user, and nothing is left running.
    @Test func liveRunsTheVoiceLoopAndExplainsAFailedStart() async throws {
        let models = SpeechModels.fixtureManager(
            root: SpeechModels.defaultFixtureRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        let environment = AppEnvironment.live(config: .fallback, persistence: .inMemory(), speechModels: models)
        let session = try #require(environment.conversation as? VoiceLoopSession)
        #expect(session.voiceLoop === environment.voiceLoop)
        #expect(session.audio.keeper === environment.conversationAudio?.keeper)
        #expect(session.status == .idle)

        let model = RecordButtonModel(session: session)
        await model.tap()

        #expect(
            model.state
                == .error(
                    .couldNotStart(message: "The speech models are still downloading. Try again when they're ready.")))
        #expect(session.status == .idle)
        #expect(await environment.conversationAudio?.keeper.status == .inactive, "the microphone was never started")
        #expect(environment.conversationAudio?.microphoneMute.isMuted == false)
    }

    @Test func pausingWithoutAConversationLeavesTheMicrophoneAlone() async throws {
        let models = SpeechModels.fixtureManager(
            root: SpeechModels.defaultFixtureRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        let environment = AppEnvironment.live(config: .fallback, persistence: .inMemory(), speechModels: models)
        let session = try #require(environment.conversation as? VoiceLoopSession)
        await session.setListeningPaused(true)
        #expect(environment.conversationAudio?.microphoneMute.isMuted == false)
        #expect(!session.status.isListeningPaused)
    }

    @Test func startFailuresReadWell() {
        #expect(
            ConversationStartFailure(VoiceLoop.StartError.modelsNotInstalled, audio: .inactive).localizedDescription
                == "The speech models are still downloading. Try again when they're ready.")
        #expect(
            ConversationStartFailure(VoiceLoop.StartError.audio("x"), audio: .failed(.microphonePermissionDenied))
                .localizedDescription
                == "Blau can't use the microphone. Turn on microphone access for Blau in Settings.")
        #expect(
            ConversationStartFailure(VoiceLoop.StartError.audio("x"), audio: .failed(.noSuitableRoute))
                .localizedDescription == "The microphone couldn't start. Try again in a moment.")
        #expect(
            ConversationStartFailure(VoiceLoop.StartError.unavailable, audio: .inactive).localizedDescription
                == "Conversations aren't available in this build of Blau.")
    }

    @Test func mutedHintRenders() throws {
        let renderer = ImageRenderer(content: MutedSpeechHint {}.frame(width: 240, height: 56))
        #expect(renderer.uiImage != nil)
    }
}
