@preconcurrency import CoreML
import Foundation

/// One 10 ms step of DeepFilterNet3's network, with its recurrent state.
///
/// ``DeepFilterNet3Processor`` owns the signal processing and calls this
/// once per hop. ``CoreMLDeepFilterNet3Network`` runs the Core ML
/// conversion; tests use a scripted network, so the DSP is checked without
/// a model.
public protocol DeepFilterNet3Network: AnyObject {
    /// Computes the gains for the frame `convolutionLookahead` hops behind
    /// the newest features.
    ///
    /// - Parameters:
    ///   - erbFeatures: The last `historyFrames` normalized ERB feature
    ///     frames, oldest first: `[historyFrames, erbBands]`.
    ///   - spectrumFeatures: The last `historyFrames` normalized low-bin
    ///     spectra, real parts then imaginary parts:
    ///     `[2, historyFrames, deepFilterBins]`.
    ///   - mask: Receives the ERB gains, `erbBands` values.
    ///   - coefficients: Receives the deep filter,
    ///     `[deepFilterOrder, deepFilterBins, 2]` (real, imaginary).
    /// - Returns: The network's local SNR estimate for the frame, in dB.
    func step(
        erbFeatures: [Float], spectrumFeatures: [Float], mask: inout [Float], coefficients: inout [Float]
    ) throws -> Float

    /// Clears the recurrent state for a new stream.
    func reset()
}

/// Where Core ML may run DeepFilterNet3.
public enum NoiseSuppressionComputeUnits: String, CaseIterable, Codable, Sendable {
    case cpuOnly
    case cpuAndGPU
    /// Neural Engine with CPU fallback, what the other models use. Keeps the
    /// GPU free, which background audio can't use anyway.
    case cpuAndNeuralEngine
    case all

    var coreML: MLComputeUnits {
        switch self {
        case .cpuOnly: .cpuOnly
        case .cpuAndGPU: .cpuAndGPU
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .all: .all
        }
    }
}

/// DeepFilterNet3's streaming Core ML conversion and its signal processing
/// parameters, loaded once and shared by every ``DeepFilterNet3Suppressor``.
///
/// The model directory holds `DeepFilterNet3-Streaming.mlpackage` (or its
/// compiled `.mlmodelc`) and `auxiliary.npz` from
/// `iky1e/DeepFilterNet3-Streaming-CoreML` (Apache-2.0 / MIT). Fetch the
/// pinned revision with `scripts/fetch-deepfilternet3.sh`.
public struct DeepFilterNet3Model: @unchecked Sendable {
    // `@unchecked`: `MLModel` is immutable after loading and Core ML allows
    // predictions from any thread; each suppressor keeps its own input,
    // output and recurrent-state buffers.

    /// The pinned conversion: `iky1e/DeepFilterNet3-Streaming-CoreML`.
    public static let repository = "iky1e/DeepFilterNet3-Streaming-CoreML"
    /// The commit `scripts/fetch-deepfilternet3.sh` downloads.
    public static let revision = "dfc12319b3a62d09e9d51aace480c981067b9d7b"
    /// The model bundle's name, without extension.
    public static let bundleName = "DeepFilterNet3-Streaming"

    public let model: MLModel
    public let parameters: DeepFilterNet3Parameters
    public let computeUnits: NoiseSuppressionComputeUnits

    public init(model: MLModel, parameters: DeepFilterNet3Parameters, computeUnits: NoiseSuppressionComputeUnits)
        throws
    {
        try CoreMLDeepFilterNet3Network.validate(model.modelDescription, parameters: parameters)
        self.model = model
        self.parameters = parameters
        self.computeUnits = computeUnits
    }

    /// Loads the model and `auxiliary.npz` from `directory`, compiling the
    /// `.mlpackage` first if there is no `.mlmodelc`.
    public static func load(
        directory: URL, computeUnits: NoiseSuppressionComputeUnits = .cpuAndNeuralEngine
    ) async throws -> DeepFilterNet3Model {
        let parameters = try DeepFilterNet3Parameters.load(auxiliary: directory.appending(path: "auxiliary.npz"))
        let compiled = directory.appending(path: "\(bundleName).mlmodelc")
        let package = directory.appending(path: "\(bundleName).mlpackage")
        let url: URL
        if FileManager.default.fileExists(atPath: compiled.path(percentEncoded: false)) {
            url = compiled
        } else if FileManager.default.fileExists(atPath: package.path(percentEncoded: false)) {
            url = try await MLModel.compileModel(at: package)
        } else {
            throw NoiseSuppressionError.incompatibleModel(
                "No \(bundleName).mlmodelc or .mlpackage in \(directory.path(percentEncoded: false))")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreML
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return try DeepFilterNet3Model(model: model, parameters: parameters, computeUnits: computeUnits)
    }

    /// A fresh network with its own buffers and recurrent state.
    public func makeNetwork() throws -> CoreMLDeepFilterNet3Network {
        try CoreMLDeepFilterNet3Network(model: model, parameters: parameters)
    }
}

/// Runs the streaming Core ML conversion of DeepFilterNet3 one hop at a
/// time. Inputs `feat_erb_buf` [1, 1, 10, 32], `feat_spec_buf`
/// [1, 2, 10, 96] and the GRU states `h_enc_in` [1, 1, 256], `h_erb_in` and
/// `h_df_in` [2, 1, 256]; outputs `erb_mask` [1, 1, 1, 32], `df_coefs`
/// [1, 5, 1, 96, 2], `lsnr` and the next GRU states. The recurrent state
/// is fed back from the outputs after every step.
///
/// Not thread-safe: one stream at a time.
public final class CoreMLDeepFilterNet3Network: DeepFilterNet3Network {
    enum Feature {
        static let erb = "feat_erb_buf"
        static let spectrum = "feat_spec_buf"
        static let mask = "erb_mask"
        static let coefficients = "df_coefs"
        static let localSNR = "lsnr"
        /// Recurrent states: input name, output name.
        static let states = [("h_enc_in", "h_enc_out"), ("h_erb_in", "h_erb_out"), ("h_df_in", "h_df_out")]
    }

    private let model: MLModel
    private let erb: MLMultiArray
    private let spectrum: MLMultiArray
    private let states: [MLMultiArray]
    private let features: MLDictionaryFeatureProvider
    private let options = MLPredictionOptions()
    private let maskCount: Int
    private let coefficientCount: Int

    init(model: MLModel, parameters: DeepFilterNet3Parameters) throws {
        let description = model.modelDescription
        try Self.validate(description, parameters: parameters)
        func array(_ name: String) throws -> MLMultiArray {
            let constraint = description.inputDescriptionsByName[name]!.multiArrayConstraint!
            let array = try MLMultiArray(shape: constraint.shape, dataType: .float32)
            array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in pointer.initialize(repeating: 0) }
            return array
        }
        self.model = model
        self.erb = try array(Feature.erb)
        self.spectrum = try array(Feature.spectrum)
        self.states = try Feature.states.map { try array($0.0) }
        var inputs: [String: MLFeatureValue] = [
            Feature.erb: MLFeatureValue(multiArray: erb), Feature.spectrum: MLFeatureValue(multiArray: spectrum),
        ]
        for (index, names) in Feature.states.enumerated() {
            inputs[names.0] = MLFeatureValue(multiArray: states[index])
        }
        self.features = try MLDictionaryFeatureProvider(dictionary: inputs)
        self.maskCount = parameters.erbBands
        self.coefficientCount = parameters.deepFilterOrder * parameters.deepFilterBins * 2
    }

    /// Checks that the model takes and returns what the processor expects.
    static func validate(
        _ description: MLModelDescription, parameters p: DeepFilterNet3Parameters
    ) throws(NoiseSuppressionError) {
        func shape(_ name: String, _ features: [String: MLFeatureDescription]) throws(NoiseSuppressionError) -> [Int] {
            guard let constraint = features[name]?.multiArrayConstraint else {
                throw .incompatibleModel("No multi-array feature named \(name)")
            }
            return constraint.shape.map(\.intValue)
        }
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        let expected: [(String, [Int], [String: MLFeatureDescription])] = [
            (Feature.erb, [1, 1, p.historyFrames, p.erbBands], inputs),
            (Feature.spectrum, [1, 2, p.historyFrames, p.deepFilterBins], inputs),
            (Feature.mask, [1, 1, 1, p.erbBands], outputs),
            (Feature.coefficients, [1, p.deepFilterOrder, 1, p.deepFilterBins, 2], outputs),
        ]
        for (name, wanted, features) in expected {
            let actual = try shape(name, features)
            guard actual == wanted else { throw .incompatibleModel("\(name) has shape \(actual), expected \(wanted)") }
        }
        for (input, output) in Feature.states {
            let inputShape = try shape(input, inputs)
            let outputShape = try shape(output, outputs)
            guard inputShape == outputShape else {
                throw .incompatibleModel("\(input) \(inputShape) doesn't match \(output) \(outputShape)")
            }
        }
    }

    public func step(
        erbFeatures: [Float], spectrumFeatures: [Float], mask: inout [Float], coefficients: inout [Float]
    ) throws -> Float {
        precondition(erbFeatures.count == erb.count && spectrumFeatures.count == spectrum.count)
        Self.write(erbFeatures, to: erb)
        Self.write(spectrumFeatures, to: spectrum)
        let prediction = try model.prediction(from: features, options: options)
        func output(_ name: String) throws -> MLMultiArray {
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
                throw NoiseSuppressionError.predictionFailed("No \(name) in the prediction")
            }
            return array
        }
        try Self.read(output(Feature.mask), into: &mask, count: maskCount)
        try Self.read(output(Feature.coefficients), into: &coefficients, count: coefficientCount)
        for (index, names) in Feature.states.enumerated() {
            let next = try output(names.1)
            var values = [Float](repeating: 0, count: states[index].count)
            try Self.read(next, into: &values, count: values.count)
            Self.write(values, to: states[index])
        }
        var localSNR: [Float] = [0]
        if let snr = prediction.featureValue(for: Feature.localSNR)?.multiArrayValue {
            try Self.read(snr, into: &localSNR, count: 1)
        }
        return localSNR[0]
    }

    public func reset() {
        for state in states {
            state.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in pointer.initialize(repeating: 0) }
        }
    }

    private static func write(_ values: [Float], to array: MLMultiArray) {
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            _ = pointer.update(fromContentsOf: values)
        }
    }

    /// Copies the first `count` values in logical (row-major) order, whatever
    /// the array's precision and strides.
    private static func read(_ array: MLMultiArray, into values: inout [Float], count: Int) throws {
        guard array.count >= count else {
            throw NoiseSuppressionError.predictionFailed("An output has \(array.count) values, expected \(count)")
        }
        if array.dataType == .float32, isContiguous(array) {
            array.withUnsafeBufferPointer(ofType: Float.self) { pointer in
                values.withUnsafeMutableBufferPointer { destination in
                    _ = destination.update(fromContentsOf: pointer.prefix(count))
                }
            }
        } else {
            let scalars = MLShapedArray<Float>(converting: array).scalars
            for index in 0..<count { values[index] = scalars[index] }
        }
    }

    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        var expected = 1
        for (size, stride) in zip(array.shape.map(\.intValue), array.strides.map(\.intValue)).reversed() {
            if size > 1 && stride != expected { return false }
            expected *= size
        }
        return true
    }
}
