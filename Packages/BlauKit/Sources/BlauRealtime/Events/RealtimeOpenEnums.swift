/// A string-valued protocol field with a set of known values that the server
/// may extend at any time (a new item status, role or error type).
///
/// Modelled as a struct with static constants rather than a Swift `enum`, so
/// a value Blau doesn't know yet decodes instead of failing the whole event.
/// Compare against the constants (`status == .completed`) and fall through
/// to a default for anything else.
public protocol RealtimeOpenEnum: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension RealtimeOpenEnum {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Who a conversation message is from.
public struct RealtimeRole: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let user: Self = "user"
    public static let assistant: Self = "assistant"
    public static let system: Self = "system"
}

/// Processing status of a conversation item.
public struct RealtimeItemStatus: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let inProgress: Self = "in_progress"
    public static let completed: Self = "completed"
    public static let cancelled: Self = "cancelled"
    public static let incomplete: Self = "incomplete"
}

/// The kind of a content part inside a message item.
public struct RealtimeContentType: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// User text, as Blau sends committed utterances.
    public static let inputText: Self = "input_text"
    /// User audio.
    public static let inputAudio: Self = "input_audio"
    /// General text (assistant history, text responses).
    public static let text: Self = "text"
    /// Assistant audio, with its `transcript`.
    public static let audio: Self = "audio"
    /// The verbatim line of a `force_message` item.
    public static let outputText: Self = "output_text"
}

/// Status of a response (`response.created`, `response.done`).
public struct RealtimeResponseStatus: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let inProgress: Self = "in_progress"
    public static let completed: Self = "completed"
    /// Cancelled by `response.cancel` (barge-in).
    public static let cancelled: Self = "cancelled"
    public static let incomplete: Self = "incomplete"
    public static let failed: Self = "failed"
}

/// Output modality of a response.
public struct RealtimeModality: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let text: Self = "text"
    public static let audio: Self = "audio"
}

/// The `type` of an `error` event.
public struct RealtimeErrorType: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A malformed client event.
    public static let invalidRequest: Self = "invalid_request_error"
    /// A client event type the server doesn't support.
    public static let invalidEvent: Self = "invalid_event"
    /// A server failure.
    public static let internalError: Self = "internal_error"
    /// The session timed out for inactivity.
    public static let timeout: Self = "timeout"
    /// The session hit the maximum conversation duration (120 minutes).
    public static let maxDuration: Self = "max_duration"
}

/// Audio codec for session input or output.
public struct RealtimeAudioFormatType: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Raw little-endian PCM16. Blau's choice: 24 kHz mono.
    public static let pcm: Self = "audio/pcm"
    /// G.711 µ-law.
    public static let pcmu: Self = "audio/pcmu"
    /// G.711 A-law.
    public static let pcma: Self = "audio/pcma"
    /// Raw Opus packets at 24 kHz.
    public static let opus: Self = "audio/opus"
}

/// How audio travels on the WebSocket.
public struct RealtimeAudioTransport: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Base64 inside JSON events (`input_audio_buffer.append`,
    /// `response.output_audio.delta`). The default.
    public static let json: Self = "json"
    /// Raw codec bytes in WebSocket binary frames, with no header. Lifecycle
    /// events stay JSON. Saves the base64 overhead (a third of the bytes).
    public static let binary: Self = "binary"
}

/// The `type` of a session's turn detection.
public struct RealtimeTurnDetectionType: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The server detects speech and responds on its own.
    public static let serverVAD: Self = "server_vad"
}

/// `reasoning.effort` for models that support it.
public struct RealtimeReasoningEffort: RealtimeOpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let high: Self = "high"
    /// `"none"`: no reasoning. Named `disabled` so it can't be confused
    /// with `Optional.none`.
    public static let disabled: Self = "none"
}
