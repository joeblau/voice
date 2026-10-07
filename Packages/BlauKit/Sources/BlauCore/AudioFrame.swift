import Accelerate

/// A chunk of mono, 32-bit float PCM audio and its position in the stream.
///
/// The capture engine downmixes and resamples microphone input to
/// `AudioFrame.captureSampleRate` before fanning frames out to VAD, voice ID
/// and ASR. Samples are nominally in `-1...1`.
///
/// The position is a sample index rather than a time, so consecutive frames
/// line up exactly and times derived from them never drift.
public struct AudioFrame: Hashable, Sendable {
    /// Sample rate of the on-device pipeline (VAD, voice ID, ASR): 16 kHz.
    public static let captureSampleRate = 16_000

    /// Mono samples.
    public let samples: [Float]

    /// Samples per second.
    public let sampleRate: Int

    /// Index of `samples[0]` in the stream, counted at `sampleRate` from the
    /// start of capture.
    public let sampleOffset: Int64

    /// - Precondition: `sampleRate > 0` and `sampleOffset >= 0`.
    public init(samples: [Float], sampleRate: Int = AudioFrame.captureSampleRate, sampleOffset: Int64) {
        precondition(sampleRate > 0, "Sample rate must be positive")
        precondition(sampleOffset >= 0, "Sample offset must not be negative")
        self.samples = samples
        self.sampleRate = sampleRate
        self.sampleOffset = sampleOffset
    }

    public var sampleCount: Int { samples.count }

    public var isEmpty: Bool { samples.isEmpty }

    /// Index of the sample right after this frame: the next frame's
    /// `sampleOffset` when the stream has no gaps.
    public var nextSampleOffset: Int64 { sampleOffset + Int64(samples.count) }

    public var duration: Duration {
        .samples(Int64(samples.count), sampleRate: sampleRate)
    }

    /// Where the frame sits on the stream's timeline. Both ends come from
    /// absolute sample indices, so a frame's end equals the next contiguous
    /// frame's start exactly.
    public var timeRange: TimeRange {
        TimeRange(
            start: .samples(sampleOffset, sampleRate: sampleRate),
            end: .samples(nextSampleOffset, sampleRate: sampleRate)
        )
    }

    /// Root-mean-square level, `0` for an empty frame.
    public var rms: Float {
        samples.isEmpty ? 0 : vDSP.rootMeanSquare(samples)
    }

    /// Largest absolute sample value, `0` for an empty frame.
    public var peak: Float {
        samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)
    }
}
