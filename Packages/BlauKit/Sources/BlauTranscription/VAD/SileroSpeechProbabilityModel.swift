import BlauCore
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Silero VAD v6 (FluidAudio's unified 256 ms Core ML model) as a streaming
/// `SpeechProbabilityModel`.
///
/// Each call runs FluidAudio's `VadManager.processStreamingChunk` on 4096
/// samples and carries the LSTM state (`VadStreamState`) to the next call.
/// Only the probability is used: FluidAudio's own start/end state machine
/// has no minimum speech duration or maximum segment length, so
/// `VoiceActivitySegmenter` runs Blau's (see docs/vad.md).
///
/// Load it from the directory `ModelManager` installed, never with
/// FluidAudio's downloading initialiser:
///
/// ```swift
/// guard let directory = modelManager.directory(for: .sileroVAD) else { return }
/// let model = try await SileroSpeechProbabilityModel(modelDirectory: directory)
/// ```
///
/// **Backends (#26).** A model loaded from a directory can move between the
/// Neural Engine and the CPU while it runs (`InferenceBackendSwitchable`),
/// which `BackgroundInferenceMonitor` does when iOS restricts the Neural
/// Engine off screen (docs/background.md). The LSTM state carries over: both
/// backends run the same weights.
public actor SileroSpeechProbabilityModel: SpeechProbabilityModel, InferenceBackendSwitchable {
    public nonisolated let chunkLength = VadManager.chunkSize
    public nonisolated let inferenceStage = "vad"
    public nonisolated let supportedBackends: [InferenceBackend]

    private var manager: VadManager
    private var state: VadStreamState
    private var backend: InferenceBackend
    /// The compiled bundle, when the model was loaded from disk (the only
    /// way it can be reloaded on another backend).
    private let bundleURL: URL?

    /// Wraps an already constructed `VadManager`. It can't change backend.
    public init(manager: VadManager) {
        self.manager = manager
        self.state = VadStreamState.initial()
        self.backend = .neuralEngine
        self.bundleURL = nil
        self.supportedBackends = [.neuralEngine]
    }

    /// Loads the model from an installed `.sileroVAD` directory, on the
    /// compute units `ModelManager` warmed it up for (Neural Engine with CPU
    /// fallback) or, with `backend: .cpu`, on the CPU only.
    ///
    /// - Throws: Core ML's error if the bundle is missing or can't load.
    public init(modelDirectory: URL, backend: InferenceBackend = .neuralEngine) async throws {
        let bundleURL = modelDirectory.appending(path: FluidAudioModels.vadModelBundle)
        self.manager = try await Self.loadManager(bundleURL: bundleURL, backend: backend)
        self.state = VadStreamState.initial()
        self.backend = backend
        self.bundleURL = bundleURL
        self.supportedBackends = [.neuralEngine, .cpu]
    }

    public func speechProbability(of samples: [Float], at sampleOffset: Int64) async throws -> Float {
        let result = try await manager.processStreamingChunk(samples, state: state)
        state = result.state
        return result.probability
    }

    public func reset() {
        state = VadStreamState.initial()
    }

    // MARK: InferenceBackendSwitchable

    public var inferenceBackend: InferenceBackend { backend }

    /// Loads the model for `backend` while chunks keep running on the
    /// current one, then swaps. A chunk already running finishes on the old
    /// model; the stream state carries over.
    public func switchInferenceBackend(to backend: InferenceBackend) async throws {
        guard backend != self.backend else { return }
        guard supportedBackends.contains(backend), let bundleURL else {
            throw InferenceBackendError.unsupported(stage: inferenceStage, backend: backend)
        }
        let replacement = try await Self.loadManager(bundleURL: bundleURL, backend: backend)
        manager = replacement
        self.backend = backend
    }

    /// Core ML compute units for `backend`: the warm-up's units for the
    /// Neural Engine (so the compiled model it cached is reused), `.cpuOnly`
    /// for the CPU.
    static func computeUnits(for backend: InferenceBackend) -> MLComputeUnits? {
        switch backend {
        case .neuralEngine:
            CoreMLModelWarmer.computeUnits(for: .sileroVAD, bundle: FluidAudioModels.vadModelBundle).coreML
        case .cpu:
            .cpuOnly
        case .systemSpeech:
            nil
        }
    }

    private static func loadManager(bundleURL: URL, backend: InferenceBackend) async throws -> VadManager {
        guard let computeUnits = computeUnits(for: backend) else {
            throw InferenceBackendError.unsupported(stage: "vad", backend: backend)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try await MLModel.load(contentsOf: bundleURL, configuration: configuration)
        return VadManager(config: VadConfig(computeUnits: computeUnits), vadModel: model)
    }
}
