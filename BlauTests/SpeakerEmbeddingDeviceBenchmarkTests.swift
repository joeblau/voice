import BlauTranscription
import BlauVoiceID
import Foundation
import Testing

/// Times the speaker embedder on a real device with the WeSpeaker model the
/// app downloaded, for the iPhone rows in docs/benchmarks.md.
///
/// Opt-in with `BLAU_DEVICE_TESTS=1`. Launch Blau once on the device and let
/// it finish model setup first: the test reads the installed model from the
/// app's own store (Application Support/Blau/Models) and never downloads.
/// Run it with the device plugged in and the screen on, then copy the
/// printed tables (Xcode's test log) into docs/benchmarks.md.
@Suite(
    "Speaker embedding device benchmark",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .timeLimit(.minutes(10))
)
struct SpeakerEmbeddingDeviceBenchmarkTests {
    @Test func timesTheInstalledModel() async throws {
        let store = try ModelStore.applicationSupport()
        let descriptor = try #require(ModelManifest.pinned[.speakerEmbedding])
        guard store.installation(of: descriptor) != nil else {
            Issue.record("The speaker model isn't installed. Launch Blau and finish model setup, then run again.")
            return
        }
        let bundle = store.directory(for: descriptor).appending(path: WeSpeakerEmbedder.modelBundleName)
        let benchmark = SpeakerEmbeddingBenchmark(iterations: 100, warmUpIterations: 10)
        let scenarios = SpeakerEmbeddingBenchmark.Scenario.standard + [.enrollmentClip]
        for units in [SpeakerEmbeddingComputeUnits.cpuAndNeuralEngine, .cpuOnly] {
            let network = try await CoreMLSpeakerEmbeddingNetwork.load(contentsOf: bundle, computeUnits: units)
            let calls = try await benchmark.run(WeSpeakerEmbedder(network: network), scenarios: scenarios)
            let modelOnly = try await benchmark.run(network, scenarios: scenarios)
            print(
                """
                [voiceid] device benchmark, compute units \(units.rawValue)
                WeSpeakerEmbedder.embed:
                \(SpeakerEmbeddingBenchmark.markdownTable(calls))
                Model run only:
                \(SpeakerEmbeddingBenchmark.markdownTable(modelOnly))

                """)
            #expect(calls.count == scenarios.count)
        }
    }
}
