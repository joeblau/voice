import BlauAudio
import Testing

@testable import BlauRealtime

@Suite("RecordButtonState")
struct RecordButtonStateTests {
    private func running(_ change: (inout ConversationStatus) -> Void = { _ in }) -> RecordButtonState {
        var status = ConversationStatus.listening
        change(&status)
        return RecordButtonState(phase: .running, status: status)
    }

    @Test func theButtonsOwnPhaseComesFirst() {
        #expect(RecordButtonState(phase: .idle, status: .idle) == .idle)
        #expect(RecordButtonState(phase: .starting, status: .idle) == .connecting)
        #expect(RecordButtonState(phase: .stopping, status: .listening) == .stopping)
        let failure = RecordButtonFailure.couldNotStart(message: "No microphone")
        #expect(RecordButtonState(phase: .idle, status: .idle, failure: failure) == .error(failure))
    }

    @Test func aLiveConversationListensOrPlaysTheReply() {
        #expect(running() == .listening)
        for turn in [TurnState.listening, .userSpeaking, .committing, .agentThinking] {
            #expect(running { $0.turn = turn } == .listening, "\(turn)")
        }
        #expect(running { $0.turn = .agentSpeaking } == .agentSpeaking)
    }

    /// Utterances are queued while Grok connects, so the microphone is
    /// listening even before the connection opens.
    @Test func listensWhileTheConnectionOpens() {
        #expect(running { $0.connection = .connecting(attempt: 1) } == .listening)
        #expect(running { $0.connection = .reconnecting(attempt: 2) } == .listening)
    }

    /// A running conversation whose audio is coming back is
    /// `reconnecting`, not `connecting`: it is still running, so a tap ends
    /// it (`connecting` is only the button's own start).
    @Test func audioThatIsntFlowingIsReconnectingOrAnError() {
        #expect(running { $0.audio = .starting } == .reconnecting)
        #expect(running { $0.audio = .recovering } == .reconnecting)
        #expect(running { $0.audio = .inactive } == .reconnecting)
        #expect(
            running {
                $0.audio = .recovering
                $0.isListeningPaused = true
            } == .reconnecting)
        #expect(running { $0.audio = .interrupted } == .error(.audioInterrupted))
        #expect(running { $0.audio = .paused } == .error(.audioUnavailable))
        #expect(running { $0.audio = .failed(.microphonePermissionDenied) } == .error(.audioUnavailable))
    }

    @Test func aLostConnectionIsAnError() {
        let lost = TurnFailure(kind: .connection, message: "closed")
        #expect(running { $0.turn = .error(lost) } == .error(.connection(requiresUserAction: false)))
        let badKey = TurnFailure(kind: .connection, message: "401", requiresUserAction: true)
        #expect(running { $0.turn = .error(badKey) } == .error(.connection(requiresUserAction: true)))
    }

    /// A failed response or transcript write is reported by the orchestrator
    /// and left as soon as the user speaks: the microphone is still live.
    @Test func aFailedTurnKeepsListening() {
        let response = TurnFailure(kind: .response, message: "timeout")
        #expect(running { $0.turn = .error(response) } == .listening)
    }

    /// A muted microphone is never shown as listening, even while Grok
    /// talks; audio problems still win because nothing can be heard.
    @Test func pausedOutranksWhoIsTalking() {
        #expect(running { $0.isListeningPaused = true } == .paused)
        #expect(
            running {
                $0.isListeningPaused = true
                $0.turn = .agentSpeaking
            } == .paused)
        #expect(
            running {
                $0.isListeningPaused = true
                $0.audio = .interrupted
            } == .error(.audioInterrupted))
    }

    @Test func namesAreStable() {
        let states: [RecordButtonState] = [
            .idle, .connecting, .listening, .agentSpeaking, .paused, .reconnecting, .stopping,
            .error(.audioInterrupted),
        ]
        #expect(
            states.map(\.name) == [
                "idle", "connecting", "listening", "agentSpeaking", "paused", "reconnecting", "stopping", "error",
            ])
        #expect(states.filter(\.isBusy) == [.connecting, .reconnecting, .stopping])
        #expect(states.filter(\.isListening) == [.listening, .agentSpeaking])
    }

    /// Which states are a running conversation (a tap ends it).
    @Test func runningStates() {
        let running: [RecordButtonState] = [
            .listening, .agentSpeaking, .paused, .reconnecting, .error(.audioInterrupted), .error(.audioUnavailable),
            .error(.connection(requiresUserAction: false)),
        ]
        for state in running {
            #expect(state.isRunning, "\(state)")
        }
        for state: RecordButtonState in [.idle, .connecting, .stopping, .error(.couldNotStart(message: "x"))] {
            #expect(!state.isRunning, "\(state)")
        }
    }
}
