import Accelerate
import Foundation

@testable import BlauAudio

/// DeepFilterNet3's frame sizes with synthetic arrays: the exact Vorbis
/// window and ERB filterbanks that partition the bins into 32 bands (the
/// real `erb_inv_fb` is such a partition too), so a unit mask passes every
/// bin unchanged.
func syntheticDeepFilterNet3Parameters() -> DeepFilterNet3Parameters {
    let bins = 481
    let bands = 32
    // Band edges growing roughly like ERB bands: one bin each at the bottom.
    var edges = [0]
    for band in 1..<bands { edges.append(max(edges[band - 1] + 1, Int(Double(bins) * pow(Double(band) / 32, 2.2)))) }
    edges.append(bins)
    var forward = [Float](repeating: 0, count: bins * bands)
    var inverse = [Float](repeating: 0, count: bands * bins)
    for band in 0..<bands {
        let range = edges[band]..<edges[band + 1]
        for bin in range {
            forward[bin * bands + band] = 1 / Float(range.count)
            inverse[band * bins + bin] = 1
        }
    }
    return DeepFilterNet3Parameters(
        window: DeepFilterNet3Parameters.vorbisWindow(size: 960),
        erbFilterbank: forward,
        erbInverseFilterbank: inverse,
        initialMeanNormalization: (0..<bands).map { -60 - 30 * Float($0) / 31 },
        initialUnitNormalization: (0..<96).map { 0.001 - 0.0009 * Float($0) / 95 })
}

/// A network that returns fixed gains: `gain` on every ERB band and a deep
/// filter that scales the target frame by `gain` (and ignores the other
/// taps). With `gain` 1 the whole chain is an identity, delayed. It records
/// the features it was given.
final class FixedGainNetwork: DeepFilterNet3Network {
    let gain: Float
    let localSNR: Float
    private(set) var steps = 0
    private(set) var resets = 0
    private(set) var lastERBFeatures: [Float] = []
    private(set) var lastSpectrumFeatures: [Float] = []

    init(gain: Float = 1, localSNR: Float = 20) {
        self.gain = gain
        self.localSNR = localSNR
    }

    func step(
        erbFeatures: [Float], spectrumFeatures: [Float], mask: inout [Float], coefficients: inout [Float]
    ) throws -> Float {
        steps += 1
        lastERBFeatures = erbFeatures
        lastSpectrumFeatures = spectrumFeatures
        for index in mask.indices { mask[index] = gain }
        for index in coefficients.indices { coefficients[index] = 0 }
        // Tap order: two past frames, the target, two look-ahead frames.
        let targetTap = 2
        let bins = coefficients.count / (5 * 2)
        for bin in 0..<bins { coefficients[(targetTap * bins + bin) * 2] = gain }
        return localSNR
    }

    func reset() {
        resets += 1
    }
}

/// A deterministic speech-like test signal: a few harmonics with a slow
/// amplitude envelope, plus a click so alignment is unambiguous.
func testSignal(count: Int, sampleRate: Double, seed: Double = 0) -> [Float] {
    (0..<count).map { index in
        let t = Double(index) / sampleRate
        let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * t + seed)
        var value = 0.0
        for (harmonic, amplitude) in [(1.0, 0.3), (2.0, 0.15), (3.0, 0.1), (5.0, 0.05)] {
            value += amplitude * sin(2 * .pi * 210 * harmonic * t + seed * harmonic)
        }
        return Float(value * envelope)
    }
}

/// The lag (in samples, 0...maximumLag) at which `output` best matches
/// `input`, by normalized cross-correlation.
func bestLag(of output: [Float], against input: [Float], maximumLag: Int) -> (lag: Int, correlation: Float) {
    var best = (lag: 0, correlation: -Float.infinity)
    for lag in 0...maximumLag {
        let count = min(input.count, output.count - lag)
        guard count > 0 else { break }
        let a = Array(input[0..<count])
        let b = Array(output[lag..<(lag + count)])
        let denominator = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        let correlation = denominator > 0 ? vDSP.dot(a, b) / denominator : 0
        if correlation > best.correlation { best = (lag, correlation) }
    }
    return best
}

/// Signal-to-error ratio of `output` against `reference` in dB.
func signalToError(_ output: [Float], reference: [Float]) -> Float {
    let count = min(output.count, reference.count)
    let a = Array(reference[0..<count])
    let error = vDSP.subtract(a, Array(output[0..<count]))
    return 10 * log10(vDSP.sumOfSquares(a) / max(vDSP.sumOfSquares(error), 1e-20))
}
