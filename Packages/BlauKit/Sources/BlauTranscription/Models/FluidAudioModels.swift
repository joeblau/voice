import FluidAudio
import Foundation
import Synchronization

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
/// | `.parakeetRealtimeEOU1280` | `StreamingEouAsrManager(chunkSize: .ms1280).loadModels(from:)` |
/// | `.parakeetTDTv3` | `AsrModels.loadLocal(from:version: .v3)` |
/// | `.speakerEmbedding` | `MLModel` at ``speakerEmbeddingBundle`` |
public enum FluidAudioModels {
    /// Makes every FluidAudio download path throw `DownloadError
    /// .networkDisabled` instead of touching the network, so nothing but
    /// `ModelManager` downloads models. Call once at launch, before any
    /// FluidAudio API is used.
    ///
    /// Inside a ``withImplicitDownloads(isolation:_:)`` scope the flag stays
    /// off until the outermost scope ends, which then turns it on.
    public static func disableImplicitDownloads() {
        implicitDownloadScopes.withLock { scopes in
            if scopes.depth > 0 {
                scopes.restoredOfflineMode = true
            } else {
                ModelHub.offlineMode = true
            }
        }
    }

    /// Whether FluidAudio's own download paths may currently touch the
    /// network (`ModelHub.offlineMode` is off).
    public static var implicitDownloadsAllowed: Bool { !ModelHub.offlineMode }

    /// Runs `body` with FluidAudio's own downloads allowed, then puts
    /// `ModelHub.offlineMode` back the way it was.
    ///
    /// For the debug benchmark screen and background probe only (#22): their
    /// cases fetch models through FluidAudio's loaders (including variants
    /// the pinned manifest doesn't have, like EOU 160 ms and CAM++), but the
    /// app turns offline mode on at launch, so without this every download
    /// throws `networkDisabled` / `modelMissing`. Production code never
    /// calls it: it loads from ``ModelManager/directory(for:)`` with
    /// FluidAudio's local-directory APIs, which don't read the flag.
    ///
    /// Scopes may overlap (each one counts); offline mode returns when the
    /// last one ends.
    public static func withImplicitDownloads<T, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        beginImplicitDownloads()
        defer { endImplicitDownloads() }
        return try await body()
    }

    private struct ImplicitDownloadScopes {
        /// Open ``withImplicitDownloads(isolation:_:)`` scopes.
        var depth = 0
        /// `ModelHub.offlineMode` to restore when the last scope ends.
        var restoredOfflineMode = false
    }

    private static let implicitDownloadScopes = Mutex(ImplicitDownloadScopes())

    private static func beginImplicitDownloads() {
        implicitDownloadScopes.withLock { scopes in
            if scopes.depth == 0 { scopes.restoredOfflineMode = ModelHub.offlineMode }
            scopes.depth += 1
            ModelHub.offlineMode = false
        }
    }

    private static func endImplicitDownloads() {
        implicitDownloadScopes.withLock { scopes in
            scopes.depth -= 1
            if scopes.depth == 0 { ModelHub.offlineMode = scopes.restoredOfflineMode }
        }
    }

    /// The Silero VAD bundle FluidAudio's `VadManager` expects.
    public static let vadModelBundle = ModelNames.VAD.sileroVadFile

    /// The WeSpeaker embedding bundle FluidAudio's diarizer uses.
    public static let speakerEmbeddingBundle = ModelNames.Diarizer.embeddingFile

    /// The models FluidAudio loads. (`.textEmbedding` and `.languageID` are
    /// Core ML models Blau loads itself, in BlauMemory and BlauVoiceID.)
    public static let models: [ModelID] = [
        .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3, .parakeetRealtimeEOU1280,
    ]

    /// The top-level files and bundles FluidAudio's local loaders read from
    /// a model's directory. The pinned manifest must provide all of them
    /// (a test checks). Empty for a model FluidAudio doesn't load.
    public static func requiredEntries(for id: ModelID) -> Set<String> {
        switch id {
        case .sileroVAD:
            ModelNames.VAD.requiredModels
        case .parakeetRealtimeEOU, .parakeetRealtimeEOU1280:
            ModelNames.ParakeetEOU.requiredModels
        case .parakeetTDTv3:
            ModelNames.ASR.requiredModelsV3(precision: .int8).union([ModelNames.ASR.vocabularyFile])
        case .speakerEmbedding:
            [ModelNames.Diarizer.embeddingFile]
        case .textEmbedding, .languageID:
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
        case .parakeetRealtimeEOU1280: repo = .parakeetEou1280
        case .parakeetTDTv3: repo = .parakeetV3
        case .speakerEmbedding: repo = .diarizer
        case .textEmbedding, .languageID: return nil
        }
        return (repo.remotePath, repo.subPath ?? "", repo.revision)
    }
}
