import BlauTelemetry
import Foundation

/// The regression gate for the nightly ASR evaluation: per engine, the
/// worst WER, latency and speed still accepted (`docs/asr-eval/thresholds.json`).
///
/// Every limit is optional; an engine listed here must have run, or the
/// gate fails. Set a limit from the committed baseline plus a margin (see
/// docs/asr-eval.md): tight for what the hardware doesn't change (WER, the
/// audio-time latencies), loose for what it does (latency with compute,
/// RTF), because the nightly job runs on a CI virtual machine without the
/// Neural Engine.
public struct ASREvaluationThresholds: Codable, Hashable, Sendable {
    public var description: String?
    public var engines: [String: Limits]

    public struct Limits: Codable, Hashable, Sendable {
        /// Corpus WER over every fixture.
        public var maxWER: Double?
        /// Corpus WER per category.
        public var maxCategoryWER: [String: Double]?
        public var maxFirstPartialP95Ms: Double?
        public var maxFirstPartialAudioP95Ms: Double?
        public var maxEndOfUtteranceP95Ms: Double?
        public var maxEndOfUtteranceAudioP95Ms: Double?
        public var maxRealTimeFactor: Double?
        public var maxMissedUtterances: Int?
        public var maxSplitUtterances: Int?
        public var maxUnendedUtterances: Int?
        /// Fixtures the engine may throw on. Defaults to none.
        public var maxFailures: Int?

        public init(
            maxWER: Double? = nil, maxCategoryWER: [String: Double]? = nil, maxFirstPartialP95Ms: Double? = nil,
            maxFirstPartialAudioP95Ms: Double? = nil, maxEndOfUtteranceP95Ms: Double? = nil,
            maxEndOfUtteranceAudioP95Ms: Double? = nil, maxRealTimeFactor: Double? = nil,
            maxMissedUtterances: Int? = nil, maxSplitUtterances: Int? = nil, maxUnendedUtterances: Int? = nil,
            maxFailures: Int? = nil
        ) {
            self.maxWER = maxWER
            self.maxCategoryWER = maxCategoryWER
            self.maxFirstPartialP95Ms = maxFirstPartialP95Ms
            self.maxFirstPartialAudioP95Ms = maxFirstPartialAudioP95Ms
            self.maxEndOfUtteranceP95Ms = maxEndOfUtteranceP95Ms
            self.maxEndOfUtteranceAudioP95Ms = maxEndOfUtteranceAudioP95Ms
            self.maxRealTimeFactor = maxRealTimeFactor
            self.maxMissedUtterances = maxMissedUtterances
            self.maxSplitUtterances = maxSplitUtterances
            self.maxUnendedUtterances = maxUnendedUtterances
            self.maxFailures = maxFailures
        }
    }

    public init(description: String? = nil, engines: [String: Limits]) {
        self.description = description
        self.engines = engines
    }

    public static func load(_ url: URL) throws -> ASREvaluationThresholds {
        try JSONDecoder().decode(ASREvaluationThresholds.self, from: Data(contentsOf: url))
    }

    /// Checks `report` against every limit.
    ///
    /// - Parameters:
    ///   - engineIDs: Only gate these engines (the ones selected for the
    ///     run); `nil` gates every engine listed here.
    ///   - categories: Only gate these categories' WER (the ones selected
    ///     for the run); `nil` requires every category with a limit, so a
    ///     category missing from the report fails.
    public func evaluate(
        _ report: ASREvaluationReport, engineIDs: Set<String>? = nil, categories: Set<String>? = nil
    ) -> ASRGateResult {
        var checks: [ASRGateResult.Check] = []
        for (id, limits) in engines.sorted(by: { $0.key < $1.key }) where engineIDs?.contains(id) ?? true {
            guard let engine = report.engine(id) else {
                checks.append(.init(engine: id, metric: "ran", value: nil, limit: 1, unit: .count, passed: false))
                continue
            }
            let overall = engine.overall
            func check(_ metric: String, _ value: Double?, _ limit: Double?, _ unit: ASRGateResult.Unit) {
                guard let limit else { return }
                let passed = value.map { $0 <= limit } ?? false
                checks.append(.init(engine: id, metric: metric, value: value, limit: limit, unit: unit, passed: passed))
            }
            check("WER", overall.wordErrorRate, limits.maxWER, .ratio)
            for (category, limit) in (limits.maxCategoryWER ?? [:]).sorted(by: { $0.key < $1.key })
            where categories?.contains(category) ?? true {
                check("WER \(category)", engine.metrics(for: category)?.wordErrorRate, limit, .ratio)
            }
            check("first partial p95", overall.firstPartial?.p95, limits.maxFirstPartialP95Ms, .milliseconds)
            check(
                "first partial p95 (audio)", overall.firstPartialAudio?.p95, limits.maxFirstPartialAudioP95Ms,
                .milliseconds)
            check("end of utterance p95", overall.endOfUtterance?.p95, limits.maxEndOfUtteranceP95Ms, .milliseconds)
            check(
                "end of utterance p95 (audio)", overall.endOfUtteranceAudio?.p95, limits.maxEndOfUtteranceAudioP95Ms,
                .milliseconds)
            check("RTF", overall.realTimeFactor, limits.maxRealTimeFactor, .factor)
            check(
                "missed utterances", Double(overall.missedUtterances), limits.maxMissedUtterances.map(Double.init),
                .count)
            check(
                "split utterances", Double(overall.splitUtterances), limits.maxSplitUtterances.map(Double.init), .count)
            check(
                "unended utterances", Double(overall.unendedUtterances), limits.maxUnendedUtterances.map(Double.init),
                .count)
            check("failures", Double(overall.failures), Double(limits.maxFailures ?? 0), .count)
        }
        return ASRGateResult(checks: checks)
    }
}

/// The regression gate's verdict.
public struct ASRGateResult: Codable, Hashable, Sendable {
    public var checks: [Check]

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [Check] { checks.filter { !$0.passed } }

    public enum Unit: String, Codable, Hashable, Sendable {
        case ratio, milliseconds, factor, count
    }

    public struct Check: Codable, Hashable, Sendable {
        public var engine: String
        public var metric: String
        /// `nil` when the engine produced nothing to measure (no partials,
        /// no run).
        public var value: Double?
        public var limit: Double
        public var unit: Unit
        public var passed: Bool

        public var formattedValue: String { value.map { Self.format($0, unit) } ?? "–" }
        public var formattedLimit: String { Self.format(limit, unit) }

        static func format(_ value: Double, _ unit: Unit) -> String {
            switch unit {
            case .ratio: ASREvaluator.percent(value)
            case .milliseconds: "\(Int(value.rounded())) ms"
            case .factor: String(format: "%.3f", value)
            case .count: "\(Int(value))"
            }
        }
    }

    public init(checks: [Check]) {
        self.checks = checks
    }

    /// One line per failed check, or a pass line.
    public func summary() -> String {
        guard !passed else { return "Regression gate: passed (\(checks.count) checks)" }
        let lines = failures.map { check in
            check.metric == "ran"
                ? "  \(check.engine): did not run"
                : "  \(check.engine): \(check.metric) \(check.formattedValue) > \(check.formattedLimit)"
        }
        return (["Regression gate: FAILED (\(failures.count) of \(checks.count) checks)"] + lines)
            .joined(separator: "\n")
    }
}
