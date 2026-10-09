/// Who said something in a conversation.
public enum Speaker: String, CaseIterable, Codable, Hashable, Sendable {
    /// The enrolled user, speaking into the microphone.
    case user
    /// Grok, speaking through the realtime voice session.
    case agent
}

/// The voice ID gate's verdict on a segment of speech: is it the enrolled
/// speaker?
///
/// `accept`ed speech is committed as a user utterance and sent to Grok.
/// `uncertain` speech keeps being transcribed speculatively and is re-scored
/// once more audio arrives; if it is still uncertain at the end, the gate's
/// uncertain policy decides (#47). `reject`ed speech is dropped.
public enum SpeakerDecision: String, CaseIterable, Codable, Hashable, Sendable {
    /// The segment matches the enrolled voiceprint.
    case accept
    /// The segment is someone else (or not speech).
    case reject
    /// Not enough evidence yet either way.
    case uncertain

    /// Whether the speech is kept from Grok: the gate rejected it, or it was
    /// uncertain and the gate's uncertain policy dropped it (the gate passes
    /// those finals on marked `reject`, #47). The turn orchestrator ignores
    /// such an utterance.
    public var isRejected: Bool { self == .reject }
}
