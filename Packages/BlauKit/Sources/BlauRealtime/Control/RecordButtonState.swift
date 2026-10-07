import BlauAudio
import Foundation

/// What the record button shows (#41), derived from the button's own
/// `RecordButtonModel.Phase` and the conversation's `ConversationStatus`.
///
/// ```
/// idle ─tap─▶ connecting ─microphone live─▶ listening ◀─▶ agentSpeaking
///               │                              │   ▲
///          start failed               long press: pause / resume
///               ▼                              ▼   │
///             error                           paused
///
/// any running state (listening, agentSpeaking, paused, error) ─tap─▶ stopping ─▶ idle
/// ```
public enum RecordButtonState: Sendable, Hashable, CustomStringConvertible {
    /// No conversation. The microphone glyph; tapping starts one.
    case idle
    /// Starting: loading the speech pipeline and bringing up the
    /// microphone, or getting the audio back after a hiccup. A spinner.
    case connecting
    /// The microphone is live. The ring follows the input level.
    case listening
    /// Grok's reply is playing. The ring follows the output level.
    case agentSpeaking
    /// The user paused listening: the microphone is muted, the conversation
    /// goes on.
    case paused
    /// Ending the conversation. A spinner.
    case stopping
    /// Something needs attention. Tapping starts again (when the start
    /// failed) or ends the conversation (when it is still running).
    case error(RecordButtonFailure)

    /// A short, stable name for logs, tests and snapshot files.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .agentSpeaking: "agentSpeaking"
        case .paused: "paused"
        case .stopping: "stopping"
        case .error: "error"
        }
    }

    public var description: String {
        switch self {
        case .error(let failure): "error(\(failure))"
        default: name
        }
    }

    /// Whether a spinner shows (a start or stop is under way).
    public var isBusy: Bool {
        self == .connecting || self == .stopping
    }

    /// Whether the microphone is live and being listened to.
    public var isListening: Bool {
        self == .listening || self == .agentSpeaking
    }

    /// The state for a record button whose own phase is `phase`, with the
    /// conversation in `status` and the last failed start `failure`.
    public init(phase: RecordButtonModel.Phase, status: ConversationStatus, failure: RecordButtonFailure? = nil) {
        switch phase {
        case .starting:
            self = .connecting
        case .stopping:
            self = .stopping
        case .idle:
            self = failure.map(RecordButtonState.error) ?? .idle
        case .running:
            self = Self.running(status)
        }
    }

    /// A running conversation. Audio problems come first (nothing is
    /// heard), then a lost connection, then the user's pause (so a muted
    /// microphone is never shown as listening), then who is talking.
    private static func running(_ status: ConversationStatus) -> RecordButtonState {
        switch status.audio {
        case .inactive, .starting, .recovering:
            return .connecting
        case .interrupted:
            return .error(.audioInterrupted)
        case .paused, .failed:
            return .error(.audioUnavailable)
        case .live:
            break
        }
        if case .error(let failure) = status.turn, failure.kind == .connection {
            return .error(.connection(requiresUserAction: failure.requiresUserAction))
        }
        if status.isListeningPaused {
            return .paused
        }
        return status.turn == .agentSpeaking ? .agentSpeaking : .listening
    }
}

/// Why the record button shows `error`.
public enum RecordButtonFailure: Sendable, Hashable, CustomStringConvertible {
    /// The conversation couldn't start. `message` is for the user.
    case couldNotStart(message: String)
    /// The connection to Grok was lost for good. With `requiresUserAction`
    /// the xAI key is missing or was rejected.
    case connection(requiresUserAction: Bool)
    /// The system took the microphone (a call, Siri, another app).
    case audioInterrupted
    /// The audio stopped and couldn't restart by itself.
    case audioUnavailable

    public var description: String {
        switch self {
        case .couldNotStart: "couldNotStart"
        case .connection(let requiresUserAction): "connection(requiresUserAction: \(requiresUserAction))"
        case .audioInterrupted: "audioInterrupted"
        case .audioUnavailable: "audioUnavailable"
        }
    }
}
