import Accelerate
import Foundation

/// Small, deterministic signal processing for the evaluation harness:
/// simulated rooms, noise, loudspeakers and overlapping talkers. Everything
/// is seeded, so a run is reproducible bit for bit.
public enum EvaluationDSP {
    // MARK: Random numbers

    /// SplitMix64: a tiny, fast, seedable generator. Not cryptographic.
    public struct Random: RandomNumberGenerator, Sendable {
        private var state: UInt64

        public init(seed: UInt64) { state = seed }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A uniform value in `-1..<1`.
        public mutating func nextSigned() -> Float {
            Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1
        }

        /// A standard normal value (Box-Muller).
        public mutating func nextGaussian() -> Float {
            let u1 = max(Double(next() >> 11) / Double(1 << 53), .leastNonzeroMagnitude)
            let u2 = Double(next() >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
    }

    /// A stable 64-bit hash (FNV-1a) of `parts`, for per-trial seeds.
    /// (`Hasher` is randomly seeded per process, so it can't be used.)
    public static func stableHash(_ parts: String...) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0xFF
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: Levels

    /// Mean power (mean square) of `samples`, `0` when empty.
    public static func power(_ samples: [Float]) -> Float {
        samples.isEmpty ? 0 : vDSP.meanSquare(samples)
    }

    /// `signal + noise · g`, with `g` chosen so the signal-to-noise ratio is
    /// `snr` dB over the signal's length. `noise` is repeated or cut to fit.
    /// Silent signals or noise come back unchanged.
    public static func mix(_ signal: [Float], with noise: [Float], snr: Double) -> [Float] {
        guard !signal.isEmpty, !noise.isEmpty else { return signal }
        let fitted = fit(noise, count: signal.count)
        let signalPower = power(signal)
        let noisePower = power(fitted)
        guard signalPower > 0, noisePower > 0 else { return signal }
        let gain = Float((Double(signalPower) / (Double(noisePower) * pow(10, snr / 10))).squareRoot())
        return vDSP.add(multiplication: (fitted, gain), signal)
    }

    /// `samples` repeated end to end, or cut, to exactly `count` samples.
    public static func fit(_ samples: [Float], count: Int) -> [Float] {
        precondition(!samples.isEmpty || count == 0)
        guard samples.count != count else { return samples }
        guard samples.count < count else { return Array(samples.prefix(count)) }
        var result: [Float] = []
        result.reserveCapacity(count)
        while result.count < count {
            result += samples.prefix(count - result.count)
        }
        return result
    }

    /// Scales `samples` down if needed so the peak is at most `ceiling`, as a
    /// recording would be kept out of clipping.
    public static func limitPeak(_ samples: [Float], ceiling: Float = 0.99) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let peak = vDSP.maximumMagnitude(samples)
        guard peak > ceiling else { return samples }
        return vDSP.multiply(ceiling / peak, samples)
    }

    // MARK: Noise

    /// White Gaussian noise.
    public static func whiteNoise(count: Int, seed: UInt64) -> [Float] {
        var random = Random(seed: seed)
        return (0..<count).map { _ in random.nextGaussian() }
    }

    /// Pink (1/f) noise: white noise through Paul Kellet's refined filter,
    /// a close fit to room tone, fans and traffic.
    public static func pinkNoise(count: Int, seed: UInt64) -> [Float] {
        var random = Random(seed: seed)
        var b = [Float](repeating: 0, count: 7)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let white = random.nextGaussian()
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            output[index] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        return output
    }

    // MARK: Rooms

    /// A synthetic room impulse response: a unit direct path followed, after
    /// a short pre-delay, by an exponentially decaying noise tail whose
    /// energy sets the direct-to-reverberant ratio.
    ///
    /// - Parameters:
    ///   - rt60: Seconds for the tail to decay by 60 dB.
    ///   - directToReverberantRatio: Direct path energy over tail energy, in
    ///     dB. About +10 dB is a phone held close, 0 dB a couple of metres
    ///     across a living room, −5 dB the far side of a large room.
    ///   - sampleRate: Samples per second.
    ///   - seed: Seeds the tail.
    public static func roomImpulseResponse(
        rt60: Double,
        directToReverberantRatio: Double,
        sampleRate: Int,
        seed: UInt64
    ) -> [Float] {
        precondition(rt60 > 0 && sampleRate > 0)
        let length = Int(rt60 * Double(sampleRate))
        let preDelay = Int(0.005 * Double(sampleRate))
        guard length > preDelay + 1 else { return [1] }
        var random = Random(seed: seed)
        // Amplitude decays 60 dB over rt60: exp(-6.9078 t / rt60).
        let decay = 6.907_755 / (rt60 * Double(sampleRate))
        var response = [Float](repeating: 0, count: length)
        for index in (preDelay + 1)..<length {
            response[index] = random.nextGaussian() * Float(exp(-decay * Double(index - preDelay)))
        }
        let tailEnergy = response.reduce(Float(0)) { $0 + $1 * $1 }
        if tailEnergy > 0 {
            let wanted = Float(pow(10, -directToReverberantRatio / 10))
            response = vDSP.multiply((wanted / tailEnergy).squareRoot(), response)
        }
        response[0] = 1
        return response
    }

    /// The full linear convolution of `signal` and `kernel`
    /// (`signal.count + kernel.count - 1` samples), by FFT.
    public static func convolve(_ signal: [Float], _ kernel: [Float]) -> [Float] {
        guard !signal.isEmpty, !kernel.isEmpty else { return [] }
        let outputCount = signal.count + kernel.count - 1
        let log2n = vDSP_Length(max(2, Int.bitWidth - (outputCount - 1).leadingZeroBitCount))
        let size = 1 << Int(log2n)
        let half = size / 2
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            preconditionFailure("vDSP couldn't set up a \(size)-point FFT")
        }

        func spectrum(_ samples: [Float]) -> (real: [Float], imaginary: [Float]) {
            var padded = samples
            padded += [Float](repeating: 0, count: size - samples.count)
            var real = [Float](repeating: 0, count: half)
            var imaginary = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    padded.withUnsafeBytes { bytes in
                        vDSP_ctoz(
                            bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            return (real, imaginary)
        }

        let a = spectrum(signal)
        let b = spectrum(kernel)
        // Packed real spectra: element 0 holds DC (real) and Nyquist
        // (imaginary), both real-valued; the rest are complex bins.
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        real[0] = a.real[0] * b.real[0]
        imaginary[0] = a.imaginary[0] * b.imaginary[0]
        for bin in 1..<half {
            real[bin] = a.real[bin] * b.real[bin] - a.imaginary[bin] * b.imaginary[bin]
            imaginary[bin] = a.real[bin] * b.imaginary[bin] + a.imaginary[bin] * b.real[bin]
        }
        var output = [Float](repeating: 0, count: size)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                fft.inverse(input: split, output: &split)
                output.withUnsafeMutableBytes { bytes in
                    vDSP_ztoc(&split, 1, bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        // vDSP's forward real FFT is scaled by 2 and its inverse by N, so the
        // product of two forward spectra comes back 4N times too large.
        return vDSP.multiply(1 / Float(4 * size), Array(output.prefix(outputCount)))
    }

    // MARK: Filters

    /// Runs `samples` through a cascade of second-order sections.
    public static func filter(_ samples: [Float], sections: [BiquadSection]) -> [Float] {
        guard !samples.isEmpty, !sections.isEmpty else { return samples }
        let coefficients = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        guard
            var biquad = vDSP.Biquad(
                coefficients: coefficients, channelCount: 1, sectionCount: vDSP_Length(sections.count),
                ofType: Float.self)
        else { preconditionFailure("Invalid biquad coefficients") }
        return biquad.apply(input: samples)
    }

    /// Normalized second-order filter coefficients (`a0 = 1`), from Robert
    /// Bristow-Johnson's Audio EQ Cookbook.
    public struct BiquadSection: Hashable, Sendable {
        public let b0: Double
        public let b1: Double
        public let b2: Double
        public let a1: Double
        public let a2: Double

        /// A Butterworth-Q high-pass at `cutoff` Hz.
        public static func highPass(cutoff: Double, sampleRate: Int, q: Double = 0.7071) -> BiquadSection {
            let (cosine, alpha) = Self.prewarp(cutoff, sampleRate, q)
            let a0 = 1 + alpha
            return BiquadSection(
                b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
                a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
        }

        /// A Butterworth-Q low-pass at `cutoff` Hz.
        public static func lowPass(cutoff: Double, sampleRate: Int, q: Double = 0.7071) -> BiquadSection {
            let (cosine, alpha) = Self.prewarp(cutoff, sampleRate, q)
            let a0 = 1 + alpha
            return BiquadSection(
                b0: (1 - cosine) / 2 / a0, b1: (1 - cosine) / a0, b2: (1 - cosine) / 2 / a0,
                a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
        }

        private static func prewarp(_ cutoff: Double, _ sampleRate: Int, _ q: Double) -> (Double, Double) {
            precondition(cutoff > 0 && cutoff < Double(sampleRate) / 2, "Cutoff must be below Nyquist")
            let omega = 2 * Double.pi * cutoff / Double(sampleRate)
            return (cos(omega), sin(omega) / (2 * q))
        }
    }

    // MARK: Trimming

    /// `samples` without leading and trailing silence: 10 ms frames whose RMS
    /// level is below `relativeThreshold` of the loudest frame's, keeping
    /// `padding` seconds either side of the speech. Recordings with no frame
    /// above the threshold come back unchanged.
    public static func trimSilence(
        _ samples: [Float],
        sampleRate: Int,
        relativeThreshold: Float = 0.03,
        padding: Double = 0.05
    ) -> [Float] {
        let frame = max(1, sampleRate / 100)
        let frameCount = samples.count / frame
        guard frameCount > 2 else { return samples }
        let levels = (0..<frameCount).map { index in
            samples.withUnsafeBufferPointer { buffer in
                vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: buffer[(index * frame)..<((index + 1) * frame)]))
            }
        }
        guard let loudest = levels.max(), loudest > 0 else { return samples }
        let threshold = loudest * relativeThreshold
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
            let last = levels.lastIndex(where: { $0 >= threshold })
        else { return samples }
        let pad = Int(padding * Double(sampleRate))
        let start = max(0, first * frame - pad)
        let end = min(samples.count, (last + 1) * frame + pad)
        return Array(samples[start..<end])
    }
}
