import Foundation

/// Every benchmark result from one run on one device, as written to JSON and
/// pasted into docs/benchmarks.md.
public struct BenchmarkReport: Codable, Hashable, Sendable {
    /// Bumped when the JSON layout changes incompatibly.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let device: BenchmarkDevice
    public let startedAt: Date
    /// `Debug` or `Release`. Debug builds run BlauKit and FluidAudio's Swift
    /// code unoptimized, so only Release numbers go in the results table.
    public var buildConfiguration: String?
    public private(set) var results: [BenchmarkResult]

    public init(
        device: BenchmarkDevice,
        startedAt: Date,
        results: [BenchmarkResult],
        buildConfiguration: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.device = device
        self.startedAt = startedAt
        self.results = results
        self.buildConfiguration = buildConfiguration
    }

    /// The result for case `id`, if it ran.
    public func result(_ id: String) -> BenchmarkResult? {
        results.last { $0.id == id }
    }

    /// Adds `result`, replacing an earlier result for the same case.
    public mutating func merge(_ result: BenchmarkResult) {
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            results[index] = result
        } else {
            results.append(result)
        }
    }

    // MARK: JSON

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> BenchmarkReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkReport.self, from: data)
    }

    /// A file name that sorts by date and names the device:
    /// `2026-10-07T14-03-11Z-iPhone17,1.json`.
    public var suggestedFileName: String {
        let stamp = startedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(device.modelIdentifier).json"
    }

    // MARK: Markdown

    /// One table for this device: each case with its outcome and every
    /// number it recorded.
    public var markdownSummary: String {
        var lines = [
            "### \(device.displayName)",
            "",
            "\(device.operatingSystem) · \(buildConfiguration ?? "unknown build") · "
                + startedAt.formatted(.iso8601.year().month().day()),
            "",
            "| Benchmark | Outcome | Numbers |",
            "| --- | --- | --- |",
        ]
        for result in results {
            lines.append("| \(result.title) | \(Self.outcomeLabel(result)) | \(Self.numbers(result)) |")
        }
        return lines.joined(separator: "\n")
    }

    /// A table with one row per metric and one column per report, for
    /// comparing devices in docs/benchmarks.md. Latency distributions
    /// contribute a p50 and a p95 row.
    public static func comparisonTable(_ reports: [BenchmarkReport]) -> String {
        guard !reports.isEmpty else { return "" }
        var rows: [(id: String, title: String, metric: String)] = []
        var seen = Set<String>()
        for report in reports {
            for result in report.results {
                for metric in rowKeys(result) where seen.insert("\(result.id)|\(metric)").inserted {
                    rows.append((result.id, result.title, metric))
                }
            }
        }

        let header = "| Benchmark | Metric | " + reports.map { $0.device.displayName }.joined(separator: " | ") + " |"
        let rule = "| --- | --- | " + reports.map { _ in "---" }.joined(separator: " | ") + " |"
        var lines = [header, rule]
        var previousID: String?
        for row in rows {
            let title = row.id == previousID ? "" : row.title
            previousID = row.id
            let cells = reports.map { report -> String in
                guard let result = report.result(row.id) else { return "–" }
                guard result.outcome.isCompleted else { return outcomeLabel(result) }
                return cell(result, key: row.metric) ?? "–"
            }
            lines.append("| \(title) | `\(row.metric)` | " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func outcomeLabel(_ result: BenchmarkResult) -> String {
        switch result.outcome {
        case .completed: result.wasThrottled ? "ok (throttled)" : "ok"
        case .skipped(let reason): "skipped: \(escape(reason))"
        case .failed(let message): "failed: \(escape(message))"
        }
    }

    private static func numbers(_ result: BenchmarkResult) -> String {
        var parts = result.metrics.map { "\($0.key) \($0.formatted)" }
        for key in result.latencies.keys.sorted() {
            guard let summary = result.latencies[key] else { continue }
            parts.append(
                "\(key) p50 \(milliseconds(summary.p50)) / p95 \(milliseconds(summary.p95)) (n=\(summary.count))")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    /// The table rows a result contributes; a result with no numbers (skipped
    /// or failed) still gets an `outcome` row so the table shows why.
    private static func rowKeys(_ result: BenchmarkResult) -> [String] {
        let keys = result.metrics.map(\.key) + result.latencies.keys.sorted().flatMap { ["\($0).p50", "\($0).p95"] }
        return keys.isEmpty ? [outcomeKey] : keys
    }

    private static let outcomeKey = "outcome"

    private static func cell(_ result: BenchmarkResult, key: String) -> String? {
        if key == outcomeKey {
            return outcomeLabel(result)
        }
        if let metric = result.metric(key) {
            return metric.formatted
        }
        for suffix in ["p50", "p95"] where key.hasSuffix(".\(suffix)") {
            let latencyKey = String(key.dropLast(suffix.count + 1))
            guard let summary = result.latencies[latencyKey] else { continue }
            return milliseconds(suffix == "p50" ? summary.p50 : summary.p95)
        }
        return nil
    }

    private static func milliseconds(_ value: Double) -> String {
        BenchmarkMetric(key: "", value: value, unit: .milliseconds).formatted
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
