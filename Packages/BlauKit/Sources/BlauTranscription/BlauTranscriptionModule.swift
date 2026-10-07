import BlauCore

/// BlauTranscription: Silero VAD, streaming Parakeet ASR with end-of-utterance detection, the
/// second-pass transcriber, the `SpeechAnalyzer` fallback and the model
/// download manager.
///
/// See docs/architecture.md for the modules it may depend on.
public enum BlauTranscriptionModule: BlauModule {
    public static let summary = "Voice activity detection, streaming ASR, second pass and fallback transcriber"
}
