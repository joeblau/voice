import BlauCore
import Foundation

/// How `SecondPassTranscriber` picks an utterance's audio and when it keeps
/// the streaming text instead of the second pass's.
public struct SecondPassConfiguration: Hashable, Sendable {
    /// Audio read before the utterance's start (VAD's onset), so the model
    /// hears the first word's attack. Never reaches back into the previous
    /// utterance.
    public var leadingPadding: Duration

    /// Audio read after the utterance's end (VAD's end of speech, or the
    /// last word when the model ended the utterance), so the last word
    /// isn't clipped. Kept short: when the model split continuous speech,
    /// the next utterance starts right after.
    public var trailingPadding: Duration

    /// Utterances waiting for the second pass at most. When the device
    /// can't keep up, the oldest waiting one keeps its streaming text.
    public var maximumPendingUtterances: Int

    /// The share of the streaming transcript's words the second pass may
    /// change (edit distance over words, ignoring case and punctuation)
    /// before its text is rejected as a misfire, such as audio from the
    /// wrong span. The models normally disagree on a word or two.
    public var maximumWordChangeRatio: Double

    /// Transcripts shorter than this many words skip the word-change check:
    /// one word in a short reply is already a large share.
    public var minimumWordsForChangeCheck: Int

    /// The second pass is skipped from this thermal state up, so it adds no
    /// Neural Engine work while the device is hot.
    public var skipThermalState: ProcessInfo.ThermalState

    /// After the recognizer fails to load, this many utterances keep their
    /// streaming text before loading is tried again.
    public var loadRetryInterval: Int

    /// - Precondition: paddings aren't negative, `maximumPendingUtterances`
    ///   and `loadRetryInterval` are positive, `maximumWordChangeRatio` is in
    ///   `0...1`.
    public init(
        leadingPadding: Duration = .milliseconds(100),
        trailingPadding: Duration = .milliseconds(120),
        maximumPendingUtterances: Int = 4,
        maximumWordChangeRatio: Double = 0.6,
        minimumWordsForChangeCheck: Int = 3,
        skipThermalState: ProcessInfo.ThermalState = .serious,
        loadRetryInterval: Int = 10
    ) {
        precondition(leadingPadding >= .zero && trailingPadding >= .zero, "Paddings must not be negative")
        precondition(maximumPendingUtterances > 0, "maximumPendingUtterances must be positive")
        precondition((0...1).contains(maximumWordChangeRatio), "maximumWordChangeRatio must be in 0...1")
        precondition(loadRetryInterval > 0, "loadRetryInterval must be positive")
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.maximumPendingUtterances = maximumPendingUtterances
        self.maximumWordChangeRatio = maximumWordChangeRatio
        self.minimumWordsForChangeCheck = minimumWordsForChangeCheck
        self.skipThermalState = skipThermalState
        self.loadRetryInterval = loadRetryInterval
    }

    /// The defaults.
    public static let standard = SecondPassConfiguration()

    /// The capture history (`CaptureHub.Configuration.historyDuration`)
    /// the second pass needs so that even an utterance cut at
    /// `streaming.maximumUtteranceDuration` still has its start in the
    /// history when it is committed: the longest utterance, the leading
    /// padding and 2 s for the commit and the hand-off. With a shorter
    /// history the longest utterances keep their streaming text
    /// (`SecondPassSkipReason.audioUnavailable`).
    public func requiredHistory(for streaming: StreamingTranscriberConfiguration) -> Duration {
        streaming.maximumUtteranceDuration + leadingPadding + .seconds(2)
    }

    var leadingPaddingSamples: Int64 { leadingPadding.sampleCount(sampleRate: 16_000) }
    var trailingPaddingSamples: Int64 { trailingPadding.sampleCount(sampleRate: 16_000) }

    /// The audio the second pass reads for an utterance spanning `start..<end`
    /// (16 kHz samples): `leadingPadding` before it, never reaching back past
    /// `previousEnd` (the previous utterance's end) or 0, and
    /// `trailingPadding` after it. Never empty. The caller clamps the upper
    /// bound to the audio it has. Shared by `SecondPassTranscriber` and the
    /// ASR evaluation harness, so both cut the same audio.
    func audioRange(start: Int64, end: Int64, previousEnd: Int64) -> Range<Int64> {
        let lower = max(start - leadingPaddingSamples, min(previousEnd, start), 0)
        let upper = max(end + trailingPaddingSamples, lower + 1)
        return lower..<upper
    }
}

/// Why an utterance kept its streaming text.
public enum SecondPassSkipReason: String, CaseIterable, Codable, Hashable, Sendable {
    /// The `secondPassASR` feature flag is off.
    case disabled
    /// The device is at `skipThermalState` or hotter.
    case thermalPressure
    /// Parakeet TDT v3 isn't installed, or failed to load.
    case modelUnavailable
    /// The utterance's start already scrolled out of the capture history.
    case audioUnavailable
    /// Too many utterances were waiting; this one was the oldest.
    case backlog
    /// The recognizer threw.
    case failed
    /// The second pass heard no words.
    case blank
    /// The second pass changed more than `maximumWordChangeRatio` of the words.
    case diverged
}
