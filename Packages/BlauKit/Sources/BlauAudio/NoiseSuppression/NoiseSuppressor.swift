import BlauCore

/// Speech enhancement on the 16 kHz capture stream, behind voice processing
/// (VPIO): a noise suppressor that runs on Blau's own audio after the
/// system's echo cancellation and noise suppression (#51).
///
/// A suppressor is a stateful stream processor. `process(_:)` takes any
/// number of samples and returns the enhanced samples it has ready, which lag
/// the input by `latency` (the model's look-ahead and its resamplers);
/// `finish()` returns what it still holds once the input has ended. One
/// instance processes one stream at a time and is not thread-safe: the
/// harnesses make one per recording with a ``NoiseSuppressorFactory``.
///
/// | Implementation | What runs |
/// | --- | --- |
/// | ``DeepFilterNet3Suppressor`` | DeepFilterNet3 (Core ML, 48 kHz, 10 ms hops) between two resamplers |
/// | ``SoundIsolationSuppressor`` | Apple's `AUSoundIsolation` audio unit, the voice isolation model behind the Voice Isolation mic mode |
///
/// See docs/noise-suppression.md for the evaluation and the decision.
public protocol NoiseSuppressor: AnyObject {
    /// What the suppressor is, for reports.
    var descriptor: NoiseSuppressorDescriptor { get }

    /// Enhances the next samples of the stream (16 kHz mono) and returns
    /// those that are ready. Output lags input by ``NoiseSuppressorDescriptor/latencySamples``.
    func process(_ samples: [Float]) throws -> [Float]

    /// Returns the enhanced samples still held back once the stream has
    /// ended. The suppressor is ready for a new stream afterwards.
    func finish() throws -> [Float]

    /// Drops all state for a new stream.
    func reset()
}

/// Makes a fresh suppressor for one recording.
public typealias NoiseSuppressorFactory = @Sendable () throws -> any NoiseSuppressor

/// What a suppressor is and what it costs in delay.
public struct NoiseSuppressorDescriptor: Codable, Hashable, Sendable {
    /// Stable identifier for reports and engine ids, e.g. `dfn3`.
    public var id: String
    /// Human-readable name.
    public var title: String
    /// How far the output lags the input, in 16 kHz samples: the model's
    /// algorithmic delay (look-ahead, STFT overlap) plus its resamplers.
    /// Compute time comes on top.
    public var latencySamples: Int
    /// Settings worth recording with the numbers (compute units, model...).
    public var settings: [String: String]

    public init(id: String, title: String, latencySamples: Int, settings: [String: String] = [:]) {
        precondition(latencySamples >= 0, "Latency can't be negative")
        self.id = id
        self.title = title
        self.latencySamples = latencySamples
        self.settings = settings
    }

    /// The algorithmic delay as a duration.
    public var latency: Duration {
        .samples(Int64(latencySamples), sampleRate: AudioFrame.captureSampleRate)
    }
}

extension NoiseSuppressor {
    /// Enhances a whole recording and returns it **aligned with the input**:
    /// the same number of samples, with the suppressor's delay removed, so
    /// labels and windows of the original still apply.
    ///
    /// Resets the suppressor first, and leaves it ready for another
    /// recording.
    public func enhance(_ samples: [Float]) throws -> [Float] {
        reset()
        guard !samples.isEmpty else { return [] }
        var output = try process(samples)
        output += try finish()
        let delay = descriptor.latencySamples
        if output.count > delay {
            output.removeFirst(delay)
        } else {
            output.removeAll()
        }
        if output.count > samples.count {
            output.removeLast(output.count - samples.count)
        } else if output.count < samples.count {
            output += repeatElement(0, count: samples.count - output.count)
        }
        return output
    }
}

/// Why a suppressor couldn't run.
public enum NoiseSuppressionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The model files are missing or don't match what the runtime expects.
    case incompatibleModel(String)
    /// The model ran but returned something unusable.
    case predictionFailed(String)
    /// The audio unit or its rendering engine failed.
    case audioUnitFailed(String)
    /// A resampler failed.
    case resamplingFailed(String)

    public var description: String {
        switch self {
        case .incompatibleModel(let reason): "Incompatible noise suppression model: \(reason)"
        case .predictionFailed(let reason): "Noise suppression model failed: \(reason)"
        case .audioUnitFailed(let reason): "Sound isolation audio unit failed: \(reason)"
        case .resamplingFailed(let reason): "Noise suppression resampling failed: \(reason)"
        }
    }
}
