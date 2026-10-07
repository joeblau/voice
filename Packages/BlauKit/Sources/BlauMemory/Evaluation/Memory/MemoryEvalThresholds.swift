import Foundation

/// The memory evaluation's regression gate (`docs/memory-eval/thresholds.json`):
/// the lowest retrieval metrics each system may score, overall and per
/// question type, and the lowest answer accuracy per reader and judge.
///
/// ```json
/// {
///   "retrieval": {
///     "hybrid": {
///       "overall": {"Recall@5": 0.85, "MRR@10": 0.7},
///       "byType": {"temporal": {"Recall@5": 0.8}}
///     }
///   },
///   "answers": {
///     "apple-foundation-models": {"minAccuracy": 0.6, "byType": {"abstention": 0.7}, "maxFailures": 3}
///   }
/// }
/// ```
///
/// A system listed here must have run, or the gate fails. Answer limits
/// apply only to a run whose reader and judge match the key (answers are
/// optional: the CI machine may have no model); `requireAnswers` turns a
/// missing answer stage into a failure.
public struct MemoryEvalThresholds: Codable, Hashable, Sendable {
    public typealias Metric = MemoryEvalRetrievalMetrics.Metric

    public struct RetrievalLimits: Codable, Hashable, Sendable {
        public var overall: [Metric: Double]?
        public var byType: [String: [Metric: Double]]?

        public init(overall: [Metric: Double]? = nil, byType: [String: [Metric: Double]]? = nil) {
            self.overall = overall
            self.byType = byType
        }
    }

    public struct AnswerLimits: Codable, Hashable, Sendable {
        public var minAccuracy: Double?
        public var byType: [String: Double]?
        /// Questions whose reader or judge may fail. Defaults to no limit.
        public var maxFailures: Int?

        public init(minAccuracy: Double? = nil, byType: [String: Double]? = nil, maxFailures: Int? = nil) {
            self.minAccuracy = minAccuracy
            self.byType = byType
            self.maxFailures = maxFailures
        }
    }

    public var description: String?
    public var retrieval: [String: RetrievalLimits]
    public var answers: [String: AnswerLimits]?

    public init(
        description: String? = nil, retrieval: [String: RetrievalLimits], answers: [String: AnswerLimits]? = nil
    ) {
        self.description = description
        self.retrieval = retrieval
        self.answers = answers
    }

    public static func load(_ url: URL) throws -> MemoryEvalThresholds {
        try JSONDecoder().decode(MemoryEvalThresholds.self, from: Data(contentsOf: url))
    }

    /// Checks `report` against every limit.
    ///
    /// - Parameters:
    ///   - partial: The run left questions out (a type or id filter, or a
    ///     limit), so overall numbers aren't comparable: only the per-type
    ///     limits of the types that ran are checked.
    ///   - requireAnswers: Fail when answers weren't evaluated, or were
    ///     evaluated by a reader and judge without limits here.
    public func evaluate(_ report: MemoryEvalReport, partial: Bool = false, requireAnswers: Bool = false)
        -> MemoryEvalGateResult
    {
        var checks: [MemoryEvalGateResult.Check] = []
        var notes: [String] = []
        let ranTypes = Set(report.dataset.questionsByType.filter { $0.value > 0 }.keys)

        for (id, limits) in retrieval.sorted(by: { $0.key < $1.key }) {
            guard let system = report.system(id) else {
                checks.append(.init(scope: id, metric: "ran", value: nil, limit: 1, passed: false))
                continue
            }
            if partial {
                if limits.overall?.isEmpty == false { notes.append("\(id): overall limits skipped (partial run)") }
            } else {
                for (metric, limit) in (limits.overall ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    checks.append(
                        .minimum(
                            scope: id, metric: metric.rawValue, value: system.overall.value(of: metric), limit: limit))
                }
            }
            for (type, metrics) in (limits.byType ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard !partial || ranTypes.contains(type) else { continue }
                let measured = system.byType[type]
                for (metric, limit) in metrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    checks.append(
                        .minimum(
                            scope: "\(id) \(type)", metric: metric.rawValue, value: measured?.value(of: metric),
                            limit: limit))
                }
            }
        }

        if let answers = report.answers {
            if let limits = self.answers?[answers.key] {
                let scope = "answers (\(answers.key))"
                if let minimum = limits.minAccuracy {
                    if partial {
                        notes.append("\(scope): overall accuracy limit skipped (partial run)")
                    } else {
                        checks.append(
                            .minimum(scope: scope, metric: "accuracy", value: answers.overall.accuracy, limit: minimum))
                    }
                }
                for (type, minimum) in (limits.byType ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard !partial || ranTypes.contains(type) else { continue }
                    checks.append(
                        .minimum(
                            scope: "\(scope) \(type)", metric: "accuracy", value: answers.byType[type]?.accuracy,
                            limit: minimum))
                }
                if let maximum = limits.maxFailures, !partial {
                    checks.append(
                        .maximum(
                            scope: scope, metric: "failures", value: Double(answers.overall.failures),
                            limit: Double(maximum)))
                }
            } else {
                let message = "answers by \(answers.key) have no limits"
                if requireAnswers {
                    checks.append(
                        .init(scope: "answers (\(answers.key))", metric: "limits", value: nil, limit: 1, passed: false))
                }
                notes.append(message)
            }
        } else {
            let reason = report.answersSkipped ?? "no reader"
            if requireAnswers {
                checks.append(.init(scope: "answers", metric: "ran", value: nil, limit: 1, passed: false))
            }
            notes.append("answers not evaluated (\(reason)); answer limits not checked")
        }
        return MemoryEvalGateResult(checks: checks, notes: notes)
    }
}

/// The regression gate's verdict.
public struct MemoryEvalGateResult: Codable, Hashable, Sendable {
    public struct Check: Codable, Hashable, Sendable {
        /// The system (and type), or the answer stage.
        public var scope: String
        public var metric: String
        /// `nil` when nothing was measured (the system didn't run).
        public var value: Double?
        public var limit: Double
        /// `true` when `value` must stay at or under `limit`.
        public var isMaximum: Bool
        public var passed: Bool

        public init(scope: String, metric: String, value: Double?, limit: Double, isMaximum: Bool = false, passed: Bool)
        {
            self.scope = scope
            self.metric = metric
            self.value = value
            self.limit = limit
            self.isMaximum = isMaximum
            self.passed = passed
        }

        static func minimum(scope: String, metric: String, value: Double?, limit: Double) -> Check {
            Check(
                scope: scope, metric: metric, value: value, limit: limit,
                passed: value.map { $0 >= limit - 1e-9 } ?? false)
        }

        static func maximum(scope: String, metric: String, value: Double?, limit: Double) -> Check {
            Check(
                scope: scope, metric: metric, value: value, limit: limit, isMaximum: true,
                passed: value.map { $0 <= limit + 1e-9 } ?? false)
        }
    }

    public var checks: [Check]
    public var notes: [String]

    public init(checks: [Check], notes: [String] = []) {
        self.checks = checks
        self.notes = notes
    }

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [Check] { checks.filter { !$0.passed } }

    /// One line per failed check (or a pass line), then the notes.
    public func summary() -> String {
        var lines: [String]
        if passed {
            lines = ["Regression gate: passed (\(checks.count) checks)"]
        } else {
            lines = ["Regression gate: FAILED (\(failures.count) of \(checks.count) checks)"]
            lines += failures.map { check in
                guard let value = check.value else { return "  \(check.scope): \(check.metric) not measured" }
                let comparison = check.isMaximum ? ">" : "<"
                return "  \(check.scope): \(check.metric) \(MemoryEvalReport.number(value)) \(comparison) "
                    + MemoryEvalReport.number(check.limit)
            }
        }
        lines += notes.map { "  note: \($0)" }
        return lines.joined(separator: "\n")
    }
}
