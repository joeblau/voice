import BlauAudio
import BlauTelemetry
import Foundation
import XCTest

/// Base class for the on-device model benchmarks (#22).
///
/// Every test skips unless `BLAU_DEVICE_TESTS=1` (`make bench` sets it via
/// `TEST_RUNNER_BLAU_DEVICE_TESTS`), and skips on the simulator, which has
/// no Neural Engine, unless `BLAU_BENCH_ALLOW_SIMULATOR=1`. Each test runs
/// one `BenchmarkCase`, attaches its result to the `.xcresult` and adds it to
/// a cumulative per-device report (also attached). See docs/benchmarks.md.
class BenchmarkTestCase: XCTestCase {
    static let environment = ProcessInfo.processInfo.environment

    /// `Assets/` copied into this bundle: optional EmbeddingGemma model and
    /// `benchmark-speech.wav` recording (both gitignored).
    static var assetsDirectory: URL? {
        Bundle(for: BenchmarkTestCase.self).resourceURL?.appendingPathComponent("Assets", isDirectory: true)
    }

    /// Shared by every test in the run, so speech is synthesized once.
    static let audio = AudioFixtureStore.standard(
        recordingURL: assetsDirectory?.appendingPathComponent("benchmark-speech.wav"))

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            Self.environment["BLAU_DEVICE_TESTS"] == "1",
            "Model benchmarks download models and take minutes; run them with `make bench DEVICE=<udid>`")
        #if targetEnvironment(simulator)
            try XCTSkipUnless(
                Self.environment["BLAU_BENCH_ALLOW_SIMULATOR"] == "1",
                "The simulator has no Neural Engine; run the benchmarks on an iPhone")
        #endif
        continueAfterFailure = true
    }

    /// Runs `benchmark`, records it, and turns a skip into `XCTSkip` and a
    /// failure into a test failure.
    @discardableResult
    func measure(_ benchmark: any BenchmarkCase) async throws -> BenchmarkResult {
        let result = await BenchmarkRunner().run(benchmark)
        let report = await ReportCollector.shared.add(result)

        let single = BenchmarkReport(
            device: report.device, startedAt: result.startedAt, results: [result],
            buildConfiguration: report.buildConfiguration)
        print(single.markdownSummary)
        attach(try single.jsonData(), name: "\(result.id).json", type: "public.json")
        attach(try report.jsonData(), name: report.suggestedFileName, type: "public.json")
        attach(Data(report.markdownSummary.utf8), name: "summary.md", type: "public.plain-text")
        await ReportCollector.shared.write(report)

        switch result.outcome {
        case .completed:
            break
        case .skipped(let reason):
            throw XCTSkip(reason)
        case .failed(let message):
            XCTFail("\(benchmark.id) failed: \(message)")
        }
        return result
    }

    private func attach(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }
}

/// Accumulates every result of the run into one report for this device.
actor ReportCollector {
    static let shared = ReportCollector()

    private var report = BenchmarkReport(
        device: .current, startedAt: .now, results: [], buildConfiguration: BenchmarkTestCase.buildConfiguration)

    func add(_ result: BenchmarkResult) -> BenchmarkReport {
        report.merge(result)
        return report
    }

    /// Also keeps the report in the runner's temporary directory, for
    /// `xcrun devicectl device copy from` when attachments aren't handy.
    func write(_ report: BenchmarkReport) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlauBenchmarks")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? report.jsonData().write(to: directory.appendingPathComponent(report.suggestedFileName))
    }
}
