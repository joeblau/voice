@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Testing

@testable import BlauTranscription

/// Downloads the real pinned models from Hugging Face, warms them up with
/// Core ML, loads them with FluidAudio, then relaunches offline. Off by
/// default (it downloads hundreds of megabytes); run it with
///
///     BLAU_MODEL_DOWNLOAD_SMOKE=1 swift test --filter ModelDownloadSmokeTests
///
/// Optional environment:
/// - `BLAU_MODEL_DOWNLOAD_SMOKE_MODELS`: comma-separated `ModelID`s
///   (default: the required models).
/// - `BLAU_MODEL_DOWNLOAD_SMOKE_DIR`: store root to use and keep (default: a
///   temporary directory, deleted afterwards). Point two runs at the same
///   directory to test resuming.
@MainActor
@Suite(
    "Real model download (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_MODEL_DOWNLOAD_SMOKE"] == "1"),
    .serialized
)
struct ModelDownloadSmokeTests {
    let environment = ProcessInfo.processInfo.environment

    var selectedModels: [ModelID] {
        guard let list = environment["BLAU_MODEL_DOWNLOAD_SMOKE_MODELS"] else {
            return ModelID.allCases.filter(\.isRequired)
        }
        return list.split(separator: ",").compactMap { ModelID(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    @Test(.timeLimit(.minutes(30)))
    func downloadsLoadsAndRelaunchesOffline() async throws {
        // FluidAudio must never download on its own.
        FluidAudioModels.disableImplicitDownloads()

        let temp = try TemporaryDirectory()
        let root =
            environment["BLAU_MODEL_DOWNLOAD_SMOKE_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? temp.url
        let selected = Set(selectedModels)
        let manifest = ModelManifest(models: ModelManifest.pinned.models.filter { selected.contains($0.id) })
        let preferences = InMemoryModelPreferencesStore(
            ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: true))

        // First launch: download over the real network and warm up with Core ML.
        let manager = ModelManager(
            manifest: manifest, store: ModelStore(root: root), preferencesStore: preferences,
            systemVersion: "smoke-\(UUID().uuidString)")
        let started = ContinuousClock.now
        await manager.start()
        await manager.waitUntilIdle()
        let elapsed = ContinuousClock.now - started

        #expect(manager.isExcludedFromBackup == true)
        for descriptor in manifest.models {
            #expect(manager.state(of: descriptor.id) == .ready, "\(descriptor.id): \(manager.state(of: descriptor.id))")
            print(
                "[smoke] \(descriptor.id.rawValue): \(descriptor.totalBytes) bytes, warm-up \(manager.warmUpDurations[descriptor.id].map { "\($0)" } ?? "-")"
            )
        }
        print("[smoke] first launch took \(elapsed); disk usage \(manager.totalDiskUsage) bytes at \(root.path())")

        // FluidAudio loads each model from the manager's directory.
        for id in selected {
            let directory = try #require(manager.directory(for: id))
            try await loadWithFluidAudio(id, from: directory)
        }

        // Second launch: offline. Everything is ready without the network.
        let offline = ModelManager(
            manifest: manifest, store: ModelStore(root: root),
            transport: ModelFixtures.Transport(manifest: ModelManifest(models: [])),
            networkMonitor: StaticNetworkMonitor(.offline), preferencesStore: preferences,
            systemVersion: "smoke-offline-\(UUID().uuidString)")
        await offline.start()
        await offline.waitUntilIdle()
        for descriptor in manifest.models {
            #expect(offline.state(of: descriptor.id) == .ready, "\(descriptor.id) offline")
        }
        #expect(offline.isReady || !selected.isSuperset(of: ModelID.allCases.filter(\.isRequired)))
    }

    private func loadWithFluidAudio(_ id: ModelID, from directory: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        switch id {
        case .sileroVAD:
            let model = try MLModel(
                contentsOf: directory.appending(path: FluidAudioModels.vadModelBundle), configuration: configuration)
            let vad = VadManager(config: .default, vadModel: model)
            let results = try await vad.process([Float](repeating: 0, count: 16_000))
            #expect(!results.isEmpty)
            #expect(results.allSatisfy { !$0.isVoiceActive }, "Silence is not speech")
        case .parakeetRealtimeEOU:
            let asr = StreamingEouAsrManager(configuration: configuration, chunkSize: .ms320)
            try await asr.loadModels(from: directory)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            _ = try await asr.process(audioBuffer: buffer)
            _ = try await asr.finish()
        case .parakeetTDTv3:
            _ = try AsrModels.loadLocal(from: directory, version: .v3)
        case .speakerEmbedding:
            _ = try MLModel(
                contentsOf: directory.appending(path: FluidAudioModels.speakerEmbeddingBundle),
                configuration: configuration)
        case .textEmbedding:
            // Blau's own model (BlauMemory's TextEmbeddingModel loads it with
            // its tokenizer and token table); here, just Core ML.
            let bundles = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
                .filter { $0.hasSuffix(".mlmodelc") }
            #expect(!bundles.isEmpty)
            for bundle in bundles {
                _ = try MLModel(contentsOf: directory.appending(path: bundle), configuration: configuration)
            }
        }
        print("[smoke] FluidAudio loaded \(id.rawValue)")
    }
}
