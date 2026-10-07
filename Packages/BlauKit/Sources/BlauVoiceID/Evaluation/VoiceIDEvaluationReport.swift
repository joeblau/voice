import BlauCore
import Foundation

/// Summary numbers for one slice of an evaluation: one preprocessor, scoring
/// method, window and condition.
public struct VoiceIDEvaluationMetrics: Hashable, Codable, Sendable {
    public let preprocessor: String
    public let scoring: VoiceIDScoring
    /// Window length in seconds.
    public let window: Double
    /// A condition name, or `all` for every condition pooled.
    public let condition: String
    public let targetTrials: Int
    public let nonTargetTrials: Int
    public let equalErrorRate: Double
    public let equalErrorThreshold: Float
    /// FAR at each of the plan's fixed FRRs (the point's `falseRejectRate`
    /// is the achieved FRR, at most the fixed one).
    public let atFixedFalseRejectRates: [VoiceIDOperatingPoint]
    /// FRR at each of the plan's fixed FARs.
    public let atFixedFalseAcceptRates: [VoiceIDOperatingPoint]
    /// The DET curve, thinned for plotting.
    public let curve: [VoiceIDOperatingPoint]

    /// - Returns: `nil` if `scores` lacks target or non-target trials.
    init?(
        preprocessor: String, scoring: VoiceIDScoring, window: SpeakerEmbeddingWindow, condition: String,
        scores: VoiceIDScores, plan: VoiceIDEvaluationPlan
    ) {
        guard scores.isComplete else { return nil }
        let curve = DETCurve(scores)
        let equalError = curve.equalErrorPoint
        self.preprocessor = preprocessor
        self.scoring = scoring
        self.window = window.seconds
        self.condition = condition
        self.targetTrials = scores.target.count
        self.nonTargetTrials = scores.nonTarget.count
        self.equalErrorRate = equalError.falseAcceptRate
        self.equalErrorThreshold = equalError.threshold
        self.atFixedFalseRejectRates = plan.reportedFalseRejectRates.map { curve.threshold(forFalseRejectRate: $0) }
        self.atFixedFalseAcceptRates = plan.reportedFalseAcceptRates.map { curve.threshold(forFalseAcceptRate: $0) }
        self.curve = curve.thinnedPoints(maximumCount: 120)
    }
}

/// Accept / uncertain / reject counts at the calibrated thresholds for one
/// group of trials.
public struct VoiceIDDecisionBreakdown: Hashable, Codable, Sendable {
    public enum TrialKind: String, Hashable, Codable, Sendable {
        /// The probe is the enrolled speaker: accepts are right.
        case target
        /// Anyone or anything else: accepts are false accepts.
        case nonTarget = "non-target"
    }

    /// Window length in seconds.
    public let window: Double
    /// A condition name, or `all`.
    public let condition: String
    /// `all`, `source=<kind>` or `<tag>=<value>`.
    public let group: String
    public let trials: TrialKind
    public let accepted: Int
    public let uncertain: Int
    public let rejected: Int

    public var total: Int { accepted + uncertain + rejected }

    public func rate(_ decision: SpeakerDecision) -> Double {
        guard total > 0 else { return 0 }
        let count =
            switch decision {
            case .accept: accepted
            case .uncertain: uncertain
            case .reject: rejected
            }
        return Double(count) / Double(total)
    }
}

/// Score distributions at one window, binned, with the calibrated
/// thresholds: the picture behind `T_hi` and `T_lo`.
public struct VoiceIDScoreHistogram: Hashable, Codable, Sendable {
    public let window: Double
    /// Lower edge of the first bin.
    public let lowerBound: Float
    public let binWidth: Float
    public let targetCounts: [Int]
    public let nonTargetCounts: [Int]
    public let thresholds: VoiceIDThresholds

    init(window: SpeakerEmbeddingWindow, scores: VoiceIDScores, thresholds: VoiceIDThresholds, binWidth: Float = 0.02) {
        let all = scores.target + scores.nonTarget
        let low = ((all.min() ?? 0) / binWidth).rounded(.down) * binWidth
        let high = ((all.max() ?? 1) / binWidth).rounded(.up) * binWidth
        let binCount = max(1, Int(((high - low) / binWidth).rounded()) + 1)
        func histogram(_ values: [Float]) -> [Int] {
            var counts = [Int](repeating: 0, count: binCount)
            for value in values {
                counts[min(binCount - 1, max(0, Int((value - low) / binWidth)))] += 1
            }
            return counts
        }
        self.window = window.seconds
        self.lowerBound = low
        self.binWidth = binWidth
        self.targetCounts = histogram(scores.target)
        self.nonTargetCounts = histogram(scores.nonTarget)
        self.thresholds = thresholds
    }
}

/// Everything an evaluation run measured, and the thresholds it proposes.
/// Codable, so runs can be stored and compared over time; `markdown()` and
/// ``VoiceIDEvaluationPlots`` render it for docs/voice-id-eval.md.
public struct VoiceIDEvaluationReport: Hashable, Codable, Sendable {
    public struct Calibration: Hashable, Codable, Sendable {
        public let scoring: VoiceIDScoring
        public let targets: VoiceIDCalibrationTargets
        public let short: VoiceIDCalibratedThresholds
        public let long: VoiceIDCalibratedThresholds
        /// The proposed configuration, ready to paste into
        /// `VoiceIDConfig.calibrated`.
        public let config: VoiceIDConfig
    }

    public let dataset: String
    public let consent: String
    public let date: String
    public let modelIdentifier: String
    public let targetSpeakers: Int
    public let enrollmentRecordings: Int
    public let probeRecordings: Int
    /// Probe recordings per source kind.
    public let probeSources: [String: Int]
    public let cohortSize: Int
    /// Window lengths in seconds.
    public let windows: [Double]
    public let conditions: [VoiceIDCondition]
    /// Conditions the dataset couldn't run (no cohort talkers).
    public let skippedConditions: [String]
    /// Scoring methods the dataset couldn't run (no cohort).
    public let skippedScorings: [String]
    public let preprocessors: [String]
    /// The FRRs at which each slice reports the FAR.
    public let reportedFalseRejectRates: [Double]
    /// The FARs at which each slice reports the FRR.
    public let reportedFalseAcceptRates: [Double]
    public let metrics: [VoiceIDEvaluationMetrics]
    public let calibration: Calibration
    public let decisions: [VoiceIDDecisionBreakdown]
    public let histograms: [VoiceIDScoreHistogram]

    /// The metrics for one slice, if it was measured.
    public func metrics(
        preprocessor: String = VoiceIDEvaluationPlan.baseline,
        scoring: VoiceIDScoring,
        window: Double,
        condition: String = VoiceIDEvaluationPlan.pooled
    ) -> VoiceIDEvaluationMetrics? {
        metrics.first {
            $0.preprocessor == preprocessor && $0.scoring == scoring && abs($0.window - window) < 1e-9
                && $0.condition == condition
        }
    }

    /// Scoring methods in the order they were measured.
    public var scorings: [VoiceIDScoring] {
        var seen: [VoiceIDScoring] = []
        for entry in metrics where !seen.contains(entry.scoring) { seen.append(entry.scoring) }
        return seen
    }

    /// The JSON encoding (sorted keys, pretty-printed), for storing a run.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: Markdown

    /// The report as Markdown: the proposed thresholds, then EER and fixed
    /// operating points by window, scoring, condition and preprocessor, then
    /// the decision breakdown at the proposed thresholds.
    public func markdown() -> String {
        var lines: [String] = []
        func table(_ header: [String], _ alignRight: [Bool], _ rows: [[String]]) {
            lines.append("| " + header.joined(separator: " | ") + " |")
            lines.append("| " + alignRight.map { $0 ? "---:" : "---" }.joined(separator: " | ") + " |")
            lines += rows.map { "| " + $0.joined(separator: " | ") + " |" }
            lines.append("")
        }

        lines += [
            "# Voice ID evaluation: \(dataset)",
            "",
            "- Date: \(date)",
            "- Model: `\(modelIdentifier)`",
            "- Consent / licence: \(consent)",
            "- Target speakers: \(targetSpeakers) (\(enrollmentRecordings) enrollment clips)",
            "- Probe recordings: \(probeRecordings) ("
                + probeSources.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")",
            "- AS-norm cohort: \(cohortSize) embeddings",
            "- Preprocessors: \(preprocessors.joined(separator: ", "))",
        ]
        if !skippedConditions.isEmpty {
            lines.append("- Skipped conditions (no cohort talkers): \(skippedConditions.joined(separator: ", "))")
        }
        if !skippedScorings.isEmpty {
            lines.append("- Skipped scoring methods (no cohort): \(skippedScorings.joined(separator: ", "))")
        }
        lines.append("")

        // Thresholds.
        let targets = calibration.targets
        lines += [
            "## Proposed thresholds",
            "",
            "Scoring `\(calibration.scoring)`, every condition pooled. `T_hi` is the lowest threshold with FAR <= "
                + "\(Self.percent(targets.maximumFalseAcceptRate)), `T_lo` the highest with FRR <= "
                + "\(Self.percent(targets.maximumFalseRejectRate)), rounded outward to 0.01.",
            "",
        ]
        table(
            [
                "Window", "T_hi", "T_lo", "FAR at T_hi", "FRR at T_hi", "FRR at T_lo", "FAR at T_lo",
                "Owner uncertain", "Impostor uncertain", "Trials (owner / impostor)",
            ],
            [false] + [Bool](repeating: true, count: 9),
            [(calibration.short, histograms.first?.window), (calibration.long, histograms.last?.window)]
                .map { calibrated, window in
                    [
                        window.map(Self.seconds) ?? "–",
                        Self.score(calibrated.thresholds.accept), Self.score(calibrated.thresholds.reject),
                        "\(Self.percent(calibrated.atAccept.falseAcceptRate)) (\(calibrated.falseAccepts))",
                        Self.percent(calibrated.atAccept.falseRejectRate),
                        "\(Self.percent(calibrated.atReject.falseRejectRate)) (\(calibrated.falseRejects))",
                        Self.percent(calibrated.atReject.falseAcceptRate),
                        Self.percent(calibrated.targetUncertainRate),
                        Self.percent(calibrated.nonTargetUncertainRate),
                        "\(calibrated.targetCount) / \(calibrated.nonTargetCount)",
                    ]
                }
        )
        lines += [
            "Counts in brackets are the errors behind the rate; fewer than about 30 makes it a rough estimate.",
            "",
            "```swift",
            "short: VoiceIDThresholds(accept: \(Self.score(calibration.config.short.accept)), "
                + "reject: \(Self.score(calibration.config.short.reject))),",
            "long: VoiceIDThresholds(accept: \(Self.score(calibration.config.long.accept)), "
                + "reject: \(Self.score(calibration.config.long.reject))),",
            "```",
            "",
        ]

        // EER by window and scoring.
        for preprocessor in preprocessors {
            let suffix = preprocessors.count > 1 ? " (preprocessor: \(preprocessor))" : ""
            lines += ["## Equal error rate by window\(suffix)", "", "Every condition pooled.", ""]
            table(
                ["Scoring"] + windows.map(Self.seconds), [false] + windows.map { _ in true },
                scorings.map { scoring in
                    [scoring.description]
                        + windows.map { window in
                            metrics(preprocessor: preprocessor, scoring: scoring, window: window).map {
                                Self.percent($0.equalErrorRate)
                            } ?? "–"
                        }
                }
            )
            lines += ["## Operating points\(suffix)", "", "Every condition pooled.", ""]
            table(
                ["Scoring", "Window", "EER", "EER threshold"]
                    + reportedFalseRejectRates.map { "FAR @ FRR <= \(Self.percent($0))" }
                    + reportedFalseAcceptRates.map { "FRR @ FAR <= \(Self.percent($0))" }
                    + ["Trials (owner / impostor)"],
                [false, false]
                    + [Bool](
                        repeating: true, count: 3 + reportedFalseRejectRates.count + reportedFalseAcceptRates.count),
                scorings.flatMap { scoring in
                    windows.compactMap { window in
                        metrics(preprocessor: preprocessor, scoring: scoring, window: window).map { entry in
                            [
                                scoring.description, Self.seconds(window), Self.percent(entry.equalErrorRate),
                                Self.score(entry.equalErrorThreshold),
                            ]
                                + entry.atFixedFalseRejectRates.map { Self.percent($0.falseAcceptRate) }
                                + entry.atFixedFalseAcceptRates.map { Self.percent($0.falseRejectRate) }
                                + ["\(entry.targetTrials) / \(entry.nonTargetTrials)"]
                        }
                    }
                }
            )
        }

        // By condition.
        lines += [
            "## Equal error rate by condition",
            "",
            "Scoring `\(calibration.scoring)`, no preprocessing. Conditions without owner trials (loudspeaker) "
                + "have no EER; see the decision breakdown.",
            "",
        ]
        table(
            ["Condition"] + windows.map(Self.seconds), [false] + windows.map { _ in true },
            conditions.map { condition in
                [condition.name]
                    + windows.map { window in
                        metrics(scoring: calibration.scoring, window: window, condition: condition.name).map {
                            Self.percent($0.equalErrorRate)
                        } ?? "–"
                    }
            }
        )
        table(
            ["Condition", "What it simulates"], [false, false],
            conditions.map { [$0.name, $0.summary] }
        )

        // Preprocessor comparison.
        if preprocessors.count > 1 {
            lines += ["## Preprocessors", "", "EER, scoring `\(calibration.scoring)`, by condition.", ""]
            for window in windows {
                table(
                    ["Condition (\(Self.seconds(window)))"] + preprocessors, [false] + preprocessors.map { _ in true },
                    ([VoiceIDEvaluationPlan.pooled] + conditions.map(\.name)).map { condition in
                        [condition]
                            + preprocessors.map { preprocessor in
                                metrics(
                                    preprocessor: preprocessor, scoring: calibration.scoring, window: window,
                                    condition: condition
                                ).map { Self.percent($0.equalErrorRate) } ?? "–"
                            }
                    }
                )
            }
        }

        // Decisions.
        lines += [
            "## Decisions at the proposed thresholds",
            "",
            "Share of trials accepted / uncertain / rejected. Owner trials should be accepted; impostor accepts "
                + "are false accepts. Groups: `all`, the probe's `source`, and any manifest tags.",
            "",
        ]
        for window in Set(decisions.map(\.window)).sorted() {
            let rows = decisions.filter { $0.window == window }
            table(
                ["Window", "Condition", "Group", "Trials", "Count", "Accept", "Uncertain", "Reject"],
                [false, false, false, false, true, true, true, true],
                rows.map { row in
                    [
                        Self.seconds(window), row.condition, row.group,
                        row.trials == .target ? "owner" : "impostor", "\(row.total)",
                        Self.percent(row.rate(.accept)), Self.percent(row.rate(.uncertain)),
                        Self.percent(row.rate(.reject)),
                    ]
                }
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    static func percent(_ value: Double) -> String {
        if value == 0 { return "0%" }
        if value < 0.001 { return String(format: "%.3f%%", value * 100) }
        if value < 0.1 { return String(format: "%.2f%%", value * 100) }
        return String(format: "%.1f%%", value * 100)
    }

    static func score(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f s", value) : String(format: "%.1f s", value)
    }
}
