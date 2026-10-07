import Accelerate
import BlauCore

/// A streaming speech classifier: one probability per fixed-size chunk of
/// 16 kHz mono audio, fed in stream order.
///
/// Models are stateful (Silero carries an LSTM state from chunk to chunk),
/// so `VoiceActivitySegmenter` calls them strictly sequentially and calls
/// `reset()` whenever it skips audio. `SileroSpeechProbabilityModel` is the
/// real one; `EnergySpeechProbabilityModel` needs no model file.
public protocol SpeechProbabilityModel: Sendable {
    /// Samples per call (Silero v6 unified: 4096, 256 ms). The last chunk
    /// of a stream may be shorter.
    var chunkLength: Int { get }

    /// The probability, `0...1`, that `samples` contain speech.
    ///
    /// - Parameters:
    ///   - samples: `chunkLength` samples at 16 kHz (fewer only at the end
    ///     of a stream).
    ///   - sampleOffset: Where the chunk starts in the capture stream.
    func speechProbability(of samples: [Float], at sampleOffset: Int64) async throws -> Float

    /// Forgets the state carried between chunks, as at the start of a
    /// stream. Called before the first chunk after a skip or a gap.
    func reset() async
}

/// A model-free speech detector from the signal's level above a tracked
/// noise floor. It runs before the Silero model is installed and in tests
/// that must not load Core ML. It can't tell speech from other sounds, so
/// it is a fallback, not a replacement.
public actor EnergySpeechProbabilityModel: SpeechProbabilityModel {
    public nonisolated let chunkLength: Int
    /// The level above the noise floor that maps to a probability of 0.5.
    private let midpointDecibels: Float
    /// Decibels from 0.12 to 0.88 probability.
    private let slopeDecibels: Float
    private var noiseFloor: Float?

    /// - Parameters:
    ///   - chunkLength: Samples per chunk (default 4096, Silero's).
    ///   - midpointDecibels: SNR, in dB, that counts as even odds.
    ///   - slopeDecibels: Width of the transition around the midpoint.
    public init(chunkLength: Int = 4_096, midpointDecibels: Float = 12, slopeDecibels: Float = 4) {
        precondition(chunkLength > 0, "chunkLength must be positive")
        precondition(slopeDecibels > 0, "slopeDecibels must be positive")
        self.chunkLength = chunkLength
        self.midpointDecibels = midpointDecibels
        self.slopeDecibels = slopeDecibels
    }

    public func speechProbability(of samples: [Float], at sampleOffset: Int64) -> Float {
        let level = AudioLevelMath.decibels(rms: samples.isEmpty ? 0 : vDSP.rootMeanSquare(samples))
        let floor = noiseFloor ?? level
        let snr = level - floor
        let probability = 1 / (1 + exp(-(snr - midpointDecibels) / (slopeDecibels / 4)))
        // Track the floor: fall fast, rise slowly (and not at all on speech).
        if level < floor {
            noiseFloor = floor + 0.5 * (level - floor)
        } else if probability < 0.5 {
            noiseFloor = floor + 0.05 * (level - floor)
        } else {
            noiseFloor = floor
        }
        return probability
    }

    public func reset() {
        noiseFloor = nil
    }
}

/// Level arithmetic shared by the segmenter and the energy model.
enum AudioLevelMath {
    /// The quietest level reported, in dBFS. Digital silence maps here.
    static let floorDecibels: Float = -160

    static func decibels(rms: Float) -> Float {
        guard rms > 0 else { return floorDecibels }
        return max(20 * log10(rms), floorDecibels)
    }

    /// RMS level in dBFS of `samples`.
    static func decibels(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return floorDecibels }
        return samples.withUnsafeBufferPointer { decibels(rms: vDSP.rootMeanSquare($0)) }
    }
}
