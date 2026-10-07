import BlauCore

/// Counters for `SecondPassTranscriber`, for tests, the debug HUD and logs.
public struct SecondPassStatistics: Hashable, Sendable {
    /// Finals the base transcriber reported.
    public var utterancesSubmitted: Int64 = 0
    /// Utterances whose text the second pass replaced (`.refined` events).
    public var utterancesRefined: Int64 = 0
    /// Utterances the second pass transcribed to exactly the streaming text.
    public var utterancesUnchanged: Int64 = 0
    /// Utterances that kept their streaming text, by reason.
    public var skipped: [SecondPassSkipReason: Int64] = [:]
    /// Recognizer loads (successful or not).
    public var recognizerLoads: Int64 = 0
    /// Audio given to the recognizer, in 16 kHz samples (padding included).
    public var samplesTranscribed: Int64 = 0
    /// Time spent in the recognizer.
    public var modelTime: Duration = .zero
    /// The slowest single utterance.
    public var slowestUtterance: Duration = .zero
    /// Recognizer calls (successful or not).
    public var recognitions: Int64 = 0

    public init() {}

    /// Mean recognizer time per utterance.
    public var meanModelTime: Duration {
        recognitions == 0 ? .zero : modelTime / Int(recognitions)
    }

    /// Skipped utterances, all reasons.
    public var utterancesSkipped: Int64 {
        skipped.values.reduce(0, +)
    }

    /// Model time over audio time: below 1 is faster than real time.
    public var realTimeFactor: Double {
        guard samplesTranscribed > 0 else { return 0 }
        return modelTime.timeInterval / (Double(samplesTranscribed) / 16_000)
    }
}
