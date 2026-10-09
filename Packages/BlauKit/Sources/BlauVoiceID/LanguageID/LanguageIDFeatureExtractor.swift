import Accelerate
import Foundation

/// Log-mel filterbank features in a [frames, ``melCount``] matrix, row-major:
/// the language identification model's input.
public struct LanguageIDFeatures: Hashable, Sendable {
    public let frameCount: Int
    /// `frameCount * melCount` values, frame by frame.
    public let values: [Float]

    public init(frameCount: Int, values: [Float]) {
        precondition(values.count == frameCount * LanguageIDFeatureExtractor.melCount, "Wrong number of values")
        self.frameCount = frameCount
        self.values = values
    }

    /// One frame's `melCount` values.
    public func frame(_ index: Int) -> ArraySlice<Float> {
        let width = LanguageIDFeatureExtractor.melCount
        return values[(index * width)..<((index + 1) * width)]
    }
}

/// SpeechBrain's `Fbank` front end, as the VoxLingua107 language ID model
/// was trained with it: 16 kHz audio, 25 ms periodic Hamming windows every
/// 10 ms (centred, zero padded), the power spectrum of a 400-point DFT, 60
/// triangular mel filters (SpeechBrain's symmetric triangles, not HTK's),
/// `10 log10` with a floor of 80 dB below the loudest value.
///
/// It reproduces the `frontend.py` published with the Core ML export
/// (aufklarer/SpeechBrain-ECAPA-VoxLingua107-21M-CoreML), which the export
/// validates against SpeechBrain itself. The model does the sentence mean
/// normalization. A test checks values against that reference
/// (`LanguageIDFeatureExtractorTests`).
///
/// 400 points isn't a length vDSP's FFTs take, so the DFT is a matrix
/// product with precomputed cosine and sine tables (`vDSP_mmul`): about 32
/// million multiply-adds for 2 s, well under a millisecond on Apple silicon.
public struct LanguageIDFeatureExtractor: Sendable {
    public static let sampleRate = 16_000
    public static let fftLength = 400
    public static let hopLength = 160
    public static let melCount = 60
    /// The floor below the loudest value, in dB.
    public static let topDecibels: Float = 80
    static let binCount = fftLength / 2 + 1

    private let window: [Float]
    /// [fftLength, binCount] row-major.
    private let cosine: [Float]
    private let sine: [Float]
    /// [binCount, melCount] row-major.
    private let filterbank: [Float]

    public init() {
        let n = Self.fftLength
        let bins = Self.binCount
        window = (0..<n).map { index in
            Float(0.54) - Float(0.46) * cos(Float(2 * Double.pi) * Float(index) / Float(n))
        }
        var cosine = [Float](repeating: 0, count: n * bins)
        var sine = [Float](repeating: 0, count: n * bins)
        for sample in 0..<n {
            for bin in 0..<bins {
                // Reduce the phase modulo n first, so large products stay exact.
                let phase = 2 * Double.pi * Double((sample * bin) % n) / Double(n)
                cosine[sample * bins + bin] = Float(cos(phase))
                sine[sample * bins + bin] = Float(sin(phase))
            }
        }
        self.cosine = cosine
        self.sine = sine
        filterbank = Self.melFilterbank()
    }

    /// The number of frames `sampleCount` samples give.
    public static func frameCount(forSamples sampleCount: Int) -> Int {
        let padded = max(sampleCount + fftLength, fftLength)
        return (padded - fftLength) / hopLength + 1
    }

    /// The fewest samples that give `frames` frames.
    public static func sampleCount(forFrames frames: Int) -> Int {
        max(0, (frames - 1) * hopLength)
    }

    /// The features of 16 kHz mono `samples`.
    ///
    /// - Precondition: `samples` is not empty.
    public func features(_ samples: [Float]) -> LanguageIDFeatures {
        precondition(!samples.isEmpty, "No audio")
        let n = Self.fftLength
        let hop = Self.hopLength
        let bins = Self.binCount
        let mels = Self.melCount

        var padded = [Float](repeating: 0, count: samples.count + n)
        padded.withUnsafeMutableBufferPointer { buffer in
            samples.withUnsafeBufferPointer { source in
                (buffer.baseAddress! + n / 2).update(from: source.baseAddress!, count: source.count)
            }
        }
        let frames = (padded.count - n) / hop + 1

        // Windowed frames, [frames, n].
        var windowed = [Float](repeating: 0, count: frames * n)
        windowed.withUnsafeMutableBufferPointer { output in
            padded.withUnsafeBufferPointer { input in
                window.withUnsafeBufferPointer { window in
                    for frame in 0..<frames {
                        vDSP_vmul(
                            input.baseAddress! + frame * hop, 1, window.baseAddress!, 1,
                            output.baseAddress! + frame * n, 1, vDSP_Length(n))
                    }
                }
            }
        }

        // Power spectrum, [frames, bins].
        var real = [Float](repeating: 0, count: frames * bins)
        var imaginary = [Float](repeating: 0, count: frames * bins)
        Self.multiply(windowed, cosine, into: &real, rows: frames, inner: n, columns: bins)
        Self.multiply(windowed, sine, into: &imaginary, rows: frames, inner: n, columns: bins)
        vDSP.multiply(real, real, result: &real)
        vDSP.multiply(imaginary, imaginary, result: &imaginary)
        vDSP.add(real, imaginary, result: &real)

        // Mel energies, [frames, mels], in dB with the top-dB floor.
        var mel = [Float](repeating: 0, count: frames * mels)
        Self.multiply(real, filterbank, into: &mel, rows: frames, inner: bins, columns: mels)
        vDSP.threshold(mel, to: 1e-10, with: .clampToThreshold, result: &mel)
        vForce.log10(mel, result: &mel)
        vDSP.multiply(10, mel, result: &mel)
        let floor = vDSP.maximum(mel) - Self.topDecibels
        vDSP.threshold(mel, to: floor, with: .clampToThreshold, result: &mel)
        return LanguageIDFeatures(frameCount: frames, values: mel)
    }

    /// `result` [rows, columns] = `a` [rows, inner] × `b` [inner, columns].
    private static func multiply(
        _ a: [Float], _ b: [Float], into result: inout [Float], rows: Int, inner: Int, columns: Int
    ) {
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                result.withUnsafeMutableBufferPointer { c in
                    vDSP_mmul(
                        a.baseAddress!, 1, b.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(rows),
                        vDSP_Length(columns), vDSP_Length(inner))
                }
            }
        }
    }

    /// SpeechBrain's triangular mel filters as [bins, mels]: centres evenly
    /// spaced on the mel scale from 0 Hz to 8 kHz, each triangle as wide on
    /// both sides as the gap below its centre.
    static func melFilterbank() -> [Float] {
        let mels = melCount
        let bins = binCount
        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { Float(700 * (pow(10, Double(mel) / 2595) - 1)) }
        let low = Float(hzToMel(0))
        let high = Float(hzToMel(Double(sampleRate) / 2))
        let points = (0..<(mels + 2)).map { index in
            melToHz(low + (high - low) * Float(index) / Float(mels + 1))
        }
        let centres = Array(points[1...mels])
        let bands = (0..<mels).map { points[$0 + 1] - points[$0] }
        let nyquist = Float(sampleRate / 2)
        var filterbank = [Float](repeating: 0, count: bins * mels)
        for bin in 0..<bins {
            let frequency = nyquist * Float(bin) / Float(bins - 1)
            for mel in 0..<mels {
                let slope = (frequency - centres[mel]) / bands[mel]
                filterbank[bin * mels + mel] = max(0, min(slope + 1, -slope + 1))
            }
        }
        return filterbank
    }
}
