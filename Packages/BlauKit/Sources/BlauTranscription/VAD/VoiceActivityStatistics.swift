import BlauCore

/// Counters for `VoiceActivitySegmenter`, for telemetry, the debug HUD and
/// tests. Read a snapshot with `VoiceActivitySegmenter.statistics`.
public struct VoiceActivityStatistics: Hashable, Sendable {
    /// 16 kHz samples analysed (gaps filled with silence included).
    public var samplesProcessed: Int64 = 0
    /// Chunks the model ran on.
    public var chunksAnalyzed: Int64 = 0
    /// Chunks treated as silence without running the model because they
    /// were quieter than `modelSkipLevelDecibels`: the power saving.
    public var chunksSkipped: Int64 = 0
    /// Chunks whose model call threw; they count as silence.
    public var modelFailures: Int64 = 0
    /// Total time spent in the model.
    public var modelTime: Duration = .zero
    /// Segments ended, splits included.
    public var segments: Int64 = 0
    /// Segments ended because they reached the maximum duration.
    public var forcedSplits: Int64 = 0
    /// Bursts dropped for being shorter than the minimum speech duration.
    public var rejectedCandidates: Int64 = 0
    /// Samples inside reported segments.
    public var speechSamples: Int64 = 0
    /// Discontinuities in the input (dropped capture audio): short ones are
    /// filled with silence, long ones restart the stream.
    public var gaps: Int64 = 0
    /// `speechAudio()` values a slow subscriber lost.
    public var droppedAudioEvents: Int64 = 0

    public init() {}

    /// Share of chunks that skipped the model, `0...1`.
    public var skippedFraction: Double {
        let total = chunksAnalyzed + chunksSkipped
        return total > 0 ? Double(chunksSkipped) / Double(total) : 0
    }

    /// Model time per second of audio processed, `0...1` (`0.01` is 1% of
    /// one core, if the model ran on the CPU).
    public var modelLoad: Double {
        guard samplesProcessed > 0 else { return 0 }
        let audio = Double(samplesProcessed) / 16_000
        return modelTime.timeInterval / audio
    }
}
