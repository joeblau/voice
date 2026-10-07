import BlauAudio
import BlauTelemetry
import BlauVoiceID
import Foundation
import Testing

/// Runs the speaker-embedding cases against the real FluidAudio models on
/// this Mac. Off by default (downloads models):
///
///     BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModelSpeakerBenchmarkTests
@Suite(
    "Real-model speaker embedding benchmarks",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .serialized
)
struct RealModelSpeakerBenchmarkTests {
    static let audio = AudioFixtureStore.standard(
        recordingURL: ProcessInfo.processInfo.environment["BLAU_BENCH_AUDIO"].map { URL(filePath: $0) })

    @Test func weSpeaker() async throws {
        try await Self.runAndReport(SpeakerEmbeddingBenchmarkCase.weSpeaker(audio: Self.audio))
    }

    @Test func camPlusPlus() async throws {
        try await Self.runAndReport(SpeakerEmbeddingBenchmarkCase.camPlusPlus(audio: Self.audio))
    }

    static func runAndReport(_ benchmark: any BenchmarkCase) async throws {
        let result = await BenchmarkRunner().run(benchmark)
        #if DEBUG
            let build = "Debug"
        #else
            let build = "Release"
        #endif
        let report = BenchmarkReport(
            device: .current, startedAt: result.startedAt, results: [result], buildConfiguration: build)
        print(report.markdownSummary)
        if let directory = ProcessInfo.processInfo.environment["BLAU_BENCH_OUTPUT"] {
            let url = URL(filePath: directory).appendingPathComponent("\(result.id).json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.jsonData().write(to: url)
        }
        #expect(result.outcome == .completed, "\(result.outcome)")
    }
}
