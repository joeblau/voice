import BlauCore
import Synchronization

/// Whether the conversation is in an active turn, for the gate's uncertain
/// policy (``UncertainSpeechPolicy/commitDuringActiveTurn(minimumDuration:)``).
///
/// A turn is active while Grok is answering (thinking or speaking), and for
/// ``window`` after it last did or after the last utterance the gate
/// accepted: the user is in a back-and-forth, so a borderline segment is
/// more likely them answering than a TV across the room. Uncertain speech
/// the policy sends doesn't extend the turn, so a podcast can't keep itself
/// flowing to Grok.
///
/// The gate reports the utterances it accepts; the composition root reports
/// Grok's side from the turn orchestrator's snapshots
/// (`TurnState.isAgentActive`).
public final class ConversationTurnActivity: Sendable {
    /// How long a turn stays active after Grok's reply or the last
    /// accepted utterance.
    public let window: Duration

    private let clock: any BlauClock
    private let state = Mutex(State())

    private struct State {
        var isAgentActive = false
        /// When Grok last stopped answering (uptime).
        var agentEndedAt: Duration?
        /// When an accepted utterance was last sent (uptime).
        var userCommittedAt: Duration?
    }

    public init(window: Duration = .seconds(10), clock: any BlauClock = SystemClock()) {
        precondition(window >= .zero, "window must not be negative")
        self.window = window
        self.clock = clock
    }

    /// Grok started (`true`) or stopped (`false`) answering.
    public func agentActivityChanged(_ isActive: Bool) {
        let now = clock.uptime
        state.withLock { state in
            if state.isAgentActive, !isActive { state.agentEndedAt = now }
            state.isAgentActive = isActive
        }
    }

    /// An accepted utterance (the enrolled speaker's) was sent to Grok.
    public func userUtteranceCommitted() {
        let now = clock.uptime
        state.withLock { $0.userCommittedAt = now }
    }

    /// Whether the conversation is in an active turn now.
    public var isActive: Bool {
        let now = clock.uptime
        return state.withLock { state in
            if state.isAgentActive { return true }
            let latest = [state.agentEndedAt, state.userCommittedAt].compactMap { $0 }.max()
            return latest.map { now - $0 < window } ?? false
        }
    }

    /// Forgets everything, for a new conversation.
    public func reset() {
        state.withLock { $0 = State() }
    }
}
