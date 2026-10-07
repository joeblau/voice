/// An on-device model Blau downloads and manages.
///
/// The cases are ordered the way the manager fetches them on a fresh
/// install: the small, required models first, then the large optional
/// second-pass model.
public enum ModelID: String, CaseIterable, Codable, Hashable, Sendable {
    /// Silero VAD v6 (Core ML): speech start and end.
    case sileroVAD
    /// WeSpeaker ResNet34 speaker embeddings (256-d) for voice ID.
    case speakerEmbedding
    /// Parakeet realtime EOU 120M at 320 ms chunks: streaming ASR with
    /// end-of-utterance detection.
    case parakeetRealtimeEOU
    /// Parakeet TDT 0.6B v3: the second pass that adds punctuation and
    /// accuracy. Optional; Blau transcribes without it.
    case parakeetTDTv3

    /// Short name for Settings and onboarding.
    public var displayName: String {
        switch self {
        case .sileroVAD: "Voice activity detection"
        case .speakerEmbedding: "Voice ID"
        case .parakeetRealtimeEOU: "Live transcription"
        case .parakeetTDTv3: "High-accuracy transcription"
        }
    }

    /// One line on what the model does for the user.
    public var summary: String {
        switch self {
        case .sileroVAD: "Detects when you start and stop speaking (Silero VAD)."
        case .speakerEmbedding: "Recognizes your voice so Blau only answers you (WeSpeaker)."
        case .parakeetRealtimeEOU: "Turns speech into text as you talk (Parakeet realtime)."
        case .parakeetTDTv3: "Adds punctuation and fixes words after each sentence (Parakeet TDT v3)."
        }
    }

    /// Whether Blau needs the model before it can listen. Optional models
    /// improve quality and can be skipped or deleted.
    public var isRequired: Bool {
        switch self {
        case .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU: true
        case .parakeetTDTv3: false
        }
    }
}
