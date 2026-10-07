import BlauTelemetry
import Foundation

/// The result of an ASR evaluation run: what was evaluated, where, and every
/// engine's metrics. Written as `report.json` (the CI artifact the nightly
/// job keeps) and rendered as text tables (`table()`, what `make eval-asr`
/// prints) and Markdown (`markdown()`, the job summary).
public struct ASREvaluationReport: Codable, Hashable, Sendable {
    /// Bumped when the JSON changes incompatibly.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var device: BenchmarkDevice
    /// The commit evaluated, when known (`GITHUB_SHA` in CI).
    public var commit: String?
    public var dataset: ASRDatasetSummary
    public var engines: [ASREngineReport]
    /// The regression gate's verdict, when thresholds were given.
    public var gate: ASRGateResult?

    public init(
        generatedAt: Date, device: BenchmarkDevice, commit: String?, dataset: ASRDatasetSummary,
        engines: [ASREngineReport], gate: ASRGateResult? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.device = device
        self.commit = commit
        self.dataset = dataset
        self.engines = engines
        self.gate = gate
    }

    public func engine(_ id: String) -> ASREngineReport? {
        engines.first { $0.descriptor.id == id }
    }

    // MARK: JSON

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ASREvaluationReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ASREvaluationReport.self, from: data)
    }

    // MARK: Text

    /// One table per engine, rows per category and overall, for the
    /// terminal.
    public func table() -> String {
        var lines: [String] = [
            "ASR evaluation: \(dataset.name), \(dataset.fixtures) fixtures, \(dataset.utterances) utterances, "
                + "\(Self.seconds(dataset.audioSeconds)) of audio",
            "Device: \(device.displayName), \(device.operatingSystem)" + (commit.map { "; commit \($0)" } ?? ""),
        ]
        for engine in engines {
            lines.append("")
            lines.append("\(engine.descriptor.id): \(engine.descriptor.title)")
            let details = Self.details(engine.descriptor)
            if !details.isEmpty { lines.append(details) }
            lines.append(Self.render(Self.rows(engine), markdown: false))
            for fixture in engine.fixtures where fixture.error != nil {
                lines.append("  \(fixture.id) failed: \(fixture.error ?? "")")
            }
        }
        lines.append("")
        lines.append(Self.legend)
        if let gate {
            lines.append("")
            lines.append(gate.summary())
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Markdown

    /// The report as Markdown: the tables, the gate, and the fixtures each
    /// engine got wrong.
    public func markdown() -> String {
        var lines: [String] = [
            "# ASR evaluation",
            "",
            "- Dataset: `\(dataset.name)`, \(dataset.fixtures) fixtures, \(dataset.utterances) utterances, "
                + "\(Self.seconds(dataset.audioSeconds)) of audio (\(dataset.categories.joined(separator: ", ")))",
            "- Device: \(device.displayName), \(device.operatingSystem)",
            "- Generated: \(generatedAt.formatted(.iso8601))" + (commit.map { " at `\($0)`" } ?? ""),
        ]
        if let gate {
            lines.append("- Regression gate: " + (gate.passed ? "**passed**" : "**failed**"))
        }
        for engine in engines {
            lines.append("")
            lines.append("## `\(engine.descriptor.id)`: \(engine.descriptor.title)")
            let details = Self.details(engine.descriptor)
            if !details.isEmpty {
                lines.append("")
                lines.append(details)
            }
            lines.append("")
            lines.append(Self.render(Self.rows(engine), markdown: true))
            let wrong = engine.fixtures.filter { $0.counts.errors > 0 || $0.error != nil }
            if !wrong.isEmpty {
                lines.append("")
                lines.append("<details><summary>\(wrong.count) fixtures with errors</summary>")
                lines.append("")
                lines.append("| Fixture | WER | Reference | Hypothesis |")
                lines.append("| --- | ---: | --- | --- |")
                for fixture in wrong {
                    let hypothesis = fixture.error.map { "*failed: \($0)*" } ?? fixture.hypothesis
                    lines.append(
                        "| \(fixture.id) | \(ASREvaluator.percent(fixture.counts.wordErrorRate)) | "
                            + "\(Self.escape(fixture.reference)) | \(Self.escape(hypothesis)) |")
                }
                lines.append("")
                lines.append("</details>")
            }
        }
        lines.append("")
        lines.append(Self.legend)
        if let gate {
            lines.append("")
            lines.append("## Regression gate")
            lines.append("")
            lines.append("| Engine | Metric | Value | Limit | Result |")
            lines.append("| --- | --- | ---: | ---: | --- |")
            for check in gate.checks {
                lines.append(
                    "| `\(check.engine)` | \(check.metric) | \(check.formattedValue) | \(check.formattedLimit) | "
                        + (check.passed ? "pass" : "**FAIL**") + " |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Rendering

    static let legend = """
        WER: corpus word error rate after normalization (sub/del/ins: substituted, deleted, inserted words). \
        First partial: start of speech to the first partial. End of utterance: end of speech to the final \
        (offline engines: padding + compute after the utterance is handed over). Latencies are audio time \
        plus the compute of the emitting call; "audio" columns leave the compute out. RTF: compute / audio. \
        Missed: utterances with no final; split: utterances cut into several finals; unended: utterances \
        finalized only because the audio ended (nothing detected their end; left out of the end-of-utterance \
        latency).
        """

    static let header = [
        "Category", "Files", "Words", "WER", "Sub", "Del", "Ins", "First partial p50 / p95",
        "End of utterance p50 / p95", "EOU audio p95", "RTF", "Missed", "Split", "Unended",
    ]

    static func rows(_ engine: ASREngineReport) -> [[String]] {
        var rows = [header]
        for category in engine.categories {
            rows.append(row(category.name, category.metrics))
        }
        rows.append(row("all", engine.overall))
        return rows
    }

    static func row(_ name: String, _ metrics: ASRMetrics) -> [String] {
        [
            name, "\(metrics.fixtures)", "\(metrics.counts.referenceWords)",
            ASREvaluator.percent(metrics.wordErrorRate), "\(metrics.counts.substitutions)",
            "\(metrics.counts.deletions)", "\(metrics.counts.insertions)", latency(metrics.firstPartial),
            latency(metrics.endOfUtterance), metrics.endOfUtteranceAudio.map { milliseconds($0.p95) } ?? "–",
            String(format: "%.3f", metrics.realTimeFactor), "\(metrics.missedUtterances)",
            "\(metrics.splitUtterances)", "\(metrics.unendedUtterances)",
        ]
    }

    static func latency(_ summary: LatencySummary?) -> String {
        guard let summary else { return "–" }
        return "\(Int(summary.p50.rounded())) / \(milliseconds(summary.p95))"
    }

    static func milliseconds(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    static func details(_ descriptor: ASREngineDescriptor) -> String {
        var parts: [String] = [descriptor.kind.rawValue]
        if let model = descriptor.model { parts.append("model \(model)") }
        parts += descriptor.settings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        return parts.joined(separator: " · ")
    }

    /// Text columns padded to their widest cell (the first `leftColumns`
    /// left aligned, the rest right aligned), or a Markdown table.
    static func render(_ rows: [[String]], markdown: Bool, leftColumns: Int = 1) -> String {
        guard let header = rows.first else { return "" }
        if markdown {
            var lines = ["| " + header.joined(separator: " | ") + " |"]
            lines.append(
                "|" + String(repeating: " --- |", count: leftColumns)
                    + String(repeating: " ---: |", count: header.count - leftColumns))
            lines += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n")
        }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return column < leftColumns ? cell + padding : padding + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
