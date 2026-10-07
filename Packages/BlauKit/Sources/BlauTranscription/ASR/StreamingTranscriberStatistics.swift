/// Counters from `ParakeetStreamingTranscriber`, for diagnostics, the
/// performance HUD (#71) and tests.
public struct StreamingTranscriberStatistics: Hashable, Sendable {
    /// Final utterances emitted.
    public var utterancesCommitted: Int64 = 0
    /// Committed utterances (blank ones included) by why they ended.
    public var commits: [UtteranceCommitReason: Int64] = [:]
    /// Utterances that ended with no words (noise VAD took for speech) and
    /// were not emitted.
    public var blankUtterancesDropped: Int64 = 0
    /// Partial events emitted.
    public var partialsEmitted: Int64 = 0
    /// Model chunks run.
    public var chunksProcessed: Int64 = 0
    /// Time spent in the model.
    public var modelTime: Duration = .zero
    /// The slowest single chunk.
    public var slowestChunk: Duration = .zero
    /// Audio given to the recognizer, in samples.
    public var samplesTranscribed: Int64 = 0
    /// Audio the transcriber needed from the capture history but couldn't
    /// get (it had scrolled out), in samples.
    public var samplesMissed: Int64 = 0
    /// Recognizer calls that threw.
    public var recognizerFailures: Int64 = 0
    /// Switches to another chunk size.
    public var chunkSizeChanges: Int64 = 0
    /// Commits measured from the end of speech (`endOfUtterance` and
    /// `silence` commits after VAD reported the end).
    public var endOfSpeechCommits: Int64 = 0
    /// Their total and worst delay from the end of the speech to the commit,
    /// on the audio timeline (the model's compute time comes on top).
    public var endOfSpeechCommitDelay: Duration = .zero
    public var slowestEndOfSpeechCommit: Duration = .zero

    public init() {}

    /// The mean model time per chunk, or zero before the first chunk.
    public var meanChunkTime: Duration {
        chunksProcessed == 0 ? .zero : modelTime / Int(chunksProcessed)
    }

    /// The mean end-of-speech-to-commit delay, or zero before the first.
    public var meanEndOfSpeechCommitDelay: Duration {
        endOfSpeechCommits == 0 ? .zero : endOfSpeechCommitDelay / Int(endOfSpeechCommits)
    }
}
