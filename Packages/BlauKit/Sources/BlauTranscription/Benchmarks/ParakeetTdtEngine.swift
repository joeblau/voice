@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 through FluidAudio's `AsrManager`, for the offline
/// benchmark.
///
/// **Cold vs warm load.** The downloaded models are already compiled
/// (`.mlmodelc`), but the first load on a device still specializes them for
/// its Neural Engine, and the OS caches that result per model location.
/// `loadCold()` therefore copies the model folder to a new, unique
/// directory before loading, which misses the cache the way a fresh install
/// does; `loadWarm()` loads the same copy again. The copy is deleted on
/// `unload()`.
public actor ParakeetTdtEngine: OfflineTranscriptionEngine {
    private let version: AsrModelVersion
    private let scratchRoot: URL
    private var downloadedDirectory: URL?
    private var loadedDirectory: URL?
    private var models: AsrModels?
    private var manager: AsrManager?

    public init(scratchRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("BlauBenchmarks")) {
        version = .v3
        self.scratchRoot = scratchRoot
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadedDirectory = try await AsrModels.download(version: version) { update in
            progress(update.fractionCompleted)
        }
    }

    public func loadCold() async throws {
        guard let downloadedDirectory else { throw ParakeetBenchmarkError.notLoaded }
        removeCopy()
        let copy = scratchRoot.appendingPathComponent("tdt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: downloadedDirectory, to: copy)
        loadedDirectory = copy
        try await load(from: copy)
    }

    public func loadWarm() async throws {
        guard let loadedDirectory else { throw ParakeetBenchmarkError.notLoaded }
        manager = nil
        models = nil
        try await load(from: loadedDirectory)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager, let models else { throw ParakeetBenchmarkError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        models = nil
        removeCopy()
    }

    private func load(from directory: URL) async throws {
        let models = try AsrModels.loadLocal(from: directory, version: version)
        let manager = AsrManager(config: .default, models: models)
        self.models = models
        self.manager = manager
    }

    private func removeCopy() {
        if let loadedDirectory {
            try? FileManager.default.removeItem(at: loadedDirectory)
        }
        loadedDirectory = nil
    }
}
