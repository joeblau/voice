import BlauAudio
import BlauTelemetry
import BlauTranscription
import Foundation
import Testing

/// Runs the ASR benchmark cases against the real FluidAudio models on this
/// Mac. Off by default: it downloads several hundred megabytes of models.
///
///     BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModelAsrBenchmarkTests
///
/// Set `BLAU_BENCH_OUTPUT=<dir>` to also write each report as JSON. These
/// are Mac reference numbers only; the iPhone table comes from the
/// `BlauBenchmarks` XCTest target (see docs/benchmarks.md).
@Suite(
    "Real-model ASR benchmarks",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .serialized
)
struct RealModelAsrBenchmarkTests {
    static let audio = AudioFixtureStore.standard(
        recordingURL: ProcessInfo.processInfo.environment["BLAU_BENCH_AUDIO"].map { URL(filePath: $0) })

    @Test(arguments: ParakeetEouChunkSize.allCases)
    func parakeetEou(chunkSize: ParakeetEouChunkSize) async throws {
        try await Self.runAndReport(StreamingAsrBenchmark.parakeetEou(chunkSize, audio: Self.audio))
    }

    @Test func parakeetTdtV3() async throws {
        try await Self.runAndReport(OfflineAsrBenchmark.parakeetTdtV3(audio: Self.audio))
    }

    static func runAndReport(_ benchmark: any BenchmarkCase) async throws {
        let result = await BenchmarkRunner().run(benchmark)
        let report = BenchmarkReport(
            device: .current, startedAt: result.startedAt, results: [result], buildConfiguration: buildConfiguration)
        print(report.markdownSummary)
        if let directory = ProcessInfo.processInfo.environment["BLAU_BENCH_OUTPUT"] {
            let url = URL(filePath: directory).appendingPathComponent("\(result.id).json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.jsonData().write(to: url)
        }
        #expect(result.outcome == .completed, "\(result.outcome)")
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }
}
