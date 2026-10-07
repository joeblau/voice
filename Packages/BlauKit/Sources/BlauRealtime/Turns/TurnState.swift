import BlauAudio
import BlauCore
import Foundation

/// Where the conversation stands, as the turn orchestrator sees it (#36).
///
/// One turn goes
/// `listening → userSpeaking → committing → agentThinking → agentSpeaking → listening`.
/// `paused` is the state outside a conversation (before ``TurnOrchestrator/start(conversationID:)``
/// and after ``TurnOrchestrator/stop()``); `error` reports a turn that failed
/// and is left as soon as the user speaks again.
public enum TurnState: Sendable, Hashable, CustomStringConvertible {
    /// No conversation is running.
    case paused
    /// Waiting for the user.
    case listening
    /// The user is talking: ASR partials are arriving.
    case userSpeaking
    /// A final utterance arrived and its text is being sent to Grok.
    case committing
    /// The text is committed and a response requested; no audio yet.
    case agentThinking
    /// Grok's reply is playing.
    case agentSpeaking
    /// The last turn failed. The next partial or utterance moves on.
    case error(TurnFailure)

    /// A short, stable name for logs, signposts and accessibility.
    public var name: String {
        switch self {
        case .paused: "paused"
        case .listening: "listening"
        case .userSpeaking: "userSpeaking"
        case .committing: "committing"
        case .agentThinking: "agentThinking"
        case .agentSpeaking: "agentSpeaking"
        case .error: "error"
        }
    }

    public var description: String { name }

    /// Whether Grok is working on or speaking a reply.
    public var isAgentActive: Bool {
        switch self {
        case .committing, .agentThinking, .agentSpeaking: true
        default: false
        }
    }
}

/// Why a turn failed.
public struct TurnFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// The realtime connection couldn't be opened, or was lost for good.
        case connection
        /// Grok reported the response as failed, or never started it
        /// (no `response.created` within the response timeout).
        case response
        /// Writing the transcript failed.
        case persistence
    }

    public var kind: Kind
    /// A description for logs and the debug UI. Never contains what the
    /// user said.
    public var message: String
    /// Whether the user has to do something (add or fix their xAI key)
    /// before trying again.
    public var requiresUserAction: Bool

    public init(kind: Kind, message: String, requiresUserAction: Bool = false) {
        self.kind = kind
        self.message = message
        self.requiresUserAction = requiresUserAction
    }

    public var description: String { "\(kind.rawValue): \(message)" }
}

/// Token usage summed over a conversation's responses, from each
/// `response.done` (cancelled ones included: they are billed too).
public struct RealtimeUsageTotals: Sendable, Hashable {
    /// Responses whose `response.done` arrived.
    public var responses = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var totalTokens = 0
    /// User text items sent to Grok (`conversation.item.create` with
    /// `input_text`). xAI bills each one as a text input.
    public var textInputs = 0
    /// Reply audio received (`response.output_audio.delta`), at the
    /// session's output rate. xAI bills speech-to-speech per minute of audio.
    public var outputAudio: Duration = .zero

    public init() {}

    /// Adds one response's usage. A `nil` usage still counts the response.
    public mutating func add(_ usage: RealtimeResponse.Usage?) {
        responses += 1
        guard let usage else { return }
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        inputTokens += input
        outputTokens += output
        totalTokens += usage.totalTokens ?? (input + output)
    }
}

/// Everything the UI and the HUD show about the voice loop at one moment.
public struct TurnSnapshot: Sendable, Equatable {
    public var state: TurnState
    /// The realtime connection.
    public var connection: RealtimeClient.ConnectionState
    /// The conversation being recorded, while running.
    public var conversationID: ConversationID?
    /// The user's speech in progress (the latest ASR partial), shown live.
    public var userPartial: String?
    /// Grok's reply so far, from `response.output_audio_transcript.delta`.
    /// Empty between replies.
    public var agentText: String
    /// Committed utterances waiting for the connection to come back.
    public var queuedUtterances: Int
    /// Turns that got a complete reply.
    public var completedTurns: Int
    /// End of utterance → first audio, and whole-turn durations.
    public var latency: TurnLatencyStatistics
    /// Token usage so far in this conversation.
    public var usage: RealtimeUsageTotals
    /// The realtime session's continuity: live, reconnecting, resuming or
    /// being renewed, its age, and how often it was renewed (#39).
    public var session: RealtimeSessionContinuity
    /// How many times the user barged in on Grok this conversation (#37).
    public var bargeIns: Int
    /// The latest barge-in: what was cut and how fast it went silent.
    public var lastBargeIn: BargeInRecord?
    /// The stored agent utterances (`Utterance.id`) the user cut short this
    /// conversation, by barging in or by saying something new, so the
    /// transcript can mark them as interrupted. Their stored text is what
    /// was heard.
    public var interruptedAgentUtterances: Set<UUID>
    /// Grok's reply so far, one entry per message item, in order: the
    /// transcript next to the stored utterance and the audio it belongs to.
    /// The chat transcript (#42) reveals each one as its audio plays.
    /// Empty between replies, like ``agentText``.
    public var agentSpeech: [AgentSpeech]

    public init(
        state: TurnState = .paused,
        connection: RealtimeClient.ConnectionState = .disconnected(nil),
        conversationID: ConversationID? = nil,
        userPartial: String? = nil,
        agentText: String = "",
        queuedUtterances: Int = 0,
        completedTurns: Int = 0,
        latency: TurnLatencyStatistics = TurnLatencyStatistics(),
        usage: RealtimeUsageTotals = RealtimeUsageTotals(),
        session: RealtimeSessionContinuity = RealtimeSessionContinuity(),
        bargeIns: Int = 0,
        lastBargeIn: BargeInRecord? = nil,
        interruptedAgentUtterances: Set<UUID> = [],
        agentSpeech: [AgentSpeech] = []
    ) {
        self.state = state
        self.connection = connection
        self.conversationID = conversationID
        self.userPartial = userPartial
        self.agentText = agentText
        self.queuedUtterances = queuedUtterances
        self.completedTurns = completedTurns
        self.latency = latency
        self.usage = usage
        self.session = session
        self.bargeIns = bargeIns
        self.lastBargeIn = lastBargeIn
        self.interruptedAgentUtterances = interruptedAgentUtterances
        self.agentSpeech = agentSpeech
    }
}

extension TurnSnapshot {
    /// One message item of Grok's reply in progress.
    public struct AgentSpeech: Sendable, Hashable {
        /// The id the agent utterance is (or will be) stored under.
        public var utteranceID: UUID
        /// Where its audio plays: ask the player how much was heard.
        public var playbackID: PlaybackItemID
        /// The transcript received so far.
        public var transcript: String
        /// Wall-clock time the item started (its first audio or text).
        public var startedAt: Date?

        public init(utteranceID: UUID, playbackID: PlaybackItemID, transcript: String, startedAt: Date? = nil) {
            self.utteranceID = utteranceID
            self.playbackID = playbackID
            self.transcript = transcript
            self.startedAt = startedAt
        }
    }
}
