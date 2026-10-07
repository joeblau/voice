import BlauCore

/// When `AppleTranscriber` decides an utterance is over.
///
/// The system transcriber finalizes about once per sentence; an utterance
/// is the run of finalized sentences up to a pause. These are the rules
/// around that, on the audio timeline.
public struct AppleTranscriberConfiguration: Hashable, Sendable {
    /// The pause that ends an utterance: once the last finalized word ended
    /// this long ago (and no newer words are pending), the utterance is
    /// committed. The same 0.9 s as the Parakeet transcriber's VAD fallback,
    /// so both engines split a conversation alike.
    public var silenceCommitDelay: Duration

    /// When the recognizer holds unfinalized words that haven't changed for
    /// this much audio, it is asked to finalize them (the speaker has
    /// stopped, but it is waiting for more context).
    ///
    /// Only a fallback: the system transcriber finalizes a sentence by
    /// itself 0.7–2 s after it ends, and asking it early costs accuracy
    /// (measured on the VAD fixtures, a forced finalization garbled the
    /// short sentence that followed it; see docs/apple-asr.md).
    public var finalizationRequestDelay: Duration

    /// When words are still unfinalized this long after asking, the
    /// utterance is committed with them as they are.
    public var finalizationTimeout: Duration

    /// The longest utterance. Longer speech is committed at the last
    /// finalized sentence once it is this long.
    public var maximumUtteranceDuration: Duration

    /// How much audio before the resume position the transcriber asks the
    /// capture history for when it takes over from another engine.
    public var maximumResumeLookback: Duration

    /// Who is speaking into the microphone.
    public var speaker: Speaker

    public init(
        silenceCommitDelay: Duration = .milliseconds(900),
        finalizationRequestDelay: Duration = .milliseconds(1500),
        finalizationTimeout: Duration = .milliseconds(1500),
        maximumUtteranceDuration: Duration = .seconds(30),
        maximumResumeLookback: Duration = .seconds(10),
        speaker: Speaker = .user
    ) {
        precondition(silenceCommitDelay >= .zero, "The silence commit delay can't be negative")
        precondition(finalizationRequestDelay >= .zero, "The finalization request delay can't be negative")
        precondition(finalizationTimeout >= .zero, "The finalization timeout can't be negative")
        precondition(maximumUtteranceDuration > .zero, "Utterances must be allowed some length")
        precondition(maximumResumeLookback >= .zero, "The resume lookback can't be negative")
        self.silenceCommitDelay = silenceCommitDelay
        self.finalizationRequestDelay = finalizationRequestDelay
        self.finalizationTimeout = finalizationTimeout
        self.maximumUtteranceDuration = maximumUtteranceDuration
        self.maximumResumeLookback = maximumResumeLookback
        self.speaker = speaker
    }

    /// The defaults.
    public static let standard = AppleTranscriberConfiguration()

    var silenceCommitSamples: Int64 { silenceCommitDelay.sampleCount(sampleRate: AudioFrame.captureSampleRate) }

    var finalizationRequestSamples: Int64 {
        finalizationRequestDelay.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    var finalizationTimeoutSamples: Int64 {
        finalizationTimeout.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    var maximumUtteranceSamples: Int64 {
        maximumUtteranceDuration.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }
}

/// Counters from `AppleTranscriber`, for diagnostics, the performance HUD
/// and tests.
public struct AppleTranscriberStatistics: Hashable, Sendable {
    /// Final utterances emitted.
    public var utterancesCommitted: Int64 = 0
    /// Commits (blank ones included) by why they ended.
    public var commits: [UtteranceCommitReason: Int64] = [:]
    /// Utterances that ended with no words and were not emitted.
    public var blankUtterancesDropped: Int64 = 0
    /// Partial events emitted.
    public var partialsEmitted: Int64 = 0
    /// Results received from the engine.
    public var volatileResults: Int64 = 0
    public var finalResults: Int64 = 0
    /// Results (or the part of them) dropped because an earlier utterance
    /// had already committed that audio.
    public var staleResultsDropped: Int64 = 0
    /// Times the engine was asked to finalize early.
    public var finalizationRequests: Int64 = 0
    /// Utterances committed with words the engine never finalized.
    public var unfinalizedCommits: Int64 = 0
    /// Audio given to the engine, in samples.
    public var samplesTranscribed: Int64 = 0
    /// Audio skipped because it was before the resume position.
    public var samplesSkipped: Int64 = 0
    /// Analysis sessions started (one per `start()`, plus restarts after a
    /// failure).
    public var sessionsStarted: Int64 = 0
    /// Engine calls that threw, and result streams that failed.
    public var engineFailures: Int64 = 0
    /// Commits measured from the end of the last word to the commit, on the
    /// audio timeline.
    public var endOfSpeechCommits: Int64 = 0
    public var endOfSpeechCommitDelay: Duration = .zero
    public var slowestEndOfSpeechCommit: Duration = .zero

    public init() {}

    /// The mean end-of-speech-to-commit delay, or zero before the first.
    public var meanEndOfSpeechCommitDelay: Duration {
        endOfSpeechCommits == 0 ? .zero : endOfSpeechCommitDelay / Int(endOfSpeechCommits)
    }
}
