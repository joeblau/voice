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
    /// The shared text embedding model (EmbeddingGemma-300M, 256-d int8;
    /// #59, #60) behind memory search and topic segmentation, loaded by
    /// BlauMemory's `TextEmbeddingService`. Optional: Blau listens without
    /// it, and topics fall back to Apple's contextual embedding. Not in the
    /// pinned manifest until the converted model is hosted (docs/models.md).
    case textEmbedding

    /// Short name for Settings and onboarding.
    public var displayName: String {
        switch self {
        case .sileroVAD: "Voice activity detection"
        case .speakerEmbedding: "Voice ID"
        case .parakeetRealtimeEOU: "Live transcription"
        case .parakeetTDTv3: "High-accuracy transcription"
        case .textEmbedding: "Memory search"
        }
    }

    /// One line on what the model does for the user.
    public var summary: String {
        switch self {
        case .sileroVAD: "Detects when you start and stop speaking (Silero VAD)."
        case .speakerEmbedding: "Recognizes your voice so Blau only answers you (WeSpeaker)."
        case .parakeetRealtimeEOU: "Turns speech into text as you talk (Parakeet realtime)."
        case .parakeetTDTv3: "Adds punctuation and fixes words after each sentence (Parakeet TDT v3)."
        case .textEmbedding: "Finds what you talked about before and notices topic changes (EmbeddingGemma)."
        }
    }

    /// Whether Blau needs the model before it can listen. Optional models
    /// improve quality and can be skipped or deleted.
    public var isRequired: Bool {
        switch self {
        case .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU: true
        case .parakeetTDTv3, .textEmbedding: false
        }
    }

    /// Whether the model downloads only while
    /// `ModelPreferences.downloadsOptionalModels` ("Download High-Accuracy
    /// Model") is on. Other optional models download after the required ones
    /// either way.
    public var followsOptionalModelsPreference: Bool {
        self == .parakeetTDTv3
    }

    /// What the user loses by deleting the model, for the confirmation.
    public var deletionNote: String {
        switch self {
        case .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU:
            "Blau can't listen without this model. It downloads again before your next conversation."
        case .parakeetTDTv3:
            "Transcripts won't get the high-accuracy second pass until you download it again."
        case .textEmbedding:
            "Blau can't search past conversations until it downloads again."
        }
    }
}
