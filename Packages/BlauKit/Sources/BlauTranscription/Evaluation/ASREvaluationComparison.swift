import BlauTelemetry
import Foundation

extension ASREvaluationReport {
    /// One metric of one engine, now and in the baseline.
    public struct Comparison: Hashable, Sendable {
        public var engine: String
        public var metric: String
        public var baseline: Double?
        public var current: Double?
        public var unit: ASRGateResult.Unit

        /// `current - baseline`, when both exist.
        public var change: Double? {
            guard let baseline, let current else { return nil }
            return current - baseline
        }
    }

    /// The headline metrics of every engine in both reports, for tracking a
    /// run against the committed baseline (`docs/asr-eval/baseline.json`).
    public func comparisons(with baseline: ASREvaluationReport) -> [Comparison] {
        var rows: [Comparison] = []
        for engine in engines {
            guard let old = baseline.engine(engine.descriptor.id) else { continue }
            let id = engine.descriptor.id
            func add(_ metric: String, _ unit: ASRGateResult.Unit, _ value: (ASRMetrics) -> Double?) {
                rows.append(
                    Comparison(
                        engine: id, metric: metric, baseline: value(old.overall), current: value(engine.overall),
                        unit: unit))
            }
            add("WER", .ratio) { $0.wordErrorRate }
            for category in engine.categories {
                rows.append(
                    Comparison(
                        engine: id, metric: "WER \(category.name)",
                        baseline: old.metrics(for: category.name)?.wordErrorRate,
                        current: category.metrics.wordErrorRate, unit: .ratio))
            }
            add("first partial p95", .milliseconds) { $0.firstPartial?.p95 }
            add("end of utterance p95", .milliseconds) { $0.endOfUtterance?.p95 }
            add("end of utterance p95 (audio)", .milliseconds) { $0.endOfUtteranceAudio?.p95 }
            add("RTF", .factor) { $0.realTimeFactor }
            add("unended utterances", .count) { Double($0.unendedUtterances) }
        }
        return rows.filter { $0.baseline != nil || $0.current != nil }
    }

    /// The comparison as a text or Markdown table, with a line saying which
    /// run the baseline is.
    public func comparisonTable(with baseline: ASREvaluationReport, markdown: Bool) -> String {
        let rows = comparisons(with: baseline)
        guard !rows.isEmpty else { return "No engine in common with the baseline." }
        var table = [["Engine", "Metric", "Baseline", "Now", "Change"]]
        for row in rows {
            let format = { (value: Double?) in value.map { ASRGateResult.Check.format($0, row.unit) } ?? "–" }
            let change = row.change.map { value -> String in
                let magnitude = ASRGateResult.Check.format(abs(value), row.unit)
                guard magnitude != ASRGateResult.Check.format(0, row.unit) else { return "±" + magnitude }
                return (value > 0 ? "+" : "-") + magnitude
            }
            table.append([row.engine, row.metric, format(row.baseline), format(row.current), change ?? "–"])
        }
        let date = baseline.generatedAt.formatted(.iso8601.year().month().day())
        let title =
            "Against the baseline of \(date)" + (baseline.commit.map { " (\($0))" } ?? "")
            + " on \(baseline.device.displayName):"
        return title + "\n" + (markdown ? "\n" : "") + Self.render(table, markdown: markdown, leftColumns: 2)
    }
}
