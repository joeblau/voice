import BlauCore
import Foundation
import Testing

@testable import BlauTranscription

/// Onboarding's speech model step (#44): which setup phases need the user.
@MainActor
@Suite("Model setup onboarding")
struct ModelSetupOnboardingTests {
    private func status(_ phase: ModelSetupStatus.Phase) -> ModelSetupStatus {
        ModelSetupStatus(phase: phase, bytesReceived: 0, totalBytes: 1)
    }

    @Test func phasesMapToRequirements() {
        #expect(status(.checking).onboardingRequirement == .unknown)
        #expect(status(.needsDownload).onboardingRequirement == .missing)
        #expect(status(.failed(.sileroVAD, .loadFailed("x"))).onboardingRequirement == .missing)
        #expect(status(.downloading).onboardingRequirement == .inProgress)
        #expect(status(.waiting(for: .unmeteredNetwork)).onboardingRequirement == .inProgress)
        #expect(status(.waiting(for: .connection)).onboardingRequirement == .inProgress)
        #expect(status(.preparing).onboardingRequirement == .inProgress)
        #expect(status(.ready).onboardingRequirement == .satisfied)
    }

    /// A fresh install through the real manager on fixture models: unknown
    /// until the store is read, under way while downloading, done once
    /// ready, and missing again after the user deletes a required model.
    @Test func followsAFreshInstallAndADeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "blau-onboarding-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ModelFixtures.manifest(bytesPerFile: 4_096, ids: [.sileroVAD, .parakeetRealtimeEOU])
        let manager = ModelManager(
            manifest: manifest,
            store: ModelStore(root: root),
            transport: ModelFixtures.Transport(manifest: manifest, chunkCount: 2, delayPerChunk: .zero),
            networkMonitor: StaticNetworkMonitor(.unmetered),
            warmer: ModelFixtures.Warmer(duration: .zero),
            preferencesStore: InMemoryModelPreferencesStore()
        )
        #expect(manager.setupStatus.onboardingRequirement == .unknown)

        await manager.start()
        #expect(manager.setupStatus.onboardingRequirement == .inProgress)

        await manager.waitUntilIdle()
        #expect(manager.isReady)
        #expect(manager.setupStatus.onboardingRequirement == .satisfied)

        await manager.delete(.sileroVAD)
        #expect(manager.setupStatus.onboardingRequirement == .missing)
    }
}
