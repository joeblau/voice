import BlauCore

/// The speech recognizer behind `AppleTranscriber`: Apple's `SpeechAnalyzer`
/// with a `SpeechTranscriber` module (`SystemSpeechAnalyzerEngine`), or a
/// scripted engine in tests.
///
/// One engine runs one analysis session at a time:
///
/// 1. `start(contextualStrings:)` opens a session and returns its results;
/// 2. `append(_:)` feeds 16 kHz capture audio, in stream order (gaps are
///    allowed: every frame carries its stream position);
/// 3. `requestFinalization(through:)` asks for everything up to a position
///    to be finalized now, without waiting for it;
/// 4. `finish()` finalizes what was fed and ends the results stream.
///
/// **Positions** are absolute 16 kHz sample offsets of the capture stream,
/// as everywhere in the pipeline; the engine maps them to and from the
/// analyzer's timeline.
public protocol SpeechAnalyzerEngine: Sendable {
    /// Opens a session. The stream yields results in order and finishes
    /// after `finish()` (or throws if the analyzer fails).
    ///
    /// - Parameter contextualStrings: Terms to bias recognition toward
    ///   (`AnalysisContext.contextualStrings`).
    func start(contextualStrings: [String]) async throws -> AsyncThrowingStream<SpeechAnalyzerResult, any Error>

    /// Feeds one frame of capture audio.
    func append(_ frame: AudioFrame) async throws

    /// Asks the analyzer to finalize its results up to `position` now
    /// instead of waiting for more context. Returns at once: the final
    /// results arrive on the results stream. (The analyzer's own
    /// `finalize(through:)` suspends until the audio after `position` has
    /// been analyzed, so awaiting it from the code that feeds the audio
    /// deadlocks.)
    func requestFinalization(through position: Int64) async

    /// Replaces the terms recognition is biased toward, for the rest of the
    /// session.
    func setContextualStrings(_ strings: [String]) async

    /// Finalizes everything fed and ends the session. The results stream
    /// finishes once the last result has been delivered.
    func finish() async

    /// Ends the session at once, dropping results not delivered yet.
    func cancel() async
}

/// One result from a `SpeechAnalyzerEngine`.
///
/// Mirrors `SpeechTranscriber.Result` with `.volatileResults` and the
/// `audioTimeRange` attribute, measured on the capture stream: a **volatile**
/// result is the current guess for the audio after `finalizedThrough` and
/// replaces the previous volatile one; a **final** result is settled text
/// for a stretch of audio, and is never revised.
///
/// The system transcriber finalizes about once per sentence, 0.7–2 s of
/// audio after the sentence ends, with a time range per word. Volatile
/// results carry one range for their whole text (from the finalization
/// point to the end of the audio analyzed).
public struct SpeechAnalyzerResult: Hashable, Sendable {
    /// A stretch of the result's text and the audio it covers.
    public struct Segment: Hashable, Sendable {
        public var text: String
        /// Stream offsets, or `nil` for text without a time (the analyzer
        /// attaches times to words, not to every space).
        public var range: Range<Int64>?

        public init(text: String, range: Range<Int64>?) {
            self.text = text
            self.range = range
        }
    }

    /// The text in order. Joined, they make `text`.
    public var segments: [Segment]
    /// The audio the result covers.
    public var range: Range<Int64>
    /// Results for audio before this position are final and won't change.
    public var finalizedThrough: Int64
    /// Whether this result is final.
    public var isFinal: Bool

    public init(segments: [Segment], range: Range<Int64>, finalizedThrough: Int64, isFinal: Bool) {
        self.segments = segments
        self.range = range
        self.finalizedThrough = finalizedThrough
        self.isFinal = isFinal
    }

    /// A result whose text has no word times (one segment over `range`).
    public init(text: String, range: Range<Int64>, finalizedThrough: Int64, isFinal: Bool) {
        self.init(
            segments: [Segment(text: text, range: range)], range: range, finalizedThrough: finalizedThrough,
            isFinal: isFinal)
    }

    /// The whole text, as the analyzer wrote it.
    public var text: String { segments.map(\.text).joined() }

    /// The result with only the text at or after `position`: segments that
    /// start before it are dropped, along with untimed text that follows
    /// them. Used to keep words that an earlier utterance already committed
    /// out of the next one.
    public func trimmed(before position: Int64) -> SpeechAnalyzerResult {
        guard range.lowerBound < position else { return self }
        var kept: [Segment] = []
        var keeping = false
        for segment in segments {
            if let segmentRange = segment.range {
                keeping = segmentRange.lowerBound >= position
            }
            if keeping {
                kept.append(segment)
            }
        }
        let lower = min(max(range.lowerBound, position), range.upperBound)
        return SpeechAnalyzerResult(
            segments: kept, range: lower..<range.upperBound, finalizedThrough: finalizedThrough, isFinal: isFinal)
    }

    /// The result with only the text before `position`: the complement of
    /// `trimmed(before:)`. Used to split a final at the onset of speech
    /// that belongs to the next utterance.
    public func prefix(before position: Int64) -> SpeechAnalyzerResult {
        var kept: [Segment] = []
        var keeping = true
        for segment in segments {
            if let segmentRange = segment.range {
                keeping = segmentRange.lowerBound < position
            }
            if keeping {
                kept.append(segment)
            }
        }
        let upper = max(range.lowerBound, min(range.upperBound, position))
        return SpeechAnalyzerResult(
            segments: kept, range: range.lowerBound..<upper, finalizedThrough: min(finalizedThrough, upper),
            isFinal: isFinal)
    }

    /// Where the last timed word ends, or `nil` without word times.
    public var lastWordEnd: Int64? {
        segments.last { $0.range != nil && !$0.text.allSatisfy(\.isWhitespace) }?.range?.upperBound
    }

    /// Where the first timed word starts, or `nil` without word times.
    public var firstWordStart: Int64? {
        segments.first { $0.range != nil && !$0.text.allSatisfy(\.isWhitespace) }?.range?.lowerBound
    }
}
