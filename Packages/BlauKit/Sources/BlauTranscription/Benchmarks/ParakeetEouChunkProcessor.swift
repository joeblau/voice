@preconcurrency import AVFAudio
import BlauAudio
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// The chunk sizes FluidAudio ships for Parakeet realtime EOU 120M. Each one
/// is a separately exported encoder.
public enum ParakeetEouChunkSize: String, CaseIterable, Codable, Hashable, Sendable {
    case ms160 = "160ms"
    case ms320 = "320ms"
    case ms1280 = "1280ms"

    var fluidAudio: StreamingChunkSize {
        switch self {
        case .ms160: .ms160
        case .ms320: .ms320
        case .ms1280: .ms1280
        }
    }

    var repo: Repo {
        switch self {
        case .ms160: .parakeetEou160
        case .ms320: .parakeetEou320
        case .ms1280: .parakeetEou1280
        }
    }

    /// Samples per encoder window (FluidAudio's `chunkSamples`). For 320 ms
    /// this is 630 ms of audio: the window overlaps the previous one.
    public var windowSamples: Int { fluidAudio.chunkSamples }

    /// Samples the window advances by (FluidAudio's `shiftSamples`): the
    /// step at which new text can appear.
    public var hopSamples: Int { fluidAudio.shiftSamples }

    /// The benchmark case identifier, for example `asr.eou.320ms`.
    public var benchmarkID: String { "asr.eou.\(rawValue)" }
}

/// Runs FluidAudio's `StreamingEouAsrManager` for the streaming benchmark
/// and the background Neural Engine probe.
public actor ParakeetEouChunkProcessor: StreamingChunkProcessor {
    public nonisolated let chunkSize: ParakeetEouChunkSize
    public nonisolated let computeUnits: MLComputeUnits
    private let modelsRoot: URL
    private var manager: StreamingEouAsrManager?

    /// - Parameters:
    ///   - computeUnits: `.cpuAndNeuralEngine` (FluidAudio's default; it
    ///     never dispatches to the GPU, which iOS forbids in the background)
    ///     or `.cpuOnly` for a CPU baseline.
    ///   - modelsRoot: Where model folders live. Defaults to FluidAudio's
    ///     shared `Application Support/FluidAudio/Models`.
    public init(
        chunkSize: ParakeetEouChunkSize,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        modelsRoot: URL = MLModelConfigurationUtils.defaultModelsDirectory()
    ) {
        self.chunkSize = chunkSize
        self.computeUnits = computeUnits
        self.modelsRoot = modelsRoot
    }

    public nonisolated var windowSamples: Int { chunkSize.windowSamples }
    public nonisolated var hopSamples: Int { chunkSize.hopSamples }

    /// The folder holding this chunk size's models.
    public nonisolated var modelDirectory: URL {
        modelsRoot.appendingPathComponent(chunkSize.repo.folderName, isDirectory: true)
    }

    /// Whether every model file is already on disk.
    public nonisolated var modelsAreDownloaded: Bool {
        ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !modelsAreDownloaded else { return }
        try await ModelHub.download(chunkSize.repo, to: modelsRoot) { update in
            progress(update.fractionCompleted)
        }
    }

    public func load() async throws {
        let configuration = MLModelConfigurationUtils.defaultConfiguration(computeUnits: computeUnits)
        let manager = StreamingEouAsrManager(configuration: configuration, chunkSize: chunkSize.fluidAudio)
        try await manager.loadModels(from: modelDirectory)
        self.manager = manager
    }

    public func process(_ samples: [Float]) async throws {
        guard let manager else { throw ParakeetBenchmarkError.notLoaded }
        let buffer = try Self.pcmBuffer(samples)
        _ = try await manager.process(audioBuffer: buffer)
    }

    public func finishUtterance() async throws -> String {
        guard let manager else { throw ParakeetBenchmarkError.notLoaded }
        return try await manager.finish()
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// 16 kHz mono float32: FluidAudio's fast path, so no resampling is
    /// measured.
    static func pcmBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFixture.sampleRate), channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
            let channel = buffer.floatChannelData?[0]
        else {
            throw ParakeetBenchmarkError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}

enum ParakeetBenchmarkError: Error, CustomStringConvertible {
    case notLoaded
    case bufferAllocationFailed

    var description: String {
        switch self {
        case .notLoaded: "The models are not loaded"
        case .bufferAllocationFailed: "Could not allocate an audio buffer"
        }
    }
}
