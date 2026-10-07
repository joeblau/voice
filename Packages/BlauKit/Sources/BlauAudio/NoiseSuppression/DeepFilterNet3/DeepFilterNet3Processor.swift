import Accelerate

/// DeepFilterNet3's streaming signal path at 48 kHz, one 10 ms hop at a time:
/// STFT, features, the network, ERB gains, deep filter, inverse STFT.
///
/// Every hop in produces one hop out, delayed by
/// ``DeepFilterNet3Parameters/latencySamples`` (1,440 samples, 30 ms): one
/// hop of STFT overlap plus the network's two hops of look-ahead. Until the
/// look-ahead has filled, the output is silence.
///
/// The algorithm follows DeepFilterNet's reference (libDF and
/// `DeepFilterNet-mlx`'s `CoreMLStreamingEngine`, Apache-2.0): Vorbis window,
/// spectra scaled by `2·hop/fft²`, ERB energies in dB with an exponential
/// running mean (α = 0.99) divided by 40, low bins divided by the square
/// root of an exponential running magnitude, the ERB gains spread to bins
/// by the inverse filterbank, and the deep filter over frames t−2…t+2 on
/// the lowest 96 bins.
///
/// Not thread-safe: one stream at a time.
public final class DeepFilterNet3Processor {
    public let parameters: DeepFilterNet3Parameters
    private let network: any DeepFilterNet3Network

    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    // Streaming state.
    private var analysisMemory: [Float]
    private var synthesisMemory: [Float]
    private var meanNormalization: [Float]
    private var unitNormalization: [Float]
    private var erbHistory: [Float]
    private var spectrumRealHistory: [Float]
    private var spectrumImaginaryHistory: [Float]
    /// Spectra not yet enhanced: the target frame and its look-ahead.
    private var pending: [Spectrum] = []
    /// The last frames enhanced, for the deep filter's past taps.
    private var past: [Spectrum] = []
    private var framesAnalyzed = 0

    // Scratch buffers, allocated once.
    private var zeros: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var erb: [Float]
    private var mask: [Float]
    private var gains: [Float]
    private var coefficients: [Float]

    /// The network's local SNR estimate for the last frame enhanced, in dB
    /// (`nil` before the first).
    public private(set) var localSNR: Float?

    private struct Spectrum {
        var real: [Float]
        var imaginary: [Float]
    }

    public init(parameters: DeepFilterNet3Parameters, network: any DeepFilterNet3Network) throws {
        try parameters.validate()
        let forward: vDSP.DiscreteFourierTransform<Float>
        let inverse: vDSP.DiscreteFourierTransform<Float>
        do {
            // 960 = 15 · 2⁶, a size vDSP's complex DFT supports.
            forward = try vDSP.DiscreteFourierTransform(
                count: parameters.fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)
            inverse = try vDSP.DiscreteFourierTransform(
                previous: forward, count: parameters.fftSize, direction: .inverse, transformType: .complexComplex,
                ofType: Float.self)
        } catch {
            throw NoiseSuppressionError.incompatibleModel("vDSP has no \(parameters.fftSize)-point DFT: \(error)")
        }
        let p = parameters
        self.parameters = p
        self.network = network
        self.forward = forward
        self.inverse = inverse
        analysisMemory = [Float](repeating: 0, count: p.fftSize - p.hopSize)
        synthesisMemory = [Float](repeating: 0, count: p.fftSize - p.hopSize)
        meanNormalization = p.initialMeanNormalization
        unitNormalization = p.initialUnitNormalization
        erbHistory = [Float](repeating: 0, count: p.historyFrames * p.erbBands)
        spectrumRealHistory = [Float](repeating: 0, count: p.historyFrames * p.deepFilterBins)
        spectrumImaginaryHistory = spectrumRealHistory
        zeros = [Float](repeating: 0, count: p.fftSize)
        real = [Float](repeating: 0, count: p.fftSize)
        imaginary = [Float](repeating: 0, count: p.fftSize)
        power = [Float](repeating: 0, count: p.bins)
        erb = [Float](repeating: 0, count: p.erbBands)
        mask = [Float](repeating: 0, count: p.erbBands)
        gains = [Float](repeating: 0, count: p.bins)
        coefficients = [Float](repeating: 0, count: p.deepFilterOrder * p.deepFilterBins * 2)
    }

    /// Clears every buffer, the running normalization and the network's
    /// recurrent state, for a new stream.
    public func reset() {
        let p = parameters
        analysisMemory = [Float](repeating: 0, count: p.fftSize - p.hopSize)
        synthesisMemory = [Float](repeating: 0, count: p.fftSize - p.hopSize)
        meanNormalization = p.initialMeanNormalization
        unitNormalization = p.initialUnitNormalization
        erbHistory = [Float](repeating: 0, count: p.historyFrames * p.erbBands)
        spectrumRealHistory = [Float](repeating: 0, count: p.historyFrames * p.deepFilterBins)
        spectrumImaginaryHistory = spectrumRealHistory
        pending.removeAll(keepingCapacity: true)
        past.removeAll(keepingCapacity: true)
        framesAnalyzed = 0
        localSNR = nil
        network.reset()
    }

    /// Enhances one hop (`hopSize` samples at 48 kHz) and returns one hop,
    /// `latencySamples` behind.
    public func process(hop: [Float]) throws -> [Float] {
        let p = parameters
        precondition(hop.count == p.hopSize, "DeepFilterNet3 takes \(p.hopSize)-sample hops")
        let spectrum = analyze(hop)
        appendFeatures(of: spectrum)
        pending.append(spectrum)
        framesAnalyzed += 1
        // The network's convolutions read `convolutionLookahead` frames
        // past the one it enhances: silence until they exist.
        guard framesAnalyzed > p.convolutionLookahead else { return [Float](repeating: 0, count: p.hopSize) }

        localSNR = try network.step(
            erbFeatures: erbHistory, spectrumFeatures: spectrumRealHistory + spectrumImaginaryHistory, mask: &mask,
            coefficients: &coefficients)
        let target = pending.removeFirst()
        let enhanced = enhance(target)
        past.append(target)
        if past.count > p.deepFilterPastFrames { past.removeFirst(past.count - p.deepFilterPastFrames) }
        return synthesize(enhanced)
    }

    // MARK: Analysis

    /// Windows the last `fftSize` samples and returns the scaled one-sided
    /// spectrum.
    private func analyze(_ hop: [Float]) -> Spectrum {
        let p = parameters
        let frame = analysisMemory + hop
        analysisMemory = Array(frame[p.hopSize...])
        let windowed = vDSP.multiply(frame, p.window)
        forward.transform(inputReal: windowed, inputImaginary: zeros, outputReal: &real, outputImaginary: &imaginary)
        let scale = p.spectrumScale
        return Spectrum(
            real: vDSP.multiply(scale, real[0..<p.bins]), imaginary: vDSP.multiply(scale, imaginary[0..<p.bins]))
    }

    /// ERB energies (dB, mean-normalized) and the low bins
    /// (unit-normalized), pushed onto the feature history.
    private func appendFeatures(of spectrum: Spectrum) {
        let p = parameters
        let alpha = p.normalizationAlpha
        // |X|² per bin, then summed into ERB bands: power[1, bins] · fb[bins, bands].
        for bin in 0..<p.bins {
            power[bin] = spectrum.real[bin] * spectrum.real[bin] + spectrum.imaginary[bin] * spectrum.imaginary[bin]
        }
        power.withUnsafeBufferPointer { power in
            p.erbFilterbank.withUnsafeBufferPointer { filterbank in
                erb.withUnsafeMutableBufferPointer { erb in
                    vDSP_mmul(
                        power.baseAddress!, 1, filterbank.baseAddress!, 1, erb.baseAddress!, 1, 1,
                        vDSP_Length(p.erbBands), vDSP_Length(p.bins))
                }
            }
        }
        for band in 0..<p.erbBands {
            let decibels = 10 * log10(erb[band] + 1e-10)
            meanNormalization[band] = decibels * (1 - alpha) + meanNormalization[band] * alpha
            erb[band] = (decibels - meanNormalization[band]) / 40
        }
        Self.push(erb, onto: &erbHistory, frames: p.historyFrames)

        var lowReal = [Float](repeating: 0, count: p.deepFilterBins)
        var lowImaginary = [Float](repeating: 0, count: p.deepFilterBins)
        for bin in 0..<p.deepFilterBins {
            let re = spectrum.real[bin]
            let im = spectrum.imaginary[bin]
            unitNormalization[bin] = (re * re + im * im).squareRoot() * (1 - alpha) + unitNormalization[bin] * alpha
            let norm = max(unitNormalization[bin], 1e-10).squareRoot()
            lowReal[bin] = re / norm
            lowImaginary[bin] = im / norm
        }
        Self.push(lowReal, onto: &spectrumRealHistory, frames: p.historyFrames)
        Self.push(lowImaginary, onto: &spectrumImaginaryHistory, frames: p.historyFrames)
    }

    /// Drops the oldest frame of `history` and appends `frame`.
    private static func push(_ frame: [Float], onto history: inout [Float], frames: Int) {
        history.removeFirst(frame.count)
        history.append(contentsOf: frame)
        assert(history.count == frames * frame.count)
    }

    // MARK: Enhancement

    /// Applies the ERB gains to every bin and the deep filter to the low
    /// bins of `target`.
    private func enhance(_ target: Spectrum) -> Spectrum {
        let p = parameters
        // gains[1, bins] = mask[1, bands] · inverse[bands, bins]
        mask.withUnsafeBufferPointer { mask in
            p.erbInverseFilterbank.withUnsafeBufferPointer { inverse in
                gains.withUnsafeMutableBufferPointer { gains in
                    vDSP_mmul(
                        mask.baseAddress!, 1, inverse.baseAddress!, 1, gains.baseAddress!, 1, 1,
                        vDSP_Length(p.bins), vDSP_Length(p.erbBands))
                }
            }
        }
        var output = Spectrum(
            real: vDSP.multiply(target.real, gains), imaginary: vDSP.multiply(target.imaginary, gains))

        // Taps: past frames (zeros before the stream began), the target, then
        // the look-ahead frames still pending.
        let empty = Spectrum(
            real: [Float](repeating: 0, count: p.bins), imaginary: [Float](repeating: 0, count: p.bins))
        var taps = [Spectrum](repeating: empty, count: max(0, p.deepFilterPastFrames - past.count))
        taps += past.suffix(p.deepFilterPastFrames)
        taps.append(target)
        taps += pending.prefix(p.deepFilterLookahead)
        while taps.count < p.deepFilterOrder { taps.append(empty) }

        for bin in 0..<p.deepFilterBins {
            var sumReal: Float = 0
            var sumImaginary: Float = 0
            for (order, tap) in taps.enumerated() {
                let index = (order * p.deepFilterBins + bin) * 2
                let wr = coefficients[index]
                let wi = coefficients[index + 1]
                let xr = tap.real[bin]
                let xi = tap.imaginary[bin]
                sumReal += xr * wr - xi * wi
                sumImaginary += xr * wi + xi * wr
            }
            output.real[bin] = sumReal
            output.imaginary[bin] = sumImaginary
        }
        return output
    }

    // MARK: Synthesis

    /// Inverse STFT of one frame with overlap-add: returns the hop it
    /// completes.
    private func synthesize(_ spectrum: Spectrum) -> [Float] {
        let p = parameters
        let n = p.fftSize
        let unscale = 1 / p.spectrumScale
        // Rebuild the two-sided spectrum: X[n − k] = conj(X[k]).
        for k in 0..<p.bins {
            real[k] = spectrum.real[k] * unscale
            imaginary[k] = spectrum.imaginary[k] * unscale
        }
        for k in 1..<(n / 2) {
            real[n - k] = real[k]
            imaginary[n - k] = -imaginary[k]
        }
        var timeReal = [Float](repeating: 0, count: n)
        var timeImaginary = [Float](repeating: 0, count: n)
        inverse.transform(
            inputReal: real, inputImaginary: imaginary, outputReal: &timeReal, outputImaginary: &timeImaginary)
        let windowed = vDSP.multiply(timeReal, vDSP.multiply(1 / Float(n), p.window))
        let overlap = n - p.hopSize
        let output = vDSP.add(windowed[0..<p.hopSize], synthesisMemory[0..<p.hopSize])
        synthesisMemory = Array(windowed[p.hopSize..<n])
        assert(synthesisMemory.count == overlap)
        return output
    }
}
