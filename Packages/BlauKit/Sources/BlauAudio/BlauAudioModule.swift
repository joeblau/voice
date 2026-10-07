import BlauCore

/// BlauAudio: `AVAudioSession` and `AVAudioEngine` (voice processing I/O), the 16 kHz
/// capture ring buffer and its fan-out, 24 kHz PCM16 playback with barge-in
/// flush, and resampling.
///
/// See docs/architecture.md for the modules it may depend on.
public enum BlauAudioModule: BlauModule {
    public static let summary = "Audio session, capture engine and fan-out, playback and resampling"
}
