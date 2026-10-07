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
public actor SileroSpeechProbabilityModel: SpeechProbabilityModel {
    public nonisolated let chunkLength = VadManager.chunkSize

    private let manager: VadManager
    private var state: VadStreamState

    /// Wraps an already constructed `VadManager`.
    public init(manager: VadManager) {
        self.manager = manager
        self.state = VadStreamState.initial()
    }

    /// Loads the model from an installed `.sileroVAD` directory, on the
    /// compute units `ModelManager` warmed it up for (Neural Engine with CPU
    /// fallback).
    ///
    /// - Throws: Core ML's error if the bundle is missing or can't load.
    public init(modelDirectory: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits =
            CoreMLModelWarmer.computeUnits(for: .sileroVAD, bundle: FluidAudioModels.vadModelBundle).coreML
        let model = try await MLModel.load(
            contentsOf: modelDirectory.appending(path: FluidAudioModels.vadModelBundle),
            configuration: configuration
        )
        self.init(manager: VadManager(config: VadConfig(computeUnits: configuration.computeUnits), vadModel: model))
    }

    public func speechProbability(of samples: [Float], at sampleOffset: Int64) async throws -> Float {
        let result = try await manager.processStreamingChunk(samples, state: state)
        state = result.state
        return result.probability
    }

    public func reset() {
        state = VadStreamState.initial()
    }
}
