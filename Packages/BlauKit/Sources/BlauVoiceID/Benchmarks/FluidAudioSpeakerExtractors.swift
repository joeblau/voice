@preconcurrency import CoreML
import FluidAudio
import Foundation

/// WeSpeaker ResNet34-LM through FluidAudio.
///
/// FluidAudio ships it as the diarizer's `wespeaker_v2` embedding model
/// (pyannote's `wespeaker-voxceleb-resnet34-LM` export, 256-d). Its input
/// is a fixed 10 s waveform plus a frame mask; `DiarizerManager` repeat-pads
/// shorter audio and uses an all-ones mask for a single speaker.
///
/// FluidAudio's diarizer defaults to `.all` compute units, which may use
/// the GPU; iOS doesn't allow GPU work in the background, so this loads
/// with `.cpuAndNeuralEngine` like Blau will.
public actor WeSpeakerExtractor: SpeakerEmbeddingExtractor {
    private let computeUnits: MLComputeUnits
    private var manager: DiarizerManager?

    public init(computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        self.computeUnits = computeUnits
    }

    private var modelsDirectory: URL { DiarizerModels.defaultModelsDirectory() }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let required = DiarizerModels.requiredModelNames
        let present = required.allSatisfy {
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
        guard !present else { return }
        _ = try await DiarizerModels.download(configuration: configuration) { update in
            progress(update.fractionCompleted)
        }
    }

    public func load() async throws {
        let models = try DiarizerModels.load(
            localSegmentationModel: modelsDirectory.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
            localEmbeddingModel: modelsDirectory.appendingPathComponent(ModelNames.Diarizer.embeddingFile),
            configuration: configuration
        )
        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
    }

    public func embed(_ samples: [Float]) async throws -> [Float] {
        guard let manager else { throw SpeakerBenchmarkError.notLoaded }
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    public func unload() async {
        manager?.cleanup()
        manager = nil
    }

    private var configuration: MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: computeUnits)
    }
}

/// CAM++ (192-d) through FluidAudio's `CampPlusEmbedder`, with the compute
/// units FluidAudio chooses (CPU preprocessor, `.cpuAndGPU` model).
public actor CamPlusPlusExtractor: SpeakerEmbeddingExtractor {
    private var directory: URL?
    private var embedder: CampPlusEmbedder?

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        directory = try await CampPlusModels.download { update in progress(update.fractionCompleted) }
    }

    public func load() async throws {
        guard let directory else { throw SpeakerBenchmarkError.notLoaded }
        embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: directory))
    }

    public func embed(_ samples: [Float]) async throws -> [Float] {
        guard let embedder else { throw SpeakerBenchmarkError.notLoaded }
        return try await embedder.embed(audio: samples)
    }

    public func unload() async {
        embedder = nil
    }
}

enum SpeakerBenchmarkError: Error, CustomStringConvertible {
    case notLoaded

    var description: String { "The model is not loaded" }
}
