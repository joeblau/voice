import Foundation

/// Why capture couldn't be set up or a buffer couldn't be converted.
public enum CaptureError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The input node reported no usable format: no input route, or the
    /// microphone isn't available (permission, simulator without a mic).
    case noInputAvailable(sampleRate: Double, channelCount: Int)
    /// The input node's format isn't 32-bit float PCM.
    case unsupportedInputFormat(String)
    /// `AVAudioConverter` couldn't be created for this input rate.
    case converterUnavailable(inputSampleRate: Double)
    /// `AVAudioConverter` reported an error for a buffer.
    case conversionFailed(SystemError)

    public var description: String {
        switch self {
        case .noInputAvailable(let sampleRate, let channelCount):
            "noInputAvailable(\(sampleRate) Hz, \(channelCount) ch)"
        case .unsupportedInputFormat(let format):
            "unsupportedInputFormat(\(format))"
        case .converterUnavailable(let rate):
            "converterUnavailable(\(rate) Hz)"
        case .conversionFailed(let error):
            "conversionFailed(\(error))"
        }
    }
}

/// Counters for the capture pipeline, for telemetry, the debug HUD and
/// tests. Read a snapshot with `CaptureHub.statistics`.
///
/// "Frames" here are the hub's 16 kHz `AudioFrame`s; "buffers" are the
/// hardware buffers the audio thread delivers (about 20 ms each through the
/// sink node).
public struct CaptureStatistics: Sendable, Hashable {
    /// Frames fanned out to subscribers.
    public var framesPublished: Int64 = 0
    /// 16 kHz samples fanned out.
    public var samplesPublished: Int64 = 0
    /// Hardware buffers the audio thread dropped because the capture ring
    /// was full (the capture thread fell behind). Each drop leaves a gap in
    /// the stream's sample offsets.
    public var droppedBuffers: Int64 = 0
    /// 16 kHz samples lost to those drops: the total size of the gaps.
    public var droppedSamples: Int64 = 0
    /// Gaps in the stream (consecutive drops count once).
    public var gaps: Int64 = 0
    /// Frames thrown away because a subscriber's buffer was full (it fell
    /// more than `CaptureHub.Configuration.subscriberBuffer` behind). That
    /// subscriber sees a gap; the others are unaffected.
    public var subscriberDroppedFrames: Int64 = 0
    /// Buffers `AVAudioConverter` failed to convert. Their audio is lost.
    public var conversionFailures: Int64 = 0
    /// Capture segments started: one per graph build (start, resume, route
    /// change, media-services reset).
    public var segments: Int64 = 0

    public init() {}

    /// Every frame-equivalent the pipeline lost before reaching a
    /// subscriber, whatever the cause: capture drops (in frames of
    /// `frameLength` samples, rounded up) plus subscriber drops.
    public func droppedFrames(frameLength: Int) -> Int64 {
        precondition(frameLength > 0, "Frames must hold at least one sample")
        let length = Int64(frameLength)
        return (droppedSamples + length - 1) / length + subscriberDroppedFrames
    }
}

/// The input level of one captured frame, for the record button's meter.
public struct AudioLevel: Sendable, Hashable {
    /// Root-mean-square amplitude, `0...1` for full-scale audio.
    public var rms: Float
    /// Largest absolute sample.
    public var peak: Float
    /// Where the frame starts in the 16 kHz stream.
    public var sampleOffset: Int64

    public init(rms: Float, peak: Float, sampleOffset: Int64) {
        self.rms = rms
        self.peak = peak
        self.sampleOffset = sampleOffset
    }

    /// The quietest level reported, in dBFS. Digital silence maps here.
    public static let floorDecibels: Float = -160

    /// RMS level in dBFS (`0` is full scale).
    public var rmsDecibels: Float { Self.decibels(rms) }

    /// Peak level in dBFS.
    public var peakDecibels: Float { Self.decibels(peak) }

    /// The RMS level mapped to `0...1` for a meter: `floor` dBFS and below
    /// is `0`, full scale is `1`, linear in decibels in between.
    public func normalized(floor: Float = -60) -> Float {
        precondition(floor < 0, "The meter floor must be below full scale")
        let clamped = min(max(rmsDecibels, floor), 0)
        return (clamped - floor) / -floor
    }

    private static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return floorDecibels }
        return max(20 * log10(amplitude), floorDecibels)
    }
}
