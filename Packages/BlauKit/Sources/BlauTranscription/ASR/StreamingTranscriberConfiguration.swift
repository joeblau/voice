import BlauCore

/// When `ParakeetStreamingTranscriber` decides an utterance is over.
///
/// The model's own end-of-utterance detector is the main signal (its
/// debounce is set on the recognizer, see `ParakeetEouRecognizer`); these
/// are the guards around it.
public struct StreamingTranscriberConfiguration: Hashable, Sendable {
    /// The VAD fallback: once VAD has reported the end of speech, the
    /// utterance is committed when this much audio has passed after the
    /// speech without the model confirming the end of the utterance or
    /// speech resuming. Measured from the end of the speech as VAD places
    /// it (to 16 ms), on the audio timeline.
    public var silenceCommitDelay: Duration

    /// The longest utterance. Longer speech is committed at this length and
    /// transcription carries on in a new utterance, so a monologue (or a
    /// room VAD never hears as silent) can't grow the hypothesis without
    /// bound or hold back the conversation.
    public var maximumUtteranceDuration: Duration

    /// Who is speaking into the microphone.
    public var speaker: Speaker

    public init(
        silenceCommitDelay: Duration = .milliseconds(900),
        maximumUtteranceDuration: Duration = .seconds(30),
        speaker: Speaker = .user
    ) {
        precondition(silenceCommitDelay >= .zero, "The silence commit delay can't be negative")
        precondition(maximumUtteranceDuration > .zero, "Utterances must be allowed some length")
        self.silenceCommitDelay = silenceCommitDelay
        self.maximumUtteranceDuration = maximumUtteranceDuration
        self.speaker = speaker
    }

    /// The defaults: commit 0.9 s after the end of speech at the latest,
    /// split utterances at 30 s.
    public static let standard = StreamingTranscriberConfiguration()

    var silenceCommitSamples: Int64 {
        silenceCommitDelay.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    var maximumUtteranceSamples: Int64 {
        maximumUtteranceDuration.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }
}

/// Why an utterance was committed.
public enum UtteranceCommitReason: String, CaseIterable, Hashable, Sendable {
    /// The model confirmed the end of the utterance.
    case endOfUtterance
    /// VAD reported the end of speech and `silenceCommitDelay` passed with
    /// no end of utterance from the model (the VAD fallback).
    case silence
    /// The utterance reached `maximumUtteranceDuration`.
    case maximumLength
    /// The audio stream ended (capture stopped or VAD closed the segment at
    /// the end of the stream).
    case streamEnded
    /// `stop()` was called mid-utterance.
    case stopped
    /// The recognizer failed; what it had decoded so far is committed.
    case recognizerFailure
}
