import BlauTelemetry
import BlauTranscription
import Foundation

/// Builds the app's `ModelManager`: the real one, or (for UI tests,
/// performance tests and previews) one that runs on tiny in-memory fixture
/// models with no network and no Core ML.
enum SpeechModels {
    /// Launch environment variable that switches to fixture models. Only a
    /// test runner or Xcode can set launch environment variables, so it is
    /// honored in every configuration; the performance tests run Release.
    static let fixturesEnvironmentKey = "BLAU_MODEL_FIXTURES"

    /// Set by XCTest in an app that hosts unit tests.
    static let hostedTestsEnvironmentKey = "XCTestConfigurationFilePath"

    /// UI tests select hermetic stubs with `BLAU_UI_TEST_*` launch
    /// environment variables (for example `BLAU_UI_TEST_XAI`). Any of them
    /// also selects fixture models, so a UI test can never start a real
    /// model download, even if it doesn't set ``fixturesEnvironmentKey``.
    static let uiTestEnvironmentPrefix = "BLAU_UI_TEST_"

    /// Whether `environment` asks for fixture models.
    static func usesFixtures(_ environment: [String: String]) -> Bool {
        environment[fixturesEnvironmentKey] == "1"
            || environment[hostedTestsEnvironmentKey] != nil
            || environment.keys.contains { $0.hasPrefix(uiTestEnvironmentPrefix) }
    }

    @MainActor
    static func makeManager(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixtureRoot: URL = defaultFixtureRoot
    ) -> ModelManager {
        // Unit and UI tests run the app: never download real models there.
        if usesFixtures(environment) {
            Log.ui.notice("Using fixture speech models")
            return fixtureManager(root: fixtureRoot)
        }

        // ModelManager is the only thing that downloads models: FluidAudio's
        // loaders must never fetch their own (unpinned, any-network) copies.
        FluidAudioModels.disableImplicitDownloads()

        let store: ModelStore
        do {
            store = try ModelStore.applicationSupport()
        } catch {
            Log.ui.fault("No Application Support directory: \(error.localizedDescription, privacy: .public)")
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            store = ModelStore(root: library.appending(path: "Application Support/Blau/Models"))
        }
        return ModelManager(store: store)
    }

    static var defaultFixtureRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "blau-fixture-models", directoryHint: .isDirectory)
    }

    /// A manager over fixture models that downloads at a visible pace. Every
    /// launch starts from a fresh install.
    @MainActor
    static func fixtureManager(
        root: URL = defaultFixtureRoot,
        delayPerChunk: Duration = .milliseconds(15)
    ) -> ModelManager {
        try? FileManager.default.removeItem(at: root)
        // The models the real manifest has, so fixture launches look like
        // production (the text embedding model isn't pinned yet, #60).
        let manifest = ModelFixtures.manifest(
            bytesPerFile: 512 * 1024, ids: ModelManifest.pinned.models.map(\.id))
        return ModelManager(
            manifest: manifest,
            store: ModelStore(root: root),
            transport: ModelFixtures.Transport(manifest: manifest, chunkCount: 25, delayPerChunk: delayPerChunk),
            networkMonitor: StaticNetworkMonitor(.unmetered),
            warmer: ModelFixtures.Warmer(duration: .milliseconds(300)),
            preferencesStore: InMemoryModelPreferencesStore()
        )
    }
}

extension Int64 {
    /// "225 MB".
    var formattedByteCount: String {
        formatted(.byteCount(style: .file))
    }
}
