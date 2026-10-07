@preconcurrency import CoreML
import Dispatch
import Foundation

/// Where Core ML may run the speaker model.
public enum SpeakerEmbeddingComputeUnits: String, CaseIterable, Codable, Sendable {
    case cpuOnly
    case cpuAndGPU
    /// Neural Engine with CPU fallback: the production setting. It matches
    /// the model warm-up (`CoreMLModelWarmer`), and leaves the GPU alone,
    /// which keeps the model usable in the background.
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

/// Runs FluidAudio's WeSpeaker ResNet34-LM Core ML model
/// (`wespeaker_v2.mlmodelc`).
///
/// The model takes `waveform` [3, 160000] and `mask` [3, 589] and returns
/// `embedding` [3, 256], but only reads the first waveform row: the three
/// rows are three speaker masks over one 10 s chunk (see
/// ``SpeakerEmbeddingNetworkShape``). So each run embeds one waveform. It is
/// repeated to fill the 10 s row (``SpeakerEmbeddingInput/tile(_:into:)``,
/// as FluidAudio's `EmbeddingExtractor` does) under an all-ones mask, so the
/// pooling covers every frame, and the first output row is the embedding.
/// The other mask rows are all ones too, so no row divides by an empty mask.
///
/// The actor owns the model and its input buffers, which are allocated once
/// and reused. It runs on its own serial queue, so the synchronous Core ML
/// prediction (milliseconds on the Neural Engine) never blocks a thread of
/// Swift's cooperative pool.
public actor CoreMLSpeakerEmbeddingNetwork: SpeakerEmbeddingNetwork {
    /// Tensor names in the FluidAudio conversion.
    public enum FeatureName {
        public static let waveform = "waveform"
        public static let mask = "mask"
        public static let embedding = "embedding"
    }

    public nonisolated let shape: SpeakerEmbeddingNetworkShape

    private let model: MLModel
    private let waveform: MLMultiArray
    private let mask: MLMultiArray
    private let features: MLDictionaryFeatureProvider
    private let options = MLPredictionOptions()
    private let queue = DispatchSerialQueue(label: "com.joeblau.blau.voiceid.embedding", qos: .userInitiated)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Loads (and on first use on this OS, compiles) the model bundle at
    /// `url`.
    public static func load(
        contentsOf url: URL,
        computeUnits: SpeakerEmbeddingComputeUnits = .cpuAndNeuralEngine
    ) async throws -> CoreMLSpeakerEmbeddingNetwork {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreML
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return try CoreMLSpeakerEmbeddingNetwork(model: model)
    }

    /// Wraps a loaded model after checking its inputs and outputs.
    ///
    /// - Throws: ``SpeakerEmbedderError/incompatibleModel(_:)`` if the model
    ///   doesn't take `waveform` and `mask` Float32 arrays and return an
    ///   `embedding` array with the same number of rows.
    public init(model: MLModel) throws {
        let description = model.modelDescription
        func constraint(_ name: String, in features: [String: MLFeatureDescription]) throws -> MLMultiArrayConstraint {
            guard let constraint = features[name]?.multiArrayConstraint else {
                throw SpeakerEmbedderError.incompatibleModel("No multi-array feature named \(name)")
            }
            return constraint
        }
        let waveformConstraint = try constraint(FeatureName.waveform, in: description.inputDescriptionsByName)
        let maskConstraint = try constraint(FeatureName.mask, in: description.inputDescriptionsByName)
        let embeddingConstraint = try constraint(FeatureName.embedding, in: description.outputDescriptionsByName)
        guard waveformConstraint.dataType == .float32, maskConstraint.dataType == .float32 else {
            throw SpeakerEmbedderError.incompatibleModel("Inputs must be Float32")
        }
        let shape = try SpeakerEmbeddingNetworkShape(
            waveform: waveformConstraint.shape.map(\.intValue),
            mask: maskConstraint.shape.map(\.intValue),
            embedding: embeddingConstraint.shape.map(\.intValue)
        )

        let waveform = try MLMultiArray(shape: waveformConstraint.shape, dataType: .float32)
        waveform.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            pointer.initialize(repeating: 0)
        }
        let mask = try MLMultiArray(shape: maskConstraint.shape, dataType: .float32)
        // Every frame is the speaker: the segment is speech (VAD already cut
        // it), and the padding repeats that same speech.
        mask.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            pointer.initialize(repeating: 1)
        }
        self.shape = shape
        self.model = model
        self.waveform = waveform
        self.mask = mask
        self.features = try MLDictionaryFeatureProvider(dictionary: [
            FeatureName.waveform: MLFeatureValue(multiArray: waveform),
            FeatureName.mask: MLFeatureValue(multiArray: mask),
        ])
    }

    public func embed(_ input: [Float]) throws -> [Float] {
        precondition(
            (1...shape.sampleCount).contains(input.count), "The waveform must have 1...\(shape.sampleCount) samples")

        let sampleCount = shape.sampleCount
        waveform.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            // Row 0 starts at the beginning whatever the row stride is.
            let row = UnsafeMutableBufferPointer(rebasing: pointer[0..<sampleCount])
            input.withUnsafeBufferPointer { SpeakerEmbeddingInput.tile($0, into: row) }
        }

        let output = try model.prediction(from: features, options: options)
        guard let embedding = output.featureValue(for: FeatureName.embedding)?.multiArrayValue else {
            throw SpeakerEmbedderError.invalidOutput
        }
        return try Self.rows(of: embedding, count: 1, dimension: shape.dimension)[0]
    }

    /// The first `count` rows of a [slots, dimension] array, honoring its
    /// strides (Neural Engine outputs can be padded).
    static func rows(of array: MLMultiArray, count: Int, dimension: Int) throws -> [[Float]] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == 2, shape[0] >= count, shape[1] == dimension else {
            throw SpeakerEmbedderError.invalidOutput
        }
        func read<Scalar: MLShapedArrayScalar & BinaryFloatingPoint>(_: Scalar.Type) -> [[Float]] {
            array.withUnsafeBufferPointer(ofType: Scalar.self) { pointer in
                (0..<count).map { row in
                    (0..<dimension).map { column in Float(pointer[row * strides[0] + column * strides[1]]) }
                }
            }
        }
        switch array.dataType {
        case .float32: return read(Float.self)
        case .float16: return read(Float16.self)
        case .double: return read(Double.self)
        default:
            return (0..<count).map { row in
                (0..<dimension).map { column in array[[row, column] as [NSNumber]].floatValue }
            }
        }
    }
}
