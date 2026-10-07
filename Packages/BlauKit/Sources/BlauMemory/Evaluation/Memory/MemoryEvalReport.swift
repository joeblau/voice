import Foundation

/// What one run of the memory evaluation measured: retrieval for every
/// system, end-to-end answer accuracy when a reader and a judge ran, every
/// question's ranking and answer, and the regression gate's verdict.
/// `report.json` is this, encoded; `docs/memory-eval/baseline.json` is a
/// committed one.
public struct MemoryEvalReport: Codable, Hashable, Sendable {
    public static let currentFormat = 1

    public struct DatasetInfo: Codable, Hashable, Sendable {
        public var name: String
        public var version: Int?
        public var now: Date
        public var questions: Int
        public var questionsByType: [String: Int]
        public var sessions: Int
        public var turns: Int
        public var documents: Int
        public var facts: Int
        public var entities: Int
        /// Chunks in the index built from it.
        public var chunks: Int
    }

    /// One retrieval system's quality over the answerable questions.
    public struct SystemResult: Codable, Hashable, Sendable {
        public var id: String
        public var summary: String
        public var overall: MemoryEvalRetrievalMetrics
        public var byType: [String: MemoryEvalRetrievalMetrics]
        /// Answerable questions with no evidence in the top 5.
        public var misses: [String]

        public func metrics(for type: MemoryEvalDataset.QuestionType) -> MemoryEvalRetrievalMetrics? {
            byType[type.rawValue]
        }
    }

    public struct AnswerResult: Codable, Hashable, Sendable {
        public var reader: String
        public var judge: String
        /// The retrieval system whose results the reader saw.
        public var system: String
        /// Memories handed to the reader per question.
        public var contextSize: Int
        public var overall: MemoryEvalAnswerMetrics
        public var byType: [String: MemoryEvalAnswerMetrics]
        public var seconds: Double

        /// The gate's key for this reader and judge: the reader's identifier,
        /// plus ` judged by <judge>` when another model judged.
        public var key: String { MemoryEvalReport.answerKey(reader: reader, judge: judge) }
    }

    /// One question through the primary system, and its answer.
    public struct QuestionResult: Codable, Hashable, Sendable {
        public var id: String
        public var type: MemoryEvalDataset.QuestionType
        /// Evidence ids of the top 10, best first.
        public var ranking: [String]
        public var retrieval: MemoryEvalRetrievalMetrics?
        /// The rank (from 1) of the first evidence in the top 10.
        public var firstEvidenceRank: Int?
        public var timeExpression: String?
        public var expandedFacts: Int
        public var response: String?
        public var correct: Bool?
        public var judgeReply: String?
        public var error: String?
    }

    public var format: Int
    public var dataset: DatasetInfo
    public var createdAt: Date
    public var commit: String?
    /// The vectors' model version, or `nil` for a run without vectors.
    public var embeddingModel: String?
    /// The system the per-question results and the answers come from.
    public var primarySystem: String
    public var systems: [SystemResult]
    public var answers: AnswerResult?
    /// Why answers weren't evaluated, when they weren't.
    public var answersSkipped: String?
    public var questions: [QuestionResult]
    public var gate: MemoryEvalGateResult?

    public func system(_ id: String) -> SystemResult? { systems.first { $0.id == id } }

    public static func answerKey(reader: String, judge: String) -> String {
        reader == judge ? reader : "\(reader) judged by \(judge)"
    }

    // MARK: - Encoding

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MemoryEvalReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MemoryEvalReport.self, from: data)
    }

    // MARK: - Tables

    static let tableMetrics: [MemoryEvalRetrievalMetrics.Metric] = [
        .recallAt5, .completeAt5, .hitAt1, .mrrAt10, .ndcgAt10, .recallAt10,
    ]

    static func number(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "–"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    /// Rows of cells as a Markdown table, or as aligned plain text.
    static func render(_ rows: [[String]], markdown: Bool) -> String {
        guard let header = rows.first else { return "" }
        if markdown {
            var lines = ["| " + header.joined(separator: " | ") + " |"]
            lines.append("| " + header.indices.map { $0 == 0 ? "---" : "---:" }.joined(separator: " | ") + " |")
            lines += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n")
        }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == 0
                    ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - cell.count) + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Retrieval per system, over every answerable question.
    public func systemsTable(markdown: Bool) -> String {
        var rows = [["System"] + Self.tableMetrics.map(\.rawValue) + ["Current first"]]
        for system in systems {
            rows.append(
                [markdown ? "`\(system.id)`" : system.id]
                    + Self.tableMetrics.map { Self.number(system.overall.value(of: $0)) }
                    + [Self.number(system.overall.currentFirst)])
        }
        return Self.render(rows, markdown: markdown)
    }

    /// The primary system's retrieval by question type, with answer
    /// accuracy when it was evaluated.
    public func typeTable(markdown: Bool) -> String {
        let primary = system(primarySystem)
        var header = ["Type", "Questions", "Recall@5", "Complete@5", "MRR@10", "Current first"]
        if answers != nil { header.append("Answer accuracy") }
        var rows = [header]
        var types = MemoryEvalDataset.QuestionType.allCases.filter { (dataset.questionsByType[$0.rawValue] ?? 0) > 0 }
        if types.isEmpty { types = MemoryEvalDataset.QuestionType.allCases }
        for type in types {
            let metrics = primary?.metrics(for: type)
            var row = [
                type.rawValue, "\(dataset.questionsByType[type.rawValue] ?? 0)", Self.number(metrics?.recallAt5),
                Self.number(metrics?.completeAt5), Self.number(metrics?.mrrAt10), Self.number(metrics?.currentFirst),
            ]
            if let answers {
                row.append(answers.byType[type.rawValue].map { Self.answerCell($0) } ?? "–")
            }
            rows.append(row)
        }
        var total = [
            markdown ? "**all**" : "all", "\(dataset.questions)", Self.number(primary?.overall.recallAt5),
            Self.number(primary?.overall.completeAt5), Self.number(primary?.overall.mrrAt10),
            Self.number(primary?.overall.currentFirst),
        ]
        if let answers { total.append(Self.answerCell(answers.overall)) }
        rows.append(total)
        return Self.render(rows, markdown: markdown)
    }

    static func answerCell(_ metrics: MemoryEvalAnswerMetrics) -> String {
        "\(percent(metrics.accuracy)) (\(metrics.correct)/\(metrics.count))"
    }

    /// The plain-text summary `make eval-memory` prints.
    public func table() -> String {
        var lines = [
            "Memory evaluation: \(dataset.name), \(dataset.questions) questions, \(dataset.chunks) chunks"
                + (embeddingModel.map { ", vectors \($0)" } ?? ", no vectors"),
            "",
            systemsTable(markdown: false),
            "",
            "\(primarySystem) by question type:",
            typeTable(markdown: false),
        ]
        if let answers {
            lines += [
                "",
                "Answers: reader \(answers.reader), judge \(answers.judge), top \(answers.contextSize) memories, "
                    + "\(answers.overall.failures) failures, \(Int(answers.seconds.rounded())) s",
            ]
        } else if let answersSkipped {
            lines += ["", "Answers not evaluated: \(answersSkipped)"]
        }
        if let gate { lines += ["", gate.summary()] }
        return lines.joined(separator: "\n")
    }

    /// The full report as Markdown.
    public func markdown() -> String {
        var lines = [
            "# Memory evaluation",
            "",
            "Dataset `\(dataset.name)`\(dataset.version.map { " v\($0)" } ?? ""): \(dataset.questions) questions over "
                + "\(dataset.sessions) sessions (\(dataset.turns) exchanges), \(dataset.documents) documents and collection items, "
                + "\(dataset.facts) facts and \(dataset.entities) entities; \(dataset.chunks) chunks in the index. "
                + "Commit \(commit.map { "`\($0)`" } ?? "unknown"), \(createdAt.formatted(.iso8601)). Vectors: "
                + (embeddingModel.map { "`\($0)`" } ?? "none") + ".",
            "",
            "## Retrieval",
            "",
            "Over the \(systems.first?.overall.count ?? 0) answerable questions (top 10).",
            "",
            systemsTable(markdown: true),
            "",
            "## By question type (`\(primarySystem)`)",
            "",
            typeTable(markdown: true),
            "",
        ]
        if let answers {
            lines += [
                "## Answers",
                "",
                "Reader `\(answers.reader)`, judge `\(answers.judge)`, the top \(answers.contextSize) memories from "
                    + "`\(answers.system)`: \(Self.answerCell(answers.overall)) correct, \(answers.overall.failures) "
                    + "failures, \(Int(answers.seconds.rounded())) s.",
                "",
            ]
            let wrong = questions.filter { $0.response != nil || $0.error != nil }.filter { $0.correct != true }
            if !wrong.isEmpty {
                lines += ["| Question | Type | First evidence | Response |", "| --- | --- | ---: | --- |"]
                for question in wrong {
                    let response = (question.error.map { "error: \($0)" } ?? question.response ?? "")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                    lines.append(
                        "| `\(question.id)` | \(question.type.rawValue) | "
                            + "\(question.firstEvidenceRank.map(String.init) ?? "–") | \(response.prefix(160)) |")
                }
                lines.append("")
            }
        } else if let answersSkipped {
            lines += ["## Answers", "", "Not evaluated: \(answersSkipped).", ""]
        }
        if let primary = system(primarySystem), !primary.misses.isEmpty {
            lines += [
                "## Retrieval misses (`\(primarySystem)`)", "",
                "No evidence in the top 5: " + primary.misses.map { "`\($0)`" }.joined(separator: ", ") + ".", "",
            ]
        }
        if let gate {
            lines += ["## Regression gate", "", "```", gate.summary(), "```", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// The change against `baseline`, metric by metric.
    public func comparisonTable(with baseline: MemoryEvalReport, markdown: Bool) -> String {
        var rows = [["Metric", "Baseline", "Now", "Change"]]
        func row(_ name: String, _ old: Double?, _ new: Double?) {
            let change = old.flatMap { old in new.map { String(format: "%+.3f", $0 - old) } } ?? "–"
            rows.append([name, Self.number(old), Self.number(new), change])
        }
        for system in systems {
            let old = baseline.system(system.id)
            for metric in [MemoryEvalRetrievalMetrics.Metric.recallAt5, .completeAt5, .mrrAt10] {
                row("\(system.id) \(metric.rawValue)", old?.overall.value(of: metric), system.overall.value(of: metric))
            }
        }
        if let answers {
            let old = baseline.answers?.key == answers.key ? baseline.answers : nil
            row("answer accuracy (\(answers.key))", old?.overall.accuracy, answers.overall.accuracy)
            for type in MemoryEvalDataset.QuestionType.allCases {
                guard let new = answers.byType[type.rawValue] else { continue }
                row("  \(type.rawValue)", old?.byType[type.rawValue]?.accuracy, new.accuracy)
            }
        }
        return Self.render(rows, markdown: markdown)
    }
}
