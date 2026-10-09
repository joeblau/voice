import BlauCore
import BlauTelemetry
import Foundation
import os

/// What an evaluation run measures.
public struct VoiceIDEvaluationPlan: Sendable {
    /// Windows scored from the start of each probe. A probe is only scored
    /// at windows it is long enough to fill.
    public var windows: [SpeakerEmbeddingWindow]
    /// Scoring methods to compare. Methods that need a cohort are skipped
    /// when the dataset has none.
    public var scorings: [VoiceIDScoring]
    /// Conditions applied to every probe. Conditions that need interfering
    /// talkers are skipped when the dataset has no cohort recordings.
    public var conditions: [VoiceIDCondition]
    /// Processing to compare against the unprocessed baseline, e.g. a noise
    /// suppressor. Applied to enrollment clips and probes alike.
    public var preprocessors: [any VoiceIDAudioPreprocessor]
    /// Enrollment clips per speaker (the first ones, by path).
    public var maximumEnrollmentClips: Int
    /// Enrollment clips are cut to this length (enrollment records 3-6 s).
    public var maximumEnrollmentDuration: Duration
    /// Cohort recordings are cut to this length.
    public var maximumCohortDuration: Duration
    /// The method the thresholds are calibrated for.
    public var calibrationScoring: VoiceIDScoring
    /// Error budgets for `T_hi` and `T_lo`.
    public var calibrationTargets: VoiceIDCalibrationTargets
    /// The window `VoiceIDConfig.short` is calibrated on.
    public var shortWindow: SpeakerEmbeddingWindow
    /// The window `VoiceIDConfig.long` is calibrated on.
    public var longWindow: SpeakerEmbeddingWindow
    /// FRR values at which the report gives the FAR.
    public var reportedFalseRejectRates: [Double]
    /// FAR values at which the report gives the FRR.
    public var reportedFalseAcceptRates: [Double]
    /// Seeds every simulated condition.
    public var seed: UInt64
    /// The verification gate whose decisions the report simulates (#47):
    /// each probe is one speech segment, decided by its longest window's
    /// score as the gate's end-of-segment score would.
    public var gate: VerificationGateConfiguration

    /// The windows the issue asks for: 1, 1.5, 3 and 6 s.
    public static let standardWindows: [SpeakerEmbeddingWindow] = [
        SpeakerEmbeddingWindow(duration: .seconds(1)), .short, .long, SpeakerEmbeddingWindow(duration: .seconds(6)),
    ]

    public init(
        windows: [SpeakerEmbeddingWindow] = VoiceIDEvaluationPlan.standardWindows,
        scorings: [VoiceIDScoring] = [.cosineCentroid, .cosineBestMatch, .asNormCentroid],
        conditions: [VoiceIDCondition] = VoiceIDCondition.standard,
        preprocessors: [any VoiceIDAudioPreprocessor] = [],
        maximumEnrollmentClips: Int = 5,
        maximumEnrollmentDuration: Duration = .seconds(6),
        maximumCohortDuration: Duration = .seconds(6),
        calibrationScoring: VoiceIDScoring = .cosineCentroid,
        calibrationTargets: VoiceIDCalibrationTargets = .standard,
        shortWindow: SpeakerEmbeddingWindow = .short,
        longWindow: SpeakerEmbeddingWindow = .long,
        reportedFalseRejectRates: [Double] = [0.01, 0.03],
        reportedFalseAcceptRates: [Double] = [0.01, 0.005],
        seed: UInt64 = 48,
        gate: VerificationGateConfiguration = .standard
    ) {
        precondition(!windows.isEmpty && !scorings.isEmpty && !conditions.isEmpty)
        precondition(maximumEnrollmentClips > 0)
        precondition(Set(conditions.map(\.name)).count == conditions.count, "Condition names must be unique")
        precondition(
            Set(preprocessors.map(\.name)).count == preprocessors.count
                && !preprocessors.contains { $0.name == VoiceIDEvaluationPlan.baseline },
            "Preprocessor names must be unique and not \(VoiceIDEvaluationPlan.baseline)")
        self.windows = windows.sorted()
        self.scorings = scorings
        self.conditions = conditions
        self.preprocessors = preprocessors
        self.maximumEnrollmentClips = maximumEnrollmentClips
        self.maximumEnrollmentDuration = maximumEnrollmentDuration
        self.maximumCohortDuration = maximumCohortDuration
        self.calibrationScoring = calibrationScoring
        self.calibrationTargets = calibrationTargets
        self.shortWindow = shortWindow
        self.longWindow = longWindow
        self.reportedFalseRejectRates = reportedFalseRejectRates
        self.reportedFalseAcceptRates = reportedFalseAcceptRates
        self.seed = seed
        self.gate = gate
    }

    /// The name of the unprocessed variant in reports.
    public static let baseline = "none"

    /// The name of the pooled condition in reports: every condition at once.
    public static let pooled = "all"
}

/// Why an evaluation couldn't finish.
public enum VoiceIDEvaluationError: Error, Hashable, Sendable {
    /// The thresholds can't be calibrated: the reason says what is missing.
    case cannotCalibrate(String)
    /// A preprocessor returned audio at another sample rate.
    case preprocessorChangedSampleRate(String)
    /// An enrollment clip or probe is shorter than the embedder accepts.
    case recordingTooShort(String)
}

/// Runs a speaker embedder over an evaluation set and measures how well its
/// scores separate the enrolled speakers from everyone and everything else:
/// DET curves, EER, FAR at a fixed FRR, for each window, condition, scoring
/// method and preprocessor; then calibrates `T_hi` and `T_lo` for the gate.
///
/// Each speaker with enrollment recordings is a target in turn. Every probe
/// is scored against every target's voiceprint: a target trial when the
/// probe is that speaker, a non-target trial otherwise. With one owner and
/// many impostor recordings that is the real setup; with a public corpus it
/// turns N speakers into N target sets.
///
/// See docs/voice-id-eval.md.
public struct VoiceIDEvaluator: Sendable {
    public let embedder: any SpeakerEmbedder

    public init(embedder: any SpeakerEmbedder) {
        self.embedder = embedder
    }

    /// One scored trial under the calibration method, kept for the decision
    /// breakdown.
    private struct Trial {
        let probe: Int
        let condition: Int
        let window: Int
        let target: Int
        let isTarget: Bool
        let score: Float
    }

    /// Embeddings of one probe under one condition, by window index (`nil`
    /// where the probe is too short for the window).
    private typealias ProbeEmbeddings = [SpeakerEmbedding?]

    /// Runs the plan.
    ///
    /// - Parameters:
    ///   - date: Recorded in the report and the proposed configuration
    ///     (ISO 8601 day, e.g. `2026-10-07`).
    ///   - progress: Called with a line of text as the run advances.
    public func run(
        _ dataset: VoiceIDEvaluationDataset,
        plan: VoiceIDEvaluationPlan = VoiceIDEvaluationPlan(),
        date: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> VoiceIDEvaluationReport {
        let report = { (line: String) in
            Log.voiceID.info("Evaluation: \(line, privacy: .public)")
            progress?(line)
        }
        let probes = dataset.recordings(.probe)
        let cohortRecordings = dataset.recordings(.cohort)
        let interferers = cohortRecordings.map(\.audio.samples)
        let conditions = plan.conditions.filter { !$0.needsInterferers || !interferers.isEmpty }
        let skippedConditions = plan.conditions.filter { $0.needsInterferers && interferers.isEmpty }.map(\.name)

        // The cohort: one embedding per cohort recording, unprocessed.
        report("embedding \(cohortRecordings.count) cohort recordings")
        let cohortEmbeddings = try await embed(
            cohortRecordings.map { prefix($0.audio, plan.maximumCohortDuration) }, ids: cohortRecordings.map(\.id))
        let cohort = SpeakerCohort(embeddings: cohortEmbeddings)
        let scorings = plan.scorings.filter { !$0.needsCohort || cohort != nil }
        let skippedScorings = plan.scorings.filter { $0.needsCohort && cohort == nil }.map(\.description)

        guard scorings.contains(plan.calibrationScoring) else {
            throw VoiceIDEvaluationError.cannotCalibrate(
                "The calibration method \(plan.calibrationScoring) can't run on this dataset")
        }
        guard let shortIndex = plan.windows.firstIndex(of: plan.shortWindow),
            let longIndex = plan.windows.firstIndex(of: plan.longWindow)
        else {
            throw VoiceIDEvaluationError.cannotCalibrate("The plan must score the short and long windows")
        }

        let variants: [(name: String, processor: (any VoiceIDAudioPreprocessor)?)] =
            [(VoiceIDEvaluationPlan.baseline, nil)] + plan.preprocessors.map { ($0.name, $0) }
        var metrics: [VoiceIDEvaluationMetrics] = []
        var calibrationTrials: [Trial] = []

        for variant in variants {
            // Enrollment: clean clips (enrollment is guided, in a quiet place).
            var voiceprints: [String: [SpeakerEmbedding]] = [:]
            for speaker in dataset.targetSpeakers {
                let clips = dataset.recordings(.enrollment)
                    .filter { $0.speaker == speaker }
                    .sorted { $0.id < $1.id }
                    .prefix(plan.maximumEnrollmentClips)
                var audio: [AudioFrame] = []
                for clip in clips {
                    audio.append(
                        try await process(prefix(clip.audio, plan.maximumEnrollmentDuration), variant.processor))
                }
                voiceprints[speaker] = try await embed(audio, ids: clips.map(\.id))
            }

            // Probes: every condition, every window the probe fills.
            let longest = plan.windows[plan.windows.count - 1].duration
            var embeddings = [[ProbeEmbeddings]](
                repeating: [ProbeEmbeddings](repeating: [], count: probes.count), count: conditions.count)
            for (conditionIndex, condition) in conditions.enumerated() {
                report("\(variant.name): embedding \(probes.count) probes under \(condition.name)")
                for (probeIndex, probe) in probes.enumerated() {
                    try Task.checkCancellation()
                    // Enough audio for the longest window, plus room for a
                    // reverberation tail to build up.
                    let source = prefix(probe.audio, longest + .milliseconds(500))
                    let seed = EvaluationDSP.stableHash(String(plan.seed), condition.name, probe.id)
                    guard
                        let degraded = condition.apply(to: source.samples, seed: seed, interferers: interferers)
                    else { continue }
                    let audio = try await process(AudioFrame(samples: degraded, sampleOffset: 0), variant.processor)
                    let fitting = plan.windows.filter { $0.duration <= probe.audio.duration }
                    let vectors = try await embed(
                        fitting.map { $0.prefix(of: audio) }, ids: fitting.map { _ in probe.id })
                    embeddings[conditionIndex][probeIndex] = plan.windows.map { window in
                        fitting.firstIndex(of: window).map { vectors[$0] }
                    }
                }
            }

            // Scores.
            for scoring in scorings {
                report("\(variant.name): scoring \(scoring)")
                let scorers = try dataset.targetSpeakers.map { speaker in
                    try VoiceprintScorer(enrollment: voiceprints[speaker] ?? [], scoring: scoring, cohort: cohort)
                }
                var scores = [[VoiceIDScores]](
                    repeating: [VoiceIDScores](repeating: VoiceIDScores(), count: plan.windows.count),
                    count: conditions.count)
                let keepTrials = variant.processor == nil && scoring == plan.calibrationScoring
                for (conditionIndex, condition) in conditions.enumerated() {
                    for (probeIndex, probe) in probes.enumerated() {
                        for (windowIndex, embedding) in embeddings[conditionIndex][probeIndex].enumerated() {
                            guard let embedding else { continue }
                            let probeStatistics = scorers[0].probeStatistics(embedding)
                            for (targetIndex, scorer) in scorers.enumerated() {
                                let isTarget = probe.speaker == dataset.targetSpeakers[targetIndex]
                                if isTarget && !condition.scoresTargetTrials { continue }
                                let score = scorer.score(embedding, probeStatistics: probeStatistics)
                                if isTarget {
                                    scores[conditionIndex][windowIndex].target.append(score)
                                } else {
                                    scores[conditionIndex][windowIndex].nonTarget.append(score)
                                }
                                if keepTrials {
                                    calibrationTrials.append(
                                        Trial(
                                            probe: probeIndex, condition: conditionIndex, window: windowIndex,
                                            target: targetIndex, isTarget: isTarget, score: score))
                                }
                            }
                        }
                    }
                }
                for (windowIndex, window) in plan.windows.enumerated() {
                    var pooled = VoiceIDScores()
                    for (conditionIndex, condition) in conditions.enumerated() {
                        let set = scores[conditionIndex][windowIndex]
                        pooled.append(contentsOf: set)
                        if let entry = VoiceIDEvaluationMetrics(
                            preprocessor: variant.name, scoring: scoring, window: window, condition: condition.name,
                            scores: set, plan: plan)
                        {
                            metrics.append(entry)
                        }
                    }
                    if let entry = VoiceIDEvaluationMetrics(
                        preprocessor: variant.name, scoring: scoring, window: window,
                        condition: VoiceIDEvaluationPlan.pooled, scores: pooled, plan: plan)
                    {
                        metrics.append(entry)
                    }
                }
            }
        }

        // Calibration on the baseline, pooled over every condition.
        func pooledScores(window: Int) -> VoiceIDScores {
            var scores = VoiceIDScores()
            for trial in calibrationTrials where trial.window == window {
                if trial.isTarget { scores.target.append(trial.score) } else { scores.nonTarget.append(trial.score) }
            }
            return scores
        }
        let shortScores = pooledScores(window: shortIndex)
        let longScores = pooledScores(window: longIndex)
        guard shortScores.isComplete, longScores.isComplete else {
            throw VoiceIDEvaluationError.cannotCalibrate(
                "Need target and non-target trials at \(plan.shortWindow.seconds) s and \(plan.longWindow.seconds) s")
        }
        let short = VoiceIDThresholdCalibrator.calibrate(shortScores, targets: plan.calibrationTargets)
        let long = VoiceIDThresholdCalibrator.calibrate(longScores, targets: plan.calibrationTargets)
        let config = VoiceIDConfig(
            modelIdentifier: embedder.model.identifier,
            scoring: plan.calibrationScoring,
            short: short.thresholds,
            long: long.thresholds,
            longWindow: plan.longWindow.duration,
            calibration: VoiceIDCalibration(
                dataset: dataset.name, date: date,
                maximumFalseAcceptRate: plan.calibrationTargets.maximumFalseAcceptRate,
                maximumFalseRejectRate: plan.calibrationTargets.maximumFalseRejectRate)
        )

        let decisions = Self.decisionBreakdown(
            calibrationTrials, probes: probes, conditions: conditions,
            windows: [(shortIndex, plan.shortWindow, short.thresholds), (longIndex, plan.longWindow, long.thresholds)])
        let longest = plan.windows[plan.windows.count - 1].duration + .milliseconds(500)
        let gate = Self.gateOutcomes(
            calibrationTrials, windows: plan.windows,
            speech: probes.map { min($0.audio.duration, longest) }, conditions: conditions, config: config,
            gate: plan.gate)
        let histograms = [
            VoiceIDScoreHistogram(window: plan.shortWindow, scores: shortScores, thresholds: short.thresholds),
            VoiceIDScoreHistogram(window: plan.longWindow, scores: longScores, thresholds: long.thresholds),
        ]
        report("done: \(metrics.count) result sets")

        return VoiceIDEvaluationReport(
            dataset: dataset.name,
            consent: dataset.consent,
            date: date,
            modelIdentifier: embedder.model.identifier,
            targetSpeakers: dataset.targetSpeakers.count,
            enrollmentRecordings: dataset.recordings(.enrollment).count,
            probeRecordings: probes.count,
            probeSources: Dictionary(grouping: probes, by: \.source.rawValue).mapValues(\.count),
            cohortSize: cohortEmbeddings.count,
            windows: plan.windows.map(\.seconds),
            conditions: conditions,
            skippedConditions: skippedConditions,
            skippedScorings: skippedScorings,
            preprocessors: variants.map(\.name),
            reportedFalseRejectRates: plan.reportedFalseRejectRates,
            reportedFalseAcceptRates: plan.reportedFalseAcceptRates,
            metrics: metrics,
            calibration: VoiceIDEvaluationReport.Calibration(
                scoring: plan.calibrationScoring, targets: plan.calibrationTargets, short: short, long: long,
                config: config),
            decisions: decisions,
            histograms: histograms,
            gate: gate
        )
    }

    // MARK: Helpers

    private func embed(_ audio: [AudioFrame], ids: [String]) async throws -> [SpeakerEmbedding] {
        guard !audio.isEmpty else { return [] }
        for (frame, id) in zip(audio, ids) where frame.duration < embedder.minimumDuration {
            throw VoiceIDEvaluationError.recordingTooShort(id)
        }
        return try await embedder.embed(audio)
    }

    private func process(
        _ audio: AudioFrame, _ processor: (any VoiceIDAudioPreprocessor)?
    ) async throws -> AudioFrame {
        guard let processor else { return audio }
        let processed = try await processor.process(audio)
        guard processed.sampleRate == AudioFrame.captureSampleRate else {
            throw VoiceIDEvaluationError.preprocessorChangedSampleRate(processor.name)
        }
        return processed
    }

    private func prefix(_ audio: AudioFrame, _ duration: Duration) -> AudioFrame {
        SpeakerEmbeddingWindow(duration: duration).prefix(of: audio)
    }

    /// The verification gate's decision on every trial, simulated: each
    /// probe is one speech segment of `speech[probe]`, scored at every
    /// window it fills, and the longest score decides with `config`'s
    /// thresholds (``VerificationGateRules/simulatedDecision(scores:speechDuration:config:gate:)``).
    /// By condition, and pooled.
    private static func gateOutcomes(
        _ trials: [Trial],
        windows: [SpeakerEmbeddingWindow],
        speech: [Duration],
        conditions: [VoiceIDCondition],
        config: VoiceIDConfig,
        gate: VerificationGateConfiguration
    ) -> [VoiceIDGateOutcome] {
        struct Key: Hashable {
            let probe: Int
            let condition: Int
            let target: Int
        }
        var scores: [Key: (isTarget: Bool, scores: [(audioDuration: Duration, score: Float)])] = [:]
        for trial in trials {
            let key = Key(probe: trial.probe, condition: trial.condition, target: trial.target)
            scores[key, default: (trial.isTarget, [])].scores.append((windows[trial.window].duration, trial.score))
        }
        var counts: [String: [Bool: [SpeakerDecision?: Int]]] = [:]
        for (key, entry) in scores {
            let decision = VerificationGateRules.simulatedDecision(
                scores: entry.scores.sorted { $0.audioDuration < $1.audioDuration },
                speechDuration: speech[key.probe], config: config, gate: gate)
            for condition in [conditions[key.condition].name, VoiceIDEvaluationPlan.pooled] {
                counts[condition, default: [:]][entry.isTarget, default: [:]][decision, default: 0] += 1
            }
        }
        let order = [VoiceIDEvaluationPlan.pooled] + conditions.map(\.name)
        return order.flatMap { condition in
            [true, false].compactMap { isTarget -> VoiceIDGateOutcome? in
                guard let decisions = counts[condition]?[isTarget] else { return nil }
                return VoiceIDGateOutcome(
                    condition: condition, trials: isTarget ? .target : .nonTarget,
                    accepted: decisions[.accept, default: 0], uncertain: decisions[.uncertain, default: 0],
                    rejected: decisions[.reject, default: 0], unscored: decisions[nil, default: 0])
            }
        }
    }

    /// Accept / uncertain / reject counts at the calibrated thresholds, for
    /// owners and impostors, by condition and by probe source and tag.
    private static func decisionBreakdown(
        _ trials: [Trial],
        probes: [VoiceIDEvaluationRecording],
        conditions: [VoiceIDCondition],
        windows: [(index: Int, window: SpeakerEmbeddingWindow, thresholds: VoiceIDThresholds)]
    ) -> [VoiceIDDecisionBreakdown] {
        struct Key: Hashable {
            let window: Int
            let condition: String
            let group: String
            let isTarget: Bool
        }
        // A breakdown only says something when it splits the trials: skip
        // the source when every probe has the same one, and likewise tags.
        let splitsBySource = Set(probes.map(\.source)).count > 1
        var tagValues: [String: Set<String>] = [:]
        for probe in probes {
            for (key, value) in probe.tags { tagValues[key, default: []].insert(value) }
        }
        let splittingTags = Set(tagValues.filter { $0.value.count > 1 }.keys)
        var counts: [Key: [SpeakerDecision: Int]] = [:]
        for (index, _, thresholds) in windows {
            for trial in trials where trial.window == index {
                let decision = thresholds.decision(for: trial.score)
                let probe = probes[trial.probe]
                var groups = [VoiceIDEvaluationPlan.pooled]
                if splitsBySource { groups.append("source=\(probe.source.rawValue)") }
                groups += probe.tags.filter { splittingTags.contains($0.key) }.map { "\($0.key)=\($0.value)" }
                for condition in [conditions[trial.condition].name, VoiceIDEvaluationPlan.pooled] {
                    for group in groups {
                        counts[
                            Key(window: index, condition: condition, group: group, isTarget: trial.isTarget),
                            default: [:]][
                                decision, default: 0] += 1
                    }
                }
            }
        }
        let conditionOrder = [VoiceIDEvaluationPlan.pooled] + conditions.map(\.name)
        return counts.map { key, decisions in
            VoiceIDDecisionBreakdown(
                window: windows.first { $0.index == key.window }!.window.seconds,
                condition: key.condition,
                group: key.group,
                trials: key.isTarget ? .target : .nonTarget,
                accepted: decisions[.accept, default: 0],
                uncertain: decisions[.uncertain, default: 0],
                rejected: decisions[.reject, default: 0])
        }
        .sorted { lhs, rhs in
            let lhsKey = (lhs.window, conditionOrder.firstIndex(of: lhs.condition) ?? .max)
            let rhsKey = (rhs.window, conditionOrder.firstIndex(of: rhs.condition) ?? .max)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            if lhs.trials != rhs.trials { return lhs.trials == .target }
            if (lhs.group == VoiceIDEvaluationPlan.pooled) != (rhs.group == VoiceIDEvaluationPlan.pooled) {
                return lhs.group == VoiceIDEvaluationPlan.pooled
            }
            return lhs.group < rhs.group
        }
    }
}

extension SpeakerEmbeddingWindow {
    /// The window's length in seconds.
    public var seconds: Double { duration.timeInterval }
}
