import BlauTelemetry
import BlauTopics
import Foundation
import Testing

/// Runs the topic-label case against the on-device Foundation Models model
/// of this Mac. Off by default (needs Apple Intelligence):
///
///     BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModelTopicLabelBenchmarkTests
@Suite(
    "Real-model topic label benchmark",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1")
)
struct RealModelTopicLabelBenchmarkTests {
    @Test func foundationModels() async throws {
        let result = await BenchmarkRunner().run(TopicLabelBenchmark(generator: FoundationModelsTopicLabeler()))
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
        // Skipped is fine on a Mac without Apple Intelligence; failing isn't.
        if case .failed(let message) = result.outcome {
            Issue.record("Topic label benchmark failed: \(message)")
        }
    }
}
