import BlauTelemetry
import Foundation
import Testing

@Suite("Benchmark report")
struct BenchmarkReportTests {
    static func result(
        _ id: String,
        title: String? = nil,
        outcome: BenchmarkResult.Outcome = .completed,
        metrics: [BenchmarkMetric] = [],
        latencies: [String: LatencySummary] = [:]
    ) -> BenchmarkResult {
        BenchmarkResult(
            id: id, title: title ?? id, outcome: outcome, metrics: metrics, latencies: latencies, notes: [],
            startedAt: Date(timeIntervalSince1970: 1_791_000_000), wallTimeSeconds: 1,
            thermalStateAtStart: .nominal, thermalStateAtEnd: .fair)
    }

    static let window = LatencySummary(milliseconds: [40, 50, 60, 70, 80])!

    static let iPhone16Pro = BenchmarkReport(
        device: .fixture(identifier: "iPhone17,1"),
        startedAt: Date(timeIntervalSince1970: 1_791_000_000),
        results: [
            result(
                "asr.eou.320ms", title: "Parakeet EOU 120M, 320ms chunks",
                metrics: [
                    BenchmarkMetric(key: "load", value: 812, unit: .milliseconds),
                    BenchmarkMetric(key: "rtfx", value: 18.2, unit: .realTimeFactor),
                ],
                latencies: ["window": window]),
            result("memory.embeddinggemma", outcome: .skipped(reason: "no model")),
        ],
        buildConfiguration: "Release"
    )

    static let iPhone15Pro = BenchmarkReport(
        device: .fixture(identifier: "iPhone16,1"),
        startedAt: Date(timeIntervalSince1970: 1_791_100_000),
        results: [
            result(
                "asr.eou.320ms", title: "Parakeet EOU 120M, 320ms chunks",
                metrics: [BenchmarkMetric(key: "rtfx", value: 9.5, unit: .realTimeFactor)]),
            result("topics.label", outcome: .failed(message: "a | b")),
        ],
        buildConfiguration: "Release"
    )

    @Test func roundTripsThroughJSON() throws {
        let data = try Self.iPhone16Pro.jsonData()
        let decoded = try BenchmarkReport.decode(from: data)
        #expect(decoded == Self.iPhone16Pro)
        #expect(decoded.schemaVersion == BenchmarkReport.currentSchemaVersion)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"modelIdentifier\" : \"iPhone17,1\""))
    }

    @Test func mergeReplacesAResultForTheSameCase() {
        var report = Self.iPhone16Pro
        report.merge(Self.result("asr.eou.320ms", outcome: .failed(message: "again")))
        report.merge(Self.result("new.case"))
        #expect(report.results.map(\.id) == ["asr.eou.320ms", "memory.embeddinggemma", "new.case"])
        #expect(report.result("asr.eou.320ms")?.outcome == .failed(message: "again"))
    }

    @Test func summaryListsEveryCaseWithItsNumbers() {
        let summary = Self.iPhone16Pro.markdownSummary
        #expect(summary.contains("### iPhone 16 Pro (A18 Pro)"))
        #expect(summary.contains("Release"))
        #expect(
            summary.contains(
                "| Parakeet EOU 120M, 320ms chunks | ok | load 812 ms · rtfx 18.2× · window p50 60.0 ms / p95 78.0 ms (n=5) |"
            ))
        #expect(summary.contains("| memory.embeddinggemma | skipped: no model | – |"))
    }

    @Test func comparisonTableAlignsDevicesByMetric() {
        let table = BenchmarkReport.comparisonTable([Self.iPhone16Pro, Self.iPhone15Pro])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines[0] == "| Benchmark | Metric | iPhone 16 Pro (A18 Pro) | iPhone 15 Pro (A17 Pro) |")
        #expect(lines[1] == "| --- | --- | --- | --- |")
        #expect(lines.contains("| Parakeet EOU 120M, 320ms chunks | `load` | 812 ms | – |"))
        #expect(lines.contains("|  | `rtfx` | 18.2× | 9.50× |"))
        #expect(lines.contains("|  | `window.p50` | 60.0 ms | – |"))
        #expect(lines.contains("|  | `window.p95` | 78.0 ms | – |"))
        // A case that one device skipped or failed shows why; pipes are escaped.
        #expect(lines.contains("| topics.label | `outcome` | – | failed: a \\| b |"))
        #expect(lines.contains("| memory.embeddinggemma | `outcome` | skipped: no model | – |"))
    }

    @Test func emptyComparisonIsEmpty() {
        #expect(BenchmarkReport.comparisonTable([]).isEmpty)
    }

    @Test func fileNameSortsByDateAndNamesTheDevice() {
        #expect(Self.iPhone16Pro.suggestedFileName == "2026-10-03T04-00-00Z-iPhone17,1.json")
    }
}
