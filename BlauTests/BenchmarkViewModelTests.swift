#if DEBUG
    import BlauAudio
    import BlauTelemetry
    import BlauTranscription
    import Foundation
    import Synchronization
    import Testing

    @testable import Blau

    /// The debug benchmark screen after the app's launch-time offline mode
    /// (#22, #99).
    @MainActor
    @Suite("Benchmark screen")
    struct BenchmarkViewModelTests {
        /// Records whether FluidAudio's own downloads were allowed while it
        /// ran, the way the EOU, TDT and speaker cases' `prepare` needs them.
        final class DownloadCheckingCase: BenchmarkCase {
            let id = "test.implicit-downloads"
            let title = "Implicit downloads"
            let category = LogCategory.performance
            let allowedDuringRun = Mutex<Bool?>(nil)

            func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
                allowedDuringRun.withLock { $0 = FluidAudioModels.implicitDownloadsAllowed }
            }
        }

        @Test func theSuiteAllowsFluidAudioDownloadsAndThenRestoresOfflineMode() async throws {
            // What `SpeechModels.makeManager()` does on every live launch.
            FluidAudioModels.disableImplicitDownloads()
            #expect(!FluidAudioModels.implicitDownloadsAllowed)

            let benchmark = DownloadCheckingCase()
            let model = BenchmarkViewModel(
                audio: AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(1))),
                activity: BenchmarkActivity())
            model.entries = [.init(benchmark: benchmark)]

            model.runSelected()
            #expect(model.isRunning)
            let deadline = ContinuousClock.now + .seconds(30)
            while model.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            defer { for url in model.reportURLs { try? FileManager.default.removeItem(at: url) } }

            #expect(!model.isRunning)
            #expect(benchmark.allowedDuringRun.withLock { $0 } == true)
            #expect(!FluidAudioModels.implicitDownloadsAllowed, "Offline mode is back on after the run")
        }
    }
#endif
