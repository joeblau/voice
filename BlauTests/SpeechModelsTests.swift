import BlauTranscription
import Foundation
import Testing

@testable import Blau

@MainActor
@Suite("Speech models composition")
struct SpeechModelsTests {
    @Test func productionManagerUsesThePinnedManifest() {
        let manager = SpeechModels.makeManager(environment: [:])
        #expect(manager.manifest == ModelManifest.pinned)
        #expect(!manager.isReady, "Nothing has been checked before start()")
    }

    @Test func fixtureEnvironmentSwitchesToFixtureModels() {
        let root = FileManager.default.temporaryDirectory.appending(path: "blau-tests-\(UUID().uuidString)")
        let manager = SpeechModels.makeManager(
            environment: [SpeechModels.fixturesEnvironmentKey: "1"], fixtureRoot: root)
        #expect(manager.manifest != ModelManifest.pinned)
        #expect(manager.manifest.models.map(\.id) == ModelManifest.pinned.models.map(\.id))
    }

    /// UI tests that only select an xAI stub still never download real models.
    @Test func anyUITestStubSwitchesToFixtureModels() {
        #expect(SpeechModels.usesFixtures(["BLAU_UI_TEST_XAI": "accept"]))
        #expect(SpeechModels.usesFixtures(["BLAU_UI_TEST_ANYTHING": ""]))
        #expect(SpeechModels.usesFixtures([SpeechModels.fixturesEnvironmentKey: "1"]))
        #expect(SpeechModels.usesFixtures([SpeechModels.hostedTestsEnvironmentKey: "/tmp/config"]))
        #expect(!SpeechModels.usesFixtures([:]))
        #expect(!SpeechModels.usesFixtures([SpeechModels.fixturesEnvironmentKey: "0", "BLAU_OTHER": "1"]))

        let root = FileManager.default.temporaryDirectory.appending(path: "blau-tests-\(UUID().uuidString)")
        let manager = SpeechModels.makeManager(environment: ["BLAU_UI_TEST_XAI": "reject"], fixtureRoot: root)
        #expect(manager.manifest != ModelManifest.pinned)
    }

    /// Acceptance criterion: the real store, in the app's own Application
    /// Support on iOS, is excluded from backup.
    @Test func applicationSupportStoreIsExcludedFromBackup() throws {
        let store = try ModelStore.applicationSupport()
        #expect(store.root.path(percentEncoded: false).hasSuffix("Library/Application Support/Blau/Models/"))
        #expect(try store.prepare())
        #expect(ModelStore.isExcludedFromBackup(store.root))
    }

    @Test func fixtureManagerReachesReady() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "blau-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SpeechModels.fixtureManager(root: root, delayPerChunk: .zero)
        await manager.start()
        await manager.waitUntilIdle()
        #expect(manager.isReady)
        #expect(manager.isExcludedFromBackup == true)
        #expect(manager.directory(for: .parakeetRealtimeEOU) != nil)
    }
}
