@preconcurrency import CoreML
import Dispatch
import Foundation

/// Runs the Core ML export of SpeechBrain's VoxLingua107 ECAPA-TDNN
/// (`SpeechBrainECAPAVoxLingua107.mlmodelc`).
///
/// The model takes `mel_features` [1, frames, 60] (Float32, 10 to 3,001
/// frames: 0.1 to 30 s) and returns `log_probabilities` [1, 107]. The graph
/// subtracts the features' mean over time first (SpeechBrain's sentence mean
/// normalization), so the input is the plain log-mel filterbank.
///
/// Like the speaker network, the actor runs on its own serial queue, so
/// the synchronous prediction never blocks a thread of Swift's cooperative
/// pool.
///
/// It runs on the **CPU** by default. The input length is flexible, and on
/// this Mac (M3 Max) 2 s take 6.7 ms on the CPU against 15 ms with the GPU
/// and 22 ms on the Neural Engine (docs/voice-id.md#language-filter-50);
/// the CPU also leaves the Neural Engine to ASR and voice ID, and keeps
/// working with the screen locked (#26).
public actor CoreMLLanguageIDNetwork: LanguageIDNetwork {
    public enum FeatureName {
        public static let features = "mel_features"
        public static let logProbabilities = "log_probabilities"
    }

    public nonisolated let frameRange: ClosedRange<Int>
    public nonisolated let labelCount: Int

    private let model: MLModel
    private let options = MLPredictionOptions()
    private let queue = DispatchSerialQueue(label: "com.joeblau.blau.voiceid.language", qos: .userInitiated)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Loads (and on first use on this OS, compiles) the model bundle at
    /// `url`.
    public static func load(
        contentsOf url: URL, computeUnits: SpeakerEmbeddingComputeUnits = .cpuOnly
    ) async throws -> CoreMLLanguageIDNetwork {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreML
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return try CoreMLLanguageIDNetwork(model: model)
    }

    /// Wraps a loaded model after checking its input and output.
    ///
    /// - Throws: ``LanguageIDError/incompatibleModel(_:)`` unless the model
    ///   takes a Float32 `mel_features` [1, frames, 60] and returns
    ///   `log_probabilities` with one value per label.
    public init(model: MLModel) throws {
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName[FeatureName.features]?.multiArrayConstraint else {
            throw LanguageIDError.incompatibleModel("No multi-array input named \(FeatureName.features)")
        }
        guard let output = description.outputDescriptionsByName[FeatureName.logProbabilities]?.multiArrayConstraint
        else {
            throw LanguageIDError.incompatibleModel("No multi-array output named \(FeatureName.logProbabilities)")
        }
        guard input.dataType == .float32 else {
            throw LanguageIDError.incompatibleModel("\(FeatureName.features) must be Float32")
        }
        let shape = input.shape.map(\.intValue)
        guard shape.count == 3, shape[2] == LanguageIDFeatureExtractor.melCount else {
            throw LanguageIDError.incompatibleModel("\(FeatureName.features) has shape \(shape); expected [1, n, 60]")
        }
        let ranges = input.shapeConstraint.type == .range ? input.shapeConstraint.sizeRangeForDimension : []
        if ranges.count == 3 {
            let frames = ranges[1].rangeValue
            frameRange = max(1, frames.location)...(frames.location + max(0, frames.length - 1))
        } else {
            frameRange = shape[1]...shape[1]
        }
        labelCount = output.shape.map(\.intValue).reduce(1, *)
        guard labelCount == VoxLingua107.codes.count else {
            throw LanguageIDError.incompatibleModel("\(labelCount) outputs; expected \(VoxLingua107.codes.count)")
        }
        self.model = model
    }

    public func logProbabilities(_ features: LanguageIDFeatures) throws -> [Float] {
        precondition(frameRange.contains(features.frameCount), "The model takes \(frameRange) frames")
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: features.frameCount), NSNumber(value: LanguageIDFeatureExtractor.melCount)],
            dataType: .float32)
        let width = LanguageIDFeatureExtractor.melCount
        let strides = array.strides.map(\.intValue)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            features.values.withUnsafeBufferPointer { values in
                for frame in 0..<features.frameCount {
                    for mel in 0..<width {
                        pointer[frame * strides[1] + mel * strides[2]] = values[frame * width + mel]
                    }
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            FeatureName.features: MLFeatureValue(multiArray: array)
        ])
        let output = try model.prediction(from: provider, options: options)
        guard let values = output.featureValue(for: FeatureName.logProbabilities)?.multiArrayValue else {
            throw LanguageIDError.invalidOutput
        }
        // [1, labels], honoring strides and Float16 outputs.
        guard let row = try? CoreMLSpeakerEmbeddingNetwork.rows(of: values, count: 1, dimension: labelCount).first
        else {
            throw LanguageIDError.invalidOutput
        }
        return row
    }
}
