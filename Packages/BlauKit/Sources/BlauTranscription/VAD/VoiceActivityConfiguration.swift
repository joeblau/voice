/// Tuning for `VoiceActivitySegmenter`.
///
/// The defaults are the issue's (#28): 250 ms minimum speech, 300 ms
/// hangover, 8 s maximum segment. The probability threshold is calibrated
/// for Silero VAD v6 on the labelled fixtures (see docs/vad.md).
public struct VoiceActivityConfiguration: Hashable, Sendable {
    /// A chunk whose speech probability reaches this starts (or keeps up)
    /// speech.
    public var threshold: Float

    /// Hysteresis: once speech has started, only a chunk below this counts
    /// as silence. Chunks between the two thresholds don't change the state.
    public var negativeThreshold: Float

    /// Speech shorter than this (coughs, clicks, a door) is discarded and
    /// never reported.
    public var minimumSpeechDuration: Duration

    /// Hangover: how long the speaker must stay quiet before the segment
    /// ends. Shorter pauses stay inside one segment.
    public var minimumSilenceDuration: Duration

    /// Longer speech is split into segments of at most this length, at the
    /// quietest point of the last `splitSearchWindow`, so voice ID and the
    /// downstream consumers get bounded chunks.
    public var maximumSegmentDuration: Duration

    /// Where a forced split may fall: the quietest 16 ms of this window
    /// before the maximum duration.
    public var splitSearchWindow: Duration

    /// Extra audio kept on each side of the speech so a soft onset or a
    /// trailing consonant isn't cut. Never extends a segment over the
    /// previous one.
    public var speechPadding: Duration

    /// How far before the chunk that triggered speech the onset may be
    /// placed when the energy shows the speech began earlier.
    public var onsetLookback: Duration

    /// Boundaries are refined to 16 ms within a chunk where the signal is
    /// this far above the tracked noise floor.
    public var energyMarginDecibels: Float

    /// While no speech is open, a chunk quieter than this (RMS, dBFS) is
    /// treated as silence without running the model, to save power. `nil`
    /// always runs the model.
    public var modelSkipLevelDecibels: Float?

    public init(
        threshold: Float = 0.5,
        negativeThreshold: Float? = nil,
        minimumSpeechDuration: Duration = .milliseconds(250),
        minimumSilenceDuration: Duration = .milliseconds(300),
        maximumSegmentDuration: Duration = .seconds(8),
        splitSearchWindow: Duration = .seconds(1),
        speechPadding: Duration = .milliseconds(30),
        onsetLookback: Duration = .milliseconds(512),
        energyMarginDecibels: Float = 6,
        modelSkipLevelDecibels: Float? = -65
    ) {
        let negative = negativeThreshold ?? max(threshold - 0.15, 0.01)
        precondition((0...1).contains(threshold), "threshold must be in 0...1")
        precondition((0...1).contains(negative) && negative <= threshold, "negativeThreshold must be in 0...threshold")
        precondition(minimumSpeechDuration >= .zero, "minimumSpeechDuration must not be negative")
        precondition(minimumSilenceDuration >= .zero, "minimumSilenceDuration must not be negative")
        precondition(splitSearchWindow > .zero, "splitSearchWindow must be positive")
        precondition(
            maximumSegmentDuration > splitSearchWindow, "maximumSegmentDuration must be longer than splitSearchWindow")
        precondition(
            maximumSegmentDuration >= minimumSpeechDuration,
            "maximumSegmentDuration must not be shorter than minimumSpeechDuration")
        precondition(speechPadding >= .zero, "speechPadding must not be negative")
        precondition(onsetLookback >= .zero, "onsetLookback must not be negative")
        precondition(energyMarginDecibels >= 0, "energyMarginDecibels must not be negative")
        self.threshold = threshold
        self.negativeThreshold = negative
        self.minimumSpeechDuration = minimumSpeechDuration
        self.minimumSilenceDuration = minimumSilenceDuration
        self.maximumSegmentDuration = maximumSegmentDuration
        self.splitSearchWindow = splitSearchWindow
        self.speechPadding = speechPadding
        self.onsetLookback = onsetLookback
        self.energyMarginDecibels = energyMarginDecibels
        self.modelSkipLevelDecibels = modelSkipLevelDecibels
    }

    /// The issue's defaults.
    public static let standard = VoiceActivityConfiguration()
}
