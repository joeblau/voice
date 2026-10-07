import BlauCore

/// Who produced a stored utterance. Persisted as `Utterance.roleRaw`.
public enum UtteranceRole: String, CaseIterable, Codable, Hashable, Sendable {
    /// The enrolled user.
    case user
    /// Grok.
    case agent
    /// The app itself, for example a note that the session reconnected.
    case system

    /// The role for speech by `speaker`.
    public init(_ speaker: Speaker) {
        switch speaker {
        case .user: self = .user
        case .agent: self = .agent
        }
    }

    /// The pipeline speaker for this role, or `nil` for `system`.
    public var speaker: Speaker? {
        switch self {
        case .user: .user
        case .agent: .agent
        case .system: nil
        }
    }
}

/// Which engine produced a stored utterance's text. Persisted as
/// `Utterance.sourceRaw`.
public enum TranscriptSource: String, CaseIterable, Codable, Hashable, Sendable {
    /// On-device Parakeet (streaming EOU model, refined by the TDT second
    /// pass).
    case parakeet
    /// Apple's `SpeechAnalyzer` / `SpeechTranscriber` fallback.
    case speechAnalyzer = "speechanalyzer"
    /// Grok's output transcript (agent speech).
    case grok
}
