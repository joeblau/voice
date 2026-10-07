import Foundation

/// The signal processing around DeepFilterNet3's network: frame sizes, the
/// analysis window, the ERB filterbanks and the feature normalization.
///
/// DeepFilterNet3 (Schröter et al., 2023, https://arxiv.org/abs/2305.08227)
/// works on a 48 kHz STFT (960-point Vorbis window, 480-sample hop, 481
/// bins). The network sees two features per frame: 32 ERB band energies in
/// dB (mean-normalized) and the complex spectrum of the lowest 96 bins
/// (unit-normalized). It returns a gain per ERB band, applied to the whole
/// spectrum, and a 5-tap complex "deep filter" per low bin, applied over two
/// past frames, the frame itself and two future ones. The streaming Core ML
/// conversion (`iky1e/DeepFilterNet3-Streaming-CoreML`) computes one 10 ms
/// hop from the last 10 feature frames and explicit GRU state; everything
/// here runs in Swift around it.
///
/// The arrays come from the conversion's `auxiliary.npz`, so they always
/// match the network they were exported with.
public struct DeepFilterNet3Parameters: Hashable, Sendable {
    /// The model's sample rate.
    public var sampleRate = 48_000
    /// STFT size: 20 ms.
    public var fftSize = 960
    /// STFT hop: 10 ms, the unit the network advances by.
    public var hopSize = 480
    /// ERB bands in the gain mask.
    public var erbBands = 32
    /// Low bins enhanced by the deep filter (0-4.8 kHz).
    public var deepFilterBins = 96
    /// Taps of the deep filter.
    public var deepFilterOrder = 5
    /// Future frames the deep filter reads.
    public var deepFilterLookahead = 2
    /// Future frames the network's convolutions read: the stream must run
    /// this many hops ahead of the frame being enhanced.
    public var convolutionLookahead = 2
    /// Feature frames the streaming graph takes per hop.
    public var historyFrames = 10
    /// Smoothing of the running feature normalization: `exp(-hop / 1 s)`
    /// rounded to 3 decimals, 0.99 (DeepFilterNet's `get_norm_alpha`).
    public var normalizationAlpha: Float = 0.99

    /// The analysis and synthesis window, `fftSize` values (Vorbis).
    public var window: [Float]
    /// Power spectrum to ERB band energies: `[bins, erbBands]`, row-major.
    public var erbFilterbank: [Float]
    /// ERB band gains to per-bin gains: `[erbBands, bins]`, row-major.
    public var erbInverseFilterbank: [Float]
    /// Initial state of the ERB features' running mean, in dB.
    public var initialMeanNormalization: [Float]
    /// Initial state of the low-bin spectrum's running magnitude.
    public var initialUnitNormalization: [Float]

    /// Bins of the one-sided spectrum.
    public var bins: Int { fftSize / 2 + 1 }

    /// The STFT normalization DeepFilterNet applies to its spectra,
    /// `2 * hop / fft²` (1/960 here).
    public var spectrumScale: Float { Float(2 * hopSize) / Float(fftSize * fftSize) }

    /// How far the output lags the input, at 48 kHz: the STFT overlap (one
    /// hop) plus the convolution look-ahead (two hops), 1,440 samples or
    /// 30 ms.
    public var latencySamples: Int { (fftSize - hopSize) + convolutionLookahead * hopSize }

    /// Taps before the frame being filtered.
    var deepFilterPastFrames: Int { deepFilterOrder - deepFilterLookahead - 1 }

    public init(
        window: [Float], erbFilterbank: [Float], erbInverseFilterbank: [Float],
        initialMeanNormalization: [Float], initialUnitNormalization: [Float]
    ) {
        self.window = window
        self.erbFilterbank = erbFilterbank
        self.erbInverseFilterbank = erbInverseFilterbank
        self.initialMeanNormalization = initialMeanNormalization
        self.initialUnitNormalization = initialUnitNormalization
    }

    /// Reads `auxiliary.npz` from the Core ML conversion and checks every
    /// array's shape.
    public static func load(auxiliary url: URL) throws -> DeepFilterNet3Parameters {
        let arrays: [String: NumPyArray]
        do {
            arrays = try NumPyArchive.read(contentsOf: url)
        } catch {
            throw NoiseSuppressionError.incompatibleModel("\(url.lastPathComponent): \(error)")
        }
        return try DeepFilterNet3Parameters(arrays: arrays)
    }

    init(arrays: [String: NumPyArray]) throws(NoiseSuppressionError) {
        func array(_ name: String) throws(NoiseSuppressionError) -> NumPyArray {
            guard let array = arrays[name] else { throw .incompatibleModel("auxiliary.npz has no \(name)") }
            return array
        }
        self.init(
            window: try array("window").values,
            erbFilterbank: try array("erb_fb").values,
            erbInverseFilterbank: try array("erb_inv_fb").values,
            initialMeanNormalization: try array("mean_norm_state").values,
            initialUnitNormalization: try array("unit_norm_state").values)
        let shapes: [(String, [Int])] = [
            ("window", [fftSize]), ("erb_fb", [bins, erbBands]), ("erb_inv_fb", [erbBands, bins]),
            ("mean_norm_state", [erbBands]),
        ]
        for (name, expected) in shapes {
            let shape = try array(name).shape
            guard shape == expected else {
                throw .incompatibleModel("\(name) has shape \(shape), expected \(expected)")
            }
        }
        // Stored as [1, 96] in the conversion.
        let unit = try array("unit_norm_state")
        guard unit.values.count == deepFilterBins else {
            throw .incompatibleModel("unit_norm_state has shape \(unit.shape), expected \(deepFilterBins) values")
        }
        try validate()
    }

    /// Checks the array sizes against the frame sizes.
    func validate() throws(NoiseSuppressionError) {
        guard fftSize == 2 * hopSize else {
            throw .incompatibleModel("the overlap-add needs a 50% hop (fft \(fftSize), hop \(hopSize))")
        }
        guard deepFilterBins <= bins, deepFilterPastFrames >= 0, convolutionLookahead >= deepFilterLookahead
        else { throw .incompatibleModel("inconsistent deep filter settings") }
        let sizes: [(String, Int, Int)] = [
            ("window", window.count, fftSize),
            ("erb_fb", erbFilterbank.count, bins * erbBands),
            ("erb_inv_fb", erbInverseFilterbank.count, erbBands * bins),
            ("mean_norm_state", initialMeanNormalization.count, erbBands),
            ("unit_norm_state", initialUnitNormalization.count, deepFilterBins),
        ]
        for (name, count, expected) in sizes {
            guard count == expected else {
                throw .incompatibleModel("\(name) has \(count) values, expected \(expected)")
            }
        }
    }

    /// The Vorbis window DeepFilterNet uses: `sin(π/2 · sin²(π(n + ½)/N))`.
    /// Squared, its overlapping halves sum to one, so analysis and synthesis
    /// with it at a 50% hop reconstruct the input exactly.
    public static func vorbisWindow(size: Int) -> [Float] {
        (0..<size).map { n in
            let inner = sin(Double.pi * (Double(n) + 0.5) / Double(size))
            return Float(sin(Double.pi / 2 * inner * inner))
        }
    }
}
