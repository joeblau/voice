import BlauTelemetry
import Foundation

/// Lines up each ASR engine with its noise-suppressed variants
/// (`<engine>+<suppressor>`, ``NoiseSuppressedASREvaluationEngine``) from
/// one evaluation report: the A/B table of docs/noise-suppression.md.
public struct NoiseSuppressionComparison: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        /// The base engine's id.
        public var engine: String
        /// `none` for the engine alone, otherwise the suppressor's id.
        public var suppressor: String
        /// WER by category, in the report's category order, then overall.
        public var wordErrorRates: [Double?]
        /// Inserted words over every fixture (TV and cafe talkers end up
        /// as insertions).
        public var insertions: Int
        /// Utterances only finalized because the audio ended.
        public var unended: Int
        public var utterances: Int
        public var firstPartialP95: Double?
        public var endOfUtteranceP95: Double?
        public var realTimeFactor: Double
    }

    /// The fixture categories, in report order.
    public var categories: [String]
    public var rows: [Row]

    /// The name of the unprocessed variant.
    public static let baseline = "none"

    public init(_ report: ASREvaluationReport) {
        categories = report.dataset.categories
        var rows: [Row] = []
        let bases = report.engines.filter { !$0.descriptor.id.contains("+") }
        for base in bases {
            let variants = report.engines.filter {
                $0.descriptor.id == base.descriptor.id || $0.descriptor.id.hasPrefix(base.descriptor.id + "+")
            }
            for variant in variants {
                let id = variant.descriptor.id
                let suppressor =
                    id == base.descriptor.id ? Self.baseline : String(id.dropFirst(base.descriptor.id.count + 1))
                rows.append(
                    Row(
                        engine: base.descriptor.id, suppressor: suppressor,
                        wordErrorRates: categories.map { variant.metrics(for: $0)?.wordErrorRate }
                            + [variant.overall.wordErrorRate],
                        insertions: variant.overall.counts.insertions,
                        unended: variant.overall.unendedUtterances,
                        utterances: variant.overall.utterances,
                        firstPartialP95: variant.overall.firstPartial?.p95,
                        endOfUtteranceP95: variant.overall.endOfUtterance?.p95,
                        realTimeFactor: variant.overall.realTimeFactor))
            }
        }
        self.rows = rows
    }

    /// One Markdown table per engine.
    public func markdown() -> String {
        var sections: [String] = []
        for engine in rows.map(\.engine).uniqued() {
            var lines = [
                "`\(engine)`:",
                "",
                "| Suppressor | " + categories.map { "WER \($0)" }.joined(separator: " | ")
                    + " | WER all | Inserted | Unended | First partial p95 | End of utterance p95 | RTF |",
                "| --- |" + String(repeating: " ---: |", count: categories.count + 6),
            ]
            for row in rows where row.engine == engine {
                let rates = row.wordErrorRates.map { $0.map(ASREvaluator.percent) ?? "–" }
                let cells =
                    ["`\(row.suppressor)`"] + rates + [
                        "\(row.insertions)", "\(row.unended) of \(row.utterances)",
                        row.firstPartialP95.map { "\(Int($0.rounded())) ms" } ?? "–",
                        row.endOfUtteranceP95.map { "\(Int($0.rounded())) ms" } ?? "–",
                        String(format: "%.3f", row.realTimeFactor),
                    ]
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

extension Sequence where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
