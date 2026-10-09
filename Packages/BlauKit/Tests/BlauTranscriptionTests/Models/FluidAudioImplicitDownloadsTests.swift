import BlauTranscription
import FluidAudio
import Foundation
import Testing

/// The debug benchmark screen and background probe fetch their models with
/// FluidAudio's own loaders, after the app has turned FluidAudio's offline
/// mode on at launch (#22, #99). These tests change the process-wide
/// `ModelHub.offlineMode`, so they run one at a time and put it back.
@Suite("FluidAudio implicit downloads", .serialized)
struct FluidAudioImplicitDownloadsTests {
    /// Runs `body` and restores `ModelHub.offlineMode` afterwards.
    private func preservingOfflineMode(_ body: () async throws -> Void) async rethrows {
        let original = ModelHub.offlineMode
        defer { ModelHub.offlineMode = original }
        try await body()
    }

    @Test func offlineModeStopsTheBenchmarkModelPathAtPrepare() async throws {
        // What the screen hit before the scope existed: with no models on
        // disk, the EOU case's `prepare` throws before touching the network.
        try await preservingOfflineMode {
            FluidAudioModels.disableImplicitDownloads()
            let root = FileManager.default.temporaryDirectory.appending(
                path: "blau-implicit-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let processor = ParakeetEouChunkProcessor(chunkSize: .ms320, modelsRoot: root)

            await #expect {
                try await processor.prepare { _ in }
            } throws: { error in
                if case DownloadError.networkDisabled = error { true } else { false }
            }
        }
    }

    @Test func aScopeAllowsDownloadsAndRestoresOfflineMode() async throws {
        await preservingOfflineMode {
            FluidAudioModels.disableImplicitDownloads()
            #expect(!FluidAudioModels.implicitDownloadsAllowed)

            await FluidAudioModels.withImplicitDownloads {
                #expect(FluidAudioModels.implicitDownloadsAllowed)
                #expect(ModelHub.offlineMode == false)
            }

            #expect(!FluidAudioModels.implicitDownloadsAllowed)
            #expect(ModelHub.offlineMode == true)
        }
    }

    @Test func aThrowingScopeStillRestoresOfflineMode() async throws {
        struct Failure: Error {}
        await preservingOfflineMode {
            FluidAudioModels.disableImplicitDownloads()
            await #expect(throws: Failure.self) {
                try await FluidAudioModels.withImplicitDownloads { () async throws(Failure) in
                    throw Failure()
                }
            }
            #expect(ModelHub.offlineMode == true)
        }
    }

    @Test func overlappingScopesRestoreWhenTheLastOneEnds() async throws {
        await preservingOfflineMode {
            FluidAudioModels.disableImplicitDownloads()
            await FluidAudioModels.withImplicitDownloads {
                await FluidAudioModels.withImplicitDownloads {
                    #expect(FluidAudioModels.implicitDownloadsAllowed)
                }
                // The outer scope is still open.
                #expect(FluidAudioModels.implicitDownloadsAllowed)
            }
            #expect(!FluidAudioModels.implicitDownloadsAllowed)
        }
    }

    @Test func disablingInsideAScopeTakesEffectWhenItEnds() async throws {
        await preservingOfflineMode {
            ModelHub.offlineMode = false
            await FluidAudioModels.withImplicitDownloads {
                FluidAudioModels.disableImplicitDownloads()
                // The scope keeps downloads allowed while it is open.
                #expect(FluidAudioModels.implicitDownloadsAllowed)
            }
            #expect(ModelHub.offlineMode == true)
        }
    }

    @Test func aScopeLeavesOnlineModeOnline() async throws {
        await preservingOfflineMode {
            ModelHub.offlineMode = false
            await FluidAudioModels.withImplicitDownloads {}
            #expect(ModelHub.offlineMode == false)
        }
    }
}
