import FluidAudio
import Foundation

/// How Blau's model store lines up with FluidAudio 0.17.5.
///
/// `ModelManager` is the only code that downloads models. FluidAudio's
/// convenience loaders (`VadManager(config:)`, `StreamingEouAsrManager
/// .loadModels(to:)`, `AsrModels.downloadAndLoad`, ...) would otherwise
/// fetch their own unpinned copies into a second cache, over any network.
/// Blau loads from ``ModelManager/directory(for:)`` with FluidAudio's
/// local-directory APIs instead:
///
/// | Model | FluidAudio call |
/// | --- | --- |
/// | `.sileroVAD` | `VadManager(config:vadModel:)` with the `MLModel` at ``vadModelBundle`` |
/// | `.parakeetRealtimeEOU` | `StreamingEouAsrManager(chunkSize: .ms320).loadModels(from:)` |
/// | `.parakeetTDTv3` | `AsrModels.loadLocal(from:version: .v3)` |
/// | `.speakerEmbedding` | `MLModel` at ``speakerEmbeddingBundle`` |
public enum FluidAudioModels {
    /// Makes every FluidAudio download path throw `DownloadError
    /// .networkDisabled` instead of touching the network, so nothing but
    /// `ModelManager` downloads models. Call once at launch, before any
    /// FluidAudio API is used.
    public static func disableImplicitDownloads() {
        ModelHub.offlineMode = true
    }

    /// The Silero VAD bundle FluidAudio's `VadManager` expects.
    public static let vadModelBundle = ModelNames.VAD.sileroVadFile

    /// The WeSpeaker embedding bundle FluidAudio's diarizer uses.
    public static let speakerEmbeddingBundle = ModelNames.Diarizer.embeddingFile

    /// The models FluidAudio loads. (`.textEmbedding` is Blau's own Core
    /// ML model, loaded by BlauMemory.)
    public static let models: [ModelID] = [.sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3]

    /// The top-level files and bundles FluidAudio's local loaders read from
    /// a model's directory. The pinned manifest must provide all of them
    /// (a test checks). Empty for a model FluidAudio doesn't load.
    public static func requiredEntries(for id: ModelID) -> Set<String> {
        switch id {
        case .sileroVAD:
            ModelNames.VAD.requiredModels
        case .parakeetRealtimeEOU:
            ModelNames.ParakeetEOU.requiredModels
        case .parakeetTDTv3:
            ModelNames.ASR.requiredModelsV3(precision: .int8).union([ModelNames.ASR.vocabularyFile])
        case .speakerEmbedding:
            [ModelNames.Diarizer.embeddingFile]
        case .textEmbedding:
            []
        }
    }

    /// The upstream repository, directory and FluidAudio's own pinned
    /// revision (`main` when FluidAudio doesn't pin one) for `id`, or `nil`
    /// for a model FluidAudio doesn't load.
    public static func upstream(for id: ModelID) -> (repository: String, directory: String, revision: String)? {
        let repo: Repo
        switch id {
        case .sileroVAD: repo = .vad
        case .parakeetRealtimeEOU: repo = .parakeetEou320
        case .parakeetTDTv3: repo = .parakeetV3
        case .speakerEmbedding: repo = .diarizer
        case .textEmbedding: return nil
        }
        return (repo.remotePath, repo.subPath ?? "", repo.revision)
    }
}
