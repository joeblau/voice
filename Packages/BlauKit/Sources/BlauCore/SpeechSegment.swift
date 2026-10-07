/// Where speech begins, as reported by voice activity detection.
///
/// Offsets are absolute 16 kHz sample indices into the capture stream (the
/// same numbering as `AudioFrame.sampleOffset`), so the audio can be read
/// back from the capture history exactly.
public struct SpeechOnset: Hashable, Sendable {
    /// The segment this onset opens; matches the `SpeechSegment.id` that
    /// later ends it.
    public let segmentID: Int
    /// First sample of the speech.
    public let startOffset: Int64
    /// Samples per second of the offsets.
    public let sampleRate: Int
    /// `true` when the previous segment was split because it reached the
    /// maximum duration and this one continues the same stretch of speech.
    public let isContinuation: Bool
    /// The stream position (exclusive end of the audio analysed) when the
    /// onset was decided. `detectedAt - startOffset` is the detection
    /// latency in samples.
    public let detectedAt: Int64

    public init(segmentID: Int, startOffset: Int64, sampleRate: Int, isContinuation: Bool, detectedAt: Int64) {
        precondition(sampleRate > 0, "Sample rate must be positive")
        precondition(startOffset >= 0, "Speech can't start before the stream")
        self.segmentID = segmentID
        self.startOffset = startOffset
        self.sampleRate = sampleRate
        self.isContinuation = isContinuation
        self.detectedAt = detectedAt
    }

    /// The onset on the conversation's audio timeline.
    public var start: Duration {
        .samples(startOffset, sampleRate: sampleRate)
    }

    /// How long after the onset the decision was made.
    public var detectionLatency: Duration {
        .samples(max(0, detectedAt - startOffset), sampleRate: sampleRate)
    }
}

/// One stretch of speech found by voice activity detection: what voice ID
/// scores, what ASR transcribes and what turn-taking reacts to.
public struct SpeechSegment: Hashable, Sendable, Identifiable {
    /// Why a segment ended.
    public enum EndReason: String, Hashable, Sendable {
        /// The speaker stopped: silence lasted at least the hangover.
        case silence
        /// The segment reached the maximum duration and was split; the
        /// next segment (`SpeechOnset.isContinuation`) carries on.
        case maximumDuration
        /// The audio stream ended (capture stopped) mid-speech.
        case streamEnded
    }

    /// Sequential number of the segment, from 0, within one segmenter.
    public let id: Int
    /// The speech, as absolute 16 kHz sample offsets into the capture
    /// stream: `capture.history(in: sampleRange)` returns its audio while
    /// it is still in the history.
    public let sampleRange: Range<Int64>
    /// Samples per second of `sampleRange`.
    public let sampleRate: Int
    /// `true` when this segment continues one that was split at the
    /// maximum duration.
    public let isContinuation: Bool
    public let endReason: EndReason
    /// The stream position when the end was decided. For `.silence` that
    /// is the hangover after `sampleRange.upperBound` plus the analysis
    /// granularity.
    public let detectedAt: Int64
    /// Highest speech probability the model reported inside the segment.
    public let peakProbability: Float
    /// Mean speech probability over the chunks analysed for the segment.
    public let meanProbability: Float

    public init(
        id: Int,
        sampleRange: Range<Int64>,
        sampleRate: Int,
        isContinuation: Bool = false,
        endReason: EndReason,
        detectedAt: Int64,
        peakProbability: Float,
        meanProbability: Float
    ) {
        precondition(sampleRate > 0, "Sample rate must be positive")
        precondition(sampleRange.lowerBound >= 0, "Speech can't start before the stream")
        self.id = id
        self.sampleRange = sampleRange
        self.sampleRate = sampleRate
        self.isContinuation = isContinuation
        self.endReason = endReason
        self.detectedAt = detectedAt
        self.peakProbability = peakProbability
        self.meanProbability = meanProbability
    }

    public var sampleCount: Int64 {
        Int64(sampleRange.count)
    }

    /// The segment on the conversation's audio timeline.
    public var timeRange: TimeRange {
        TimeRange(
            start: .samples(sampleRange.lowerBound, sampleRate: sampleRate),
            end: .samples(sampleRange.upperBound, sampleRate: sampleRate)
        )
    }

    public var duration: Duration {
        .samples(sampleCount, sampleRate: sampleRate)
    }

    /// How long after the end of the speech the end was decided.
    public var endDetectionLatency: Duration {
        .samples(max(0, detectedAt - sampleRange.upperBound), sampleRate: sampleRate)
    }
}

/// Speech boundaries from voice activity detection, in stream order.
public enum VoiceActivityEvent: Hashable, Sendable {
    /// Speech started (confirmed: it lasted at least the minimum speech
    /// duration). Arrives after the onset by `SpeechOnset.detectionLatency`.
    case speechStarted(SpeechOnset)
    /// The segment opened by the matching `speechStarted` ended.
    case speechEnded(SpeechSegment)
}

/// Captured audio gated by voice activity: only speech, for consumers such
/// as ASR that should not compute during silence.
public enum SpeechAudioEvent: Hashable, Sendable {
    /// A segment started. The `audio` that follows begins at
    /// `SpeechOnset.startOffset`.
    case started(SpeechOnset)
    /// Contiguous audio of the current segment, in order. After `started`,
    /// the first frame may be long (it carries the audio between the onset
    /// and the decision); later frames are the captured frames as they
    /// arrive. Each segment's audio starts at its onset, so it can repeat
    /// the end of the previous segment's hangover when two segments are
    /// close.
    case audio(AudioFrame)
    /// The segment ended. Audio up to the decision (the hangover) has
    /// already been delivered; `SpeechSegment.sampleRange` says where the
    /// speech itself ends. A split at the maximum duration is `ended`
    /// followed at once by `started` with `isContinuation`, and the audio
    /// simply continues.
    case ended(SpeechSegment)
}

/// A voice activity detector over the captured audio (BlauTranscription,
/// #28). Voice ID, ASR and turn-taking consume it through this protocol.
public protocol VoiceActivitySource: Sendable {
    /// A new stream of speech boundaries, from now on.
    func events() -> AsyncStream<VoiceActivityEvent>

    /// A new stream of speech-only audio with its boundaries, from the next
    /// segment on.
    func speechAudio() -> AsyncStream<SpeechAudioEvent>

    /// Whether a confirmed speech segment is open right now.
    var isSpeechActive: Bool { get }
}
