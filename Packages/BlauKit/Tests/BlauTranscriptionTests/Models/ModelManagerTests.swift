import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// Everything a `ModelManager` test needs, with fakes for the network,
/// Core ML and preferences.
@MainActor
private struct Harness {
    let manifest = ModelFixtures.manifest(bytesPerFile: 16_384)
    let store: ModelStore
    let transport: ScriptedTransport
    let network: StaticNetworkMonitor
    let warmer = RecordingWarmer()
    let preferences: InMemoryModelPreferencesStore
    let signposts = RecordingSignpostBackend()

    init(root: URL, network: NetworkStatus = .unmetered, preferences: ModelPreferences = .default) {
        store = ModelStore(root: root)
        transport = ScriptedTransport(manifest: manifest)
        self.network = StaticNetworkMonitor(network)
        self.preferences = InMemoryModelPreferencesStore(preferences)
    }

    func makeManager(
        transport: (any ModelTransport)? = nil, network: (any NetworkMonitor)? = nil, systemVersion: String = "OS 1"
    ) -> ModelManager {
        ModelManager(
            manifest: manifest,
            store: store,
            transport: transport ?? self.transport,
            networkMonitor: network ?? self.network,
            warmer: warmer,
            preferencesStore: preferences,
            clock: ManualClock(),
            retryPolicy: .immediate,
            systemVersion: systemVersion,
            signposter: Signposter(category: .asr, backend: signposts)
        )
    }
}

@MainActor
@Suite("Model manager")
struct ModelManagerTests {
    /// Acceptance criterion: a fresh install downloads and loads every
    /// model, with progress visible along the way.
    @Test func freshInstallDownloadsAndWarmsUpEveryModelWithProgress() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let gate = Gate()
        harness.transport.script(
            "parakeetRealtimeEOU/parakeetRealtimeEOU.mlmodelc/weights/weight.bin", .pause(afterBytes: 8000, gate: gate))
        let manager = harness.makeManager()
        #expect(manager.setupStatus.phase == .checking)
        #expect(!manager.hasCheckedInstalledModels)

        await manager.start()
        #expect(manager.hasCheckedInstalledModels)
        #expect(manager.isExcludedFromBackup == true)

        // Mid-download, the state and the onboarding summary show progress.
        await waitUntil("EOU model is part-way") {
            if case .downloading(let bytes, _) = manager.state(of: .parakeetRealtimeEOU) { bytes > 0 } else { false }
        }
        let descriptor = try #require(harness.manifest[.parakeetRealtimeEOU])
        let fraction = try #require(manager.state(of: .parakeetRealtimeEOU).downloadFraction)
        #expect(fraction > 0 && fraction < 1)
        #expect(manager.state(of: .sileroVAD) == .ready)
        let status = manager.setupStatus
        #expect(status.phase == .downloading)
        #expect(status.bytesReceived > 0 && status.bytesReceived < status.totalBytes)
        #expect(status.totalBytes == harness.manifest.required.reduce(0) { $0 + $1.totalBytes })
        #expect(!manager.isReady)
        #expect(manager.directory(for: .parakeetRealtimeEOU) == nil)

        gate.open()
        await manager.waitUntilIdle()

        for id in ModelID.allCases {
            #expect(manager.state(of: id) == .ready, "\(id)")
        }
        #expect(manager.isReady)
        #expect(manager.setupStatus.phase == .ready)
        #expect(manager.setupStatus.fractionCompleted == 1)
        #expect(
            harness.warmer.warmed == [
                .sileroVAD, .speakerEmbedding, .parakeetRealtimeEOU, .parakeetTDTv3, .textEmbedding,
                .parakeetRealtimeEOU1280, .languageID,
            ])
        #expect(manager.directory(for: .parakeetRealtimeEOU) == harness.store.directory(for: descriptor))
        #expect(manager.diskUsage[.parakeetRealtimeEOU, default: 0] >= descriptor.totalBytes)
        #expect(manager.totalDiskUsage >= harness.manifest.models.reduce(0) { $0 + $1.totalBytes })
        #expect(Set(manager.warmUpDurations.keys) == Set(ModelID.allCases))
    }

    /// Acceptance criterion: after the first download, launching offline
    /// works with no network and no re-download.
    @Test func offlineLaunchAfterTheFirstDownloadIsReady() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let first = harness.makeManager()
        await first.start()
        await first.waitUntilIdle()
        #expect(first.isReady)
        let callsAfterInstall = harness.transport.calls.count
        let warmUpsAfterInstall = harness.warmer.warmed.count

        // Next launch: offline, and any network use would fail.
        harness.transport.setDefault(.fail(.offline))
        let offline = StaticNetworkMonitor(.offline)
        let second = harness.makeManager(network: offline)
        await second.start()
        await second.waitUntilIdle()

        for id in ModelID.allCases {
            #expect(second.state(of: id) == .ready, "\(id)")
        }
        #expect(second.isReady)
        #expect(harness.transport.calls.count == callsAfterInstall, "An offline launch must not touch the network")
        #expect(harness.warmer.warmed.count == warmUpsAfterInstall, "Already warmed up on this OS version")
        #expect(second.directory(for: .sileroVAD) != nil)
    }

    /// An OS update drops Core ML's compiled cache, so models warm up again
    /// (still offline).
    @Test func anOSUpdateWarmsModelsUpAgainOffline() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let first = harness.makeManager(systemVersion: "OS 1")
        await first.start()
        await first.waitUntilIdle()
        harness.transport.setDefault(.fail(.offline))
        let calls = harness.transport.calls.count

        let updated = harness.makeManager(network: StaticNetworkMonitor(.offline), systemVersion: "OS 2")
        await updated.start()
        #expect(updated.state(of: .sileroVAD) == .preparing || updated.state(of: .sileroVAD) == .ready)
        await updated.waitUntilIdle()

        #expect(updated.isReady)
        #expect(harness.warmer.warmed.count == 2 * ModelID.allCases.count)
        #expect(harness.transport.calls.count == calls)
    }

    @Test func waitsForWiFiOnCellularByDefault() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, network: .cellular)
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(harness.transport.calls.isEmpty)
        for id in ModelID.allCases {
            #expect(manager.state(of: id) == .waiting(for: .unmeteredNetwork), "\(id)")
        }
        #expect(manager.setupStatus.phase == .waiting(for: .unmeteredNetwork))

        harness.network.set(.unmetered)
        await waitUntil("downloads resume on Wi-Fi") { manager.isReady && manager.state(of: .parakeetTDTv3) == .ready }
        await manager.waitUntilIdle()
        for id in ModelID.allCases {
            #expect(manager.state(of: id) == .ready, "\(id)")
        }
        #expect(harness.transport.calls.allSatisfy { !$0.allowsExpensiveNetwork })
    }

    @Test func lowDataModeCountsAsMetered() async throws {
        let temp = try TemporaryDirectory()
        let constrained = NetworkStatus(isReachable: true, isExpensive: false, isConstrained: true)
        let harness = Harness(root: temp.url, network: constrained)
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .sileroVAD) == .waiting(for: .unmeteredNetwork))
        #expect(harness.transport.calls.isEmpty)
    }

    @Test func downloadsOverCellularWhenThePolicyAllows() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, network: .cellular)
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()
        #expect(manager.state(of: .sileroVAD) == .waiting(for: .unmeteredNetwork))

        manager.preferences.downloadPolicy = .anyNetwork
        await waitUntil("downloads start on cellular") { manager.isReady }
        await manager.waitUntilIdle()

        #expect(harness.preferences.load().downloadPolicy == .anyNetwork, "The choice is saved")
        #expect(harness.transport.calls.allSatisfy { $0.allowsExpensiveNetwork })
    }

    @Test func cellularCanBeAllowedForThisLaunchOnly() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, network: .cellular)
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()

        manager.allowExpensiveNetworkThisSession()
        await waitUntil("downloads start on cellular") { manager.isReady }
        await manager.waitUntilIdle()

        #expect(harness.preferences.load().downloadPolicy == .wifiOnly, "The saved preference is unchanged")
    }

    /// Turning on Wi-Fi only during a cellular download stops it right
    /// away instead of letting it finish over cellular. The partial file is
    /// kept, so the download picks up from there on Wi-Fi.
    @Test func turningOnWiFiOnlyStopsACellularDownload() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(
            root: temp.url, network: .cellular,
            preferences: ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: true))
        let weights = "parakeetRealtimeEOU/parakeetRealtimeEOU.mlmodelc/weights/weight.bin"
        let gate = Gate()
        harness.transport.script(weights, .pause(afterBytes: 8000, gate: gate))
        let manager = harness.makeManager()
        await manager.start()
        await waitUntil("EOU is downloading over cellular") {
            if case .downloading(let bytes, _) = manager.state(of: .parakeetRealtimeEOU) {
                bytes > 0 && harness.transport.calls.contains { $0.path == weights }
            } else {
                false
            }
        }

        manager.preferences.downloadPolicy = .wifiOnly
        await waitUntil("the download stops") {
            manager.state(of: .parakeetRealtimeEOU) == .waiting(for: .unmeteredNetwork)
        }
        // Even if the transfer could continue now, it doesn't.
        gate.open()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .parakeetRealtimeEOU) == .waiting(for: .unmeteredNetwork))
        #expect(manager.state(of: .parakeetTDTv3) == .waiting(for: .unmeteredNetwork))
        #expect(manager.setupStatus.phase == .waiting(for: .unmeteredNetwork))
        #expect(!manager.isReady)
        #expect(harness.store.diskUsage(of: .parakeetRealtimeEOU) > 0, "The partial download is kept")
        #expect(harness.preferences.load().downloadPolicy == .wifiOnly)

        harness.network.set(.unmetered)
        await waitUntil("the download resumes on Wi-Fi") {
            manager.isReady && manager.state(of: .parakeetTDTv3) == .ready
        }
        await manager.waitUntilIdle()
        let weightCalls = harness.transport.calls.filter { $0.path == weights }
        #expect(weightCalls.count == 2)
        #expect(weightCalls.last == TransportCall(path: weights, offset: 8000, allowsExpensiveNetwork: false))
    }

    /// The same switch on Wi-Fi leaves the download alone.
    @Test func turningOnWiFiOnlyOnWiFiKeepsDownloading() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(
            root: temp.url, preferences: ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: false))
        let weights = "parakeetRealtimeEOU/parakeetRealtimeEOU.mlmodelc/weights/weight.bin"
        let gate = Gate()
        harness.transport.script(weights, .pause(afterBytes: 8000, gate: gate))
        let manager = harness.makeManager()
        await manager.start()
        await waitUntil("EOU is downloading") { harness.transport.calls.contains { $0.path == weights } }

        manager.preferences.downloadPolicy = .wifiOnly
        gate.open()
        await manager.waitUntilIdle()

        #expect(manager.isReady)
        #expect(harness.transport.calls.filter { $0.path == weights }.count == 1, "Never restarted")
    }

    /// Choosing Wi-Fi only after "Download Using Cellular Data" ends that
    /// override: the explicit choice wins.
    @Test func choosingWiFiOnlyEndsTheCellularOverrideForThisLaunch() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, network: .cellular)
        let weights = "parakeetRealtimeEOU/parakeetRealtimeEOU.mlmodelc/weights/weight.bin"
        let gate = Gate()
        harness.transport.script(weights, .pause(afterBytes: 8000, gate: gate))
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()
        manager.allowExpensiveNetworkThisSession()
        await waitUntil("EOU is downloading over cellular") {
            harness.transport.calls.contains { $0.path == weights }
        }

        manager.preferences.downloadPolicy = .anyNetwork
        #expect(manager.allowsExpensiveNetworkThisSession)
        #expect(manager.state(of: .parakeetRealtimeEOU) != .waiting(for: .unmeteredNetwork))
        manager.preferences.downloadPolicy = .wifiOnly
        #expect(!manager.allowsExpensiveNetworkThisSession)
        await waitUntil("the download stops") {
            manager.state(of: .parakeetRealtimeEOU) == .waiting(for: .unmeteredNetwork)
        }
        gate.open()
        await manager.waitUntilIdle()
        #expect(manager.state(of: .parakeetRealtimeEOU) == .waiting(for: .unmeteredNetwork))
    }

    @Test func waitsWhileOfflineAndResumesWhenConnected() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, network: .offline)
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .sileroVAD) == .waiting(for: .connection))
        #expect(manager.setupStatus.phase == .waiting(for: .connection))
        #expect(harness.transport.calls.isEmpty)

        harness.network.set(.unmetered)
        await waitUntil("downloads resume when connected") { manager.isReady }
        await manager.waitUntilIdle()
    }

    /// The monitor said online but the transfer found no connection: wait
    /// for the next network change instead of retrying in a loop.
    @Test func aStaleOnlineStatusDoesNotSpin() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        harness.transport.setDefault(.fail(.offline))
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .sileroVAD) == .waiting(for: .connection))
        let calls = harness.transport.calls.count
        #expect(calls == ModelID.allCases.count, "One attempt per model, then wait")

        harness.transport.setDefault(.serve)
        harness.network.set(NetworkStatus(isReachable: true, isExpensive: false, isConstrained: false))
        harness.network.set(.offline)
        harness.network.set(.unmetered)
        await waitUntil("retries after the network changes") { manager.isReady }
        await manager.waitUntilIdle()
    }

    @Test func aTransportRefusingCellularWaitsForWiFi() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        // The monitor hasn't noticed yet, but the system refused the
        // expensive path.
        harness.transport.setDefault(.fail(.expensiveNetworkDisallowed))
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .sileroVAD) == .waiting(for: .unmeteredNetwork))
    }

    @Test func failuresAreReportedAndCanBeRetried() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        harness.transport.script("speakerEmbedding/vocab.json", .fail(.httpStatus(404)))
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        let failure = ModelFailure.download(.server(status: 404, path: "vocab.json"))
        #expect(manager.state(of: .speakerEmbedding) == .failed(failure))
        #expect(manager.setupStatus.phase == .failed(.speakerEmbedding, failure))
        #expect(!failure.message.isEmpty)
        // Other models carry on.
        #expect(manager.state(of: .parakeetRealtimeEOU) == .ready)

        await manager.download(.speakerEmbedding)
        await manager.waitUntilIdle()
        #expect(manager.state(of: .speakerEmbedding) == .ready)
        #expect(manager.isReady)
    }

    @Test func optionalModelsWaitForTheUserWhenAutomaticDownloadIsOff() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, preferences: ModelPreferences(downloadsOptionalModels: false))
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.isReady)
        #expect(manager.state(of: .parakeetTDTv3) == .notDownloaded)
        #expect(!harness.transport.calls.contains { $0.path.hasPrefix("parakeetTDTv3/") })
        // The text embedding model isn't the high-accuracy second pass: it
        // downloads whatever that preference says.
        #expect(manager.state(of: .textEmbedding) == .ready)

        await manager.download(.parakeetTDTv3)
        await manager.waitUntilIdle()
        #expect(manager.state(of: .parakeetTDTv3) == .ready)
    }

    @Test func turningOnOptionalModelsQueuesThem() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url, preferences: ModelPreferences(downloadsOptionalModels: false))
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()

        manager.preferences.downloadsOptionalModels = true
        await waitUntil("optional model downloads") { manager.state(of: .parakeetTDTv3) == .ready }
        // The other optional models may still be downloading or warming up;
        // let them finish before the temporary directory goes away.
        await manager.waitUntilIdle()
        #expect(harness.preferences.load().downloadsOptionalModels)
    }

    @Test func turningOffOptionalModelsStopsTheirDownload() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let gate = Gate()
        harness.transport.script(
            "parakeetTDTv3/parakeetTDTv3.mlmodelc/weights/weight.bin", .pause(afterBytes: 1000, gate: gate))
        let manager = harness.makeManager()
        await manager.start()
        await waitUntil("optional model is downloading") {
            if case .downloading = manager.state(of: .parakeetTDTv3) { true } else { false }
        }

        manager.preferences.downloadsOptionalModels = false
        await waitUntil("download stopped") { manager.state(of: .parakeetTDTv3) == .notDownloaded }
        await manager.waitUntilIdle()
        #expect(manager.state(of: .parakeetTDTv3) == .notDownloaded)
        #expect(manager.isReady)
    }

    @Test func deleteRemovesFilesAndCanDownloadAgain() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()
        #expect(manager.diskUsage[.parakeetTDTv3, default: 0] > 0)

        await manager.delete(.parakeetTDTv3)

        #expect(manager.state(of: .parakeetTDTv3) == .notDownloaded)
        #expect(manager.diskUsage[.parakeetTDTv3] == 0)
        #expect(manager.directory(for: .parakeetTDTv3) == nil)
        #expect(harness.store.installation(of: try #require(harness.manifest[.parakeetTDTv3])) == nil)
        #expect(manager.isReady, "Deleting an optional model keeps Blau usable")

        await manager.download(.parakeetTDTv3)
        await manager.waitUntilIdle()
        #expect(manager.state(of: .parakeetTDTv3) == .ready)
    }

    @Test func deletingARequiredModelNeedsADownloadBeforeBlauIsReady() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let manager = harness.makeManager()
        await manager.start()
        await manager.waitUntilIdle()

        await manager.delete(.sileroVAD)

        #expect(!manager.isReady)
        #expect(manager.setupStatus.phase == .needsDownload)

        // The next launch downloads it again by itself.
        let relaunched = harness.makeManager()
        await relaunched.start()
        await relaunched.waitUntilIdle()
        #expect(relaunched.isReady)
    }

    @Test func deleteCancelsAnInFlightDownload() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let gate = Gate()
        harness.transport.script("sileroVAD/sileroVAD.mlmodelc/weights/weight.bin", .pause(afterBytes: 500, gate: gate))
        let manager = harness.makeManager()
        await manager.start()
        await waitUntil("downloading") {
            if case .downloading = manager.state(of: .sileroVAD) { true } else { false }
        }

        // Deleting cancels the paused transfer; the gate never opens.
        await manager.delete(.sileroVAD)

        #expect(manager.state(of: .sileroVAD) == .notDownloaded)
        #expect(harness.store.diskUsage(of: .sileroVAD) == 0)
        await manager.waitUntilIdle()
        // Work moved on to the other models.
        #expect(manager.state(of: .parakeetRealtimeEOU) == .ready)
    }

    /// A model that won't load and whose files are damaged is downloaded
    /// again.
    @Test func aDamagedModelIsRepairedOnce() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let first = harness.makeManager()
        await first.start()
        await first.waitUntilIdle()

        // Damage a file without changing its size, then make the next
        // warm-up (after an "OS update") fail once.
        let descriptor = try #require(harness.manifest[.speakerEmbedding])
        let file = try #require(descriptor.files.first { $0.path.hasSuffix("weight.bin") })
        let url = harness.store.directory(for: descriptor).appending(path: file.path)
        var bytes = try Data(contentsOf: url)
        bytes[10] ^= 0xFF
        try bytes.write(to: url)
        let failingOnce = FailingOnceWarmer(id: .speakerEmbedding)
        let manager = ModelManager(
            manifest: harness.manifest, store: harness.store, transport: harness.transport,
            networkMonitor: harness.network, warmer: failingOnce, preferencesStore: harness.preferences,
            clock: ManualClock(), retryPolicy: .immediate, systemVersion: "OS 2")

        await manager.start()
        await manager.waitUntilIdle()

        #expect(manager.state(of: .speakerEmbedding) == .ready)
        #expect(harness.store.corruptFiles(in: descriptor).isEmpty)
    }

    /// Intact files that still won't load mean the model can't run here.
    @Test func anIntactModelThatWontLoadFails() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        harness.warmer.fail(.parakeetTDTv3)
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        guard case .failed(.loadFailed) = manager.state(of: .parakeetTDTv3) else {
            Issue.record("Expected a load failure, got \(manager.state(of: .parakeetTDTv3))")
            return
        }
        #expect(manager.isReady, "Optional model failures don't block Blau")
    }

    @Test func notEnoughSpaceFailsWithTheAmountNeeded() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let manager = ModelManager(
            manifest: harness.manifest, store: ModelStore(root: temp.url, availableCapacity: { _ in 1_000 }),
            transport: harness.transport, networkMonitor: harness.network, warmer: harness.warmer,
            preferencesStore: harness.preferences, clock: ManualClock(), retryPolicy: .immediate)

        await manager.start()
        await manager.waitUntilIdle()

        let descriptor = try #require(harness.manifest[.sileroVAD])
        #expect(
            manager.state(of: .sileroVAD)
                == .failed(.download(.insufficientStorage(required: descriptor.totalBytes, available: 1_000))))
        #expect(harness.transport.calls.isEmpty)
    }

    @Test func startDropsStaleRevisions() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let current = try #require(harness.manifest[.sileroVAD])
        let old = ModelDescriptor(
            id: .sileroVAD, repository: current.repository, revision: String(repeating: "e", count: 40),
            remoteDirectory: "", files: current.files)
        try installFixture(old, in: harness.store)
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        #expect(!FileManager.default.fileExists(atPath: harness.store.directory(for: old).path(percentEncoded: false)))
        #expect(manager.state(of: .sileroVAD) == .ready)
    }

    @Test func emitsDownloadAndWarmUpSignposts() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let manager = harness.makeManager()

        await manager.start()
        await manager.waitUntilIdle()

        let completed = harness.signposts.completedIntervals
        #expect(completed.filter { $0 == "model.download" }.count == ModelID.allCases.count)
        #expect(completed.filter { $0 == "model.warmUp" }.count == ModelID.allCases.count)
        #expect(harness.signposts.openIntervals.isEmpty)
    }

    @Test func startIsIdempotent() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let manager = harness.makeManager()
        await manager.start()
        await manager.start()
        await manager.waitUntilIdle()
        #expect(harness.transport.calls.count == harness.manifest.models.reduce(0) { $0 + $1.files.count })
    }

    @Test func preferencesAreLoadedFromTheStore() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(
            root: temp.url, preferences: ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: false))
        let manager = harness.makeManager()
        #expect(manager.preferences == ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: false))
    }

    @Test func fixtureTransportAndWarmerRunTheWholePipeline() async throws {
        let temp = try TemporaryDirectory()
        let manifest = ModelFixtures.manifest(bytesPerFile: 4096)
        let manager = ModelManager(
            manifest: manifest, store: ModelStore(root: temp.url),
            transport: ModelFixtures.Transport(manifest: manifest, chunkCount: 4),
            networkMonitor: StaticNetworkMonitor(), warmer: ModelFixtures.Warmer(),
            preferencesStore: InMemoryModelPreferencesStore(), clock: ManualClock())
        await manager.start()
        await manager.waitUntilIdle()
        #expect(manager.isReady)
        #expect(manager.state(of: .parakeetTDTv3) == .ready)
    }

    /// #182: a view that only reads `isReady` (the main screen around the
    /// setup card) isn't invalidated by every progress report of a
    /// download, only when the models become ready or stop being ready.
    @Test func isReadyChangesOnlyWhenReadinessFlips() async throws {
        let temp = try TemporaryDirectory()
        let harness = Harness(root: temp.url)
        let gate = Gate()
        harness.transport.script(
            "parakeetRealtimeEOU/parakeetRealtimeEOU.mlmodelc/weights/weight.bin", .pause(afterBytes: 8000, gate: gate))
        let manager = harness.makeManager()
        #expect(!manager.isReady)

        let readinessChanges = ObservationCount { _ = manager.isReady }
        let stateChanges = ObservationCount { _ = manager.states }
        await manager.start()
        await waitUntil("EOU model is part-way") {
            if case .downloading(let bytes, _) = manager.state(of: .parakeetRealtimeEOU) { bytes > 0 } else { false }
        }
        #expect(manager.state(of: .sileroVAD) == .ready, "A whole model downloaded and warmed up meanwhile")
        #expect(stateChanges.count > 5, "Progress was reported")
        #expect(readinessChanges.count == 0, "Progress didn't touch isReady")

        gate.open()
        await manager.waitUntilIdle()
        #expect(manager.isReady)
        #expect(readinessChanges.count == 1)

        // Deleting a required model makes it not ready again: one more change
        // (once the observation has re-armed).
        for _ in 0..<5 { await Task.yield() }
        await manager.delete(.sileroVAD)
        #expect(!manager.isReady)
        #expect(readinessChanges.count == 2)
    }
}

/// Counts the writes to whatever `read` reads, as SwiftUI would see them.
///
/// `withObservationTracking` fires once per registration, synchronously in
/// the property's `willSet`, so each change is counted there and the
/// observation re-armed right after the write. The observed objects are
/// main-actor isolated, so their writes (and `onChange`) run on the main
/// actor.
@MainActor
private final class ObservationCount {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
            }
            Task { @MainActor in self?.track() }
        }
    }
}

/// Fails the first warm-up of one model.
private final class FailingOnceWarmer: ModelWarmer {
    private let id: ModelID
    private let failed = Mutex(false)

    init(id: ModelID) { self.id = id }

    func warmUp(_ descriptor: ModelDescriptor, at directory: URL) async throws {
        guard descriptor.id == id else { return }
        let shouldFail = failed.withLock { failed in
            defer { failed = true }
            return !failed
        }
        if shouldFail { throw CocoaError(.fileReadCorruptFile) }
    }
}
