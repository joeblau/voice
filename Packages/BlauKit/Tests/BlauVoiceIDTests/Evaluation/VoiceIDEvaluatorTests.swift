import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Voice ID evaluation harness")
struct VoiceIDEvaluatorTests {
    let evaluator = VoiceIDEvaluator(embedder: BandEnergyEmbedder())

    /// 1, 1.5 and 3 s windows (the synthetic probes are 3.2 s long), every
    /// standard condition, the three scoring methods.
    var plan: VoiceIDEvaluationPlan {
        VoiceIDEvaluationPlan(
            windows: [SpeakerEmbeddingWindow(duration: .seconds(1)), .short, .long],
            scorings: [
                .cosineCentroid, .cosineBestMatch,
                VoiceIDScoring(comparison: .centroid, normalization: .asNorm(topK: 5)),
            ]
        )
    }

    @Test func measuresEverySliceAndCalibrates() async throws {
        let dataset = try syntheticDataset()
        let report = try await evaluator.run(dataset, plan: plan, date: "2026-10-07")

        #expect(report.dataset == "synthetic")
        #expect(report.modelIdentifier == "band-energy@test")
        #expect(report.targetSpeakers == 5)
        #expect(report.probeRecordings == 15)
        #expect(report.probeSources == ["person": 12, "tv": 3])
        #expect(report.cohortSize == 12)
        #expect(report.windows == [1, 1.5, 3])
        #expect(report.skippedConditions.isEmpty && report.skippedScorings.isEmpty)
        #expect(report.preprocessors == [VoiceIDEvaluationPlan.baseline])

        // Pooled plus every condition with both kinds of trial (loudspeaker
        // has no target trials), for every scoring and window.
        let conditionsWithEER = VoiceIDCondition.standard.filter(\.scoresTargetTrials).count
        #expect(report.metrics.count == 3 * 3 * (conditionsWithEER + 1))
        for scoring in plan.scorings {
            for window in report.windows {
                let pooled = try #require(report.metrics(scoring: scoring, window: window))
                // 15 probes × 5 targets, 3 owner trials per target; loudspeaker
                // adds only non-target trials.
                #expect(pooled.targetTrials == 15 * conditionsWithEER)
                #expect(pooled.nonTargetTrials == 60 * VoiceIDCondition.standard.count)
                #expect((0...0.5).contains(pooled.equalErrorRate))
                #expect(pooled.atFixedFalseRejectRates.count == 2 && pooled.atFixedFalseAcceptRates.count == 2)
                #expect(!pooled.curve.isEmpty)
            }
        }
        #expect(report.metrics(scoring: .cosineCentroid, window: 3, condition: "loudspeaker") == nil)
        // Clean synthetic voices separate well; the fake model is no WeSpeaker.
        let clean = try #require(report.metrics(scoring: .cosineCentroid, window: 3, condition: "clean"))
        print("[test] band-energy EER, clean, 3 s: \(clean.equalErrorRate)")
        #expect(clean.equalErrorRate < 0.2)

        // The proposal is for the embedder's model and the plan's method.
        let config = report.calibration.config
        #expect(config.modelIdentifier == "band-energy@test")
        #expect(config.scoring == .cosineCentroid)
        #expect(config.calibration?.date == "2026-10-07")
        #expect(config.short.reject <= config.short.accept && config.long.reject <= config.long.accept)
        #expect(
            report.calibration.short.atAccept.falseAcceptRate
                <= VoiceIDCalibrationTargets.standard.maximumFalseAcceptRate)
        #expect(
            report.calibration.long.atReject.falseRejectRate
                <= VoiceIDCalibrationTargets.standard.maximumFalseRejectRate)
        #expect(report.histograms.map(\.window) == [1.5, 3])
    }

    @Test func decisionBreakdownCountsEveryTrialOnce() async throws {
        let report = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        for window in [1.5, 3.0] {
            let all = report.decisions.filter { $0.window == window && $0.condition == "all" && $0.group == "all" }
            let owner = try #require(all.first { $0.trials == .target })
            let impostor = try #require(all.first { $0.trials == .nonTarget })
            let pooled = try #require(report.metrics(scoring: .cosineCentroid, window: window))
            #expect(owner.total == pooled.targetTrials)
            #expect(impostor.total == pooled.nonTargetTrials)
            // Groups split the same trials.
            let sources = report.decisions.filter {
                $0.window == window && $0.condition == "all" && $0.group.hasPrefix("source=") && $0.trials == .nonTarget
            }
            #expect(sources.map(\.total).reduce(0, +) == impostor.total)
            let rooms = report.decisions.filter {
                $0.window == window && $0.condition == "all" && $0.group.hasPrefix("room=") && $0.trials == .target
            }
            #expect(Set(rooms.map(\.group)) == ["room=kitchen", "room=office"])
            #expect(rooms.map(\.total).reduce(0, +) == owner.total)
            // The calibrated FAR at T_hi is the pooled impostor accept rate.
            let calibrated = window == 1.5 ? report.calibration.short : report.calibration.long
            #expect(abs(impostor.rate(.accept) - calibrated.atAccept.falseAcceptRate) < 1e-12)
            #expect(abs(owner.rate(.reject) - calibrated.atReject.falseRejectRate) < 1e-12)
            #expect(abs(owner.rate(.uncertain) - calibrated.targetUncertainRate) < 1e-12)
        }
        // No owner trials under loudspeaker.
        #expect(!report.decisions.contains { $0.condition == "loudspeaker" && $0.trials == .target })
        #expect(report.decisions.contains { $0.condition == "loudspeaker" && $0.trials == .nonTarget })
    }

    /// The gate simulation (#47) decides every probe once per target and
    /// condition, from its longest score: here the 3 s window, so it agrees
    /// with the 3 s decision breakdown.
    @Test func gateOutcomesDecideEveryProbeOnceFromItsLongestScore() async throws {
        let report = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        let gate = try #require(report.gate)
        for trials in [VoiceIDDecisionBreakdown.TrialKind.target, .nonTarget] {
            let outcome = try #require(gate.first { $0.condition == "all" && $0.trials == trials })
            let atThreeSeconds = try #require(
                report.decisions.first {
                    $0.window == 3 && $0.condition == "all" && $0.group == "all" && $0.trials == trials
                })
            #expect(outcome.total == atThreeSeconds.total)
            #expect(outcome.accepted == atThreeSeconds.accepted)
            #expect(outcome.uncertain == atThreeSeconds.uncertain)
            #expect(outcome.rejected == atThreeSeconds.rejected)
            #expect(outcome.unscored == 0)
        }
        // Every condition, owner trials only where they exist.
        #expect(!gate.contains { $0.condition == "loudspeaker" && $0.trials == .target })
        #expect(gate.contains { $0.condition == "loudspeaker" && $0.trials == .nonTarget })
        #expect(report.markdown().contains("## The verification gate"))
    }

    @Test func gateOutcomeRates() {
        let owner = VoiceIDGateOutcome(
            condition: "all", trials: .target, accepted: 90, uncertain: 7, rejected: 2, unscored: 1)
        #expect(owner.total == 100)
        #expect(owner.falseRejectRate == 0.02)
        #expect(owner.falseRejectRateDroppingUncertain == 0.10)
        let impostor = VoiceIDGateOutcome(
            condition: "all", trials: .nonTarget, accepted: 1, uncertain: 4, rejected: 195, unscored: 0)
        #expect(impostor.falseAcceptRate == 0.005)
        #expect(impostor.falseAcceptRateSendingUncertain == 0.025)
    }

    @Test func withoutACohortSkipsASNormAndTalkerConditions() async throws {
        let dataset = try syntheticDataset(cohort: 0)
        let report = try await evaluator.run(dataset, plan: plan, date: "d")
        #expect(report.cohortSize == 0)
        #expect(report.skippedConditions == ["babble", "overlap"])
        #expect(report.skippedScorings == ["as-norm(5)/centroid"])
        #expect(report.scorings == [.cosineCentroid, .cosineBestMatch])
        #expect(!report.conditions.contains { $0.needsInterferers })
    }

    @Test func calibratingWithAnUnavailableMethodFails() async throws {
        var plan = plan
        plan.calibrationScoring = .asNormCentroid
        plan.scorings = [.cosineCentroid]
        await #expect(throws: VoiceIDEvaluationError.self) {
            try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        }
        var missingWindow = self.plan
        missingWindow.windows = [.short]
        await #expect(throws: VoiceIDEvaluationError.self) {
            try await evaluator.run(try syntheticDataset(), plan: missingWindow, date: "d")
        }
    }

    @Test func probesOnlyFillWindowsTheyCover() async throws {
        // 2 s probes: no 3 s trials, so no long-window calibration.
        await #expect(
            throws: VoiceIDEvaluationError.cannotCalibrate("Need target and non-target trials at 1.5 s and 3.0 s")
        ) {
            try await evaluator.run(try syntheticDataset(probeSeconds: 2), plan: plan, date: "d")
        }
    }

    @Test func comparesPreprocessorsWithTheBaseline() async throws {
        var plan = plan
        plan.preprocessors = [HalfGainPreprocessor()]
        plan.conditions = [.clean, .roomFar]
        let report = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        #expect(report.preprocessors == ["none", "half-gain"])
        let baseline = try #require(report.metrics(preprocessor: "none", scoring: .cosineCentroid, window: 3))
        let processed = try #require(report.metrics(preprocessor: "half-gain", scoring: .cosineCentroid, window: 3))
        // Level doesn't change a band-energy direction much.
        #expect(abs(baseline.equalErrorRate - processed.equalErrorRate) < 0.1)
        #expect(report.markdown().contains("## Preprocessors"))

        plan.preprocessors = [WrongRatePreprocessor()]
        await #expect(throws: VoiceIDEvaluationError.preprocessorChangedSampleRate("wrong-rate")) {
            try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        }
    }

    @Test func shortEnrollmentClipsAreReported() async throws {
        let dataset = try VoiceIDEvaluationDataset(
            name: "short", consent: "test",
            recordings: [
                VoiceIDEvaluationRecording(
                    id: "a/enroll", speaker: "a", role: .enrollment,
                    audio: syntheticVoice(pitch: 200, seconds: 0.3, variant: 0)),
                VoiceIDEvaluationRecording(
                    id: "a/probe", speaker: "a", role: .probe, audio: syntheticVoice(pitch: 200, seconds: 3, variant: 1)
                ),
            ])
        await #expect(throws: VoiceIDEvaluationError.recordingTooShort("a/enroll")) {
            try await evaluator.run(dataset, plan: plan, date: "d")
        }
    }

    @Test func runsAreReproducible() async throws {
        var plan = plan
        plan.conditions = [.roomFar, .babble]
        let first = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        let second = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        #expect(first == second)
        plan.seed = 99
        let reseeded = try await evaluator.run(try syntheticDataset(), plan: plan, date: "d")
        #expect(reseeded.metrics != first.metrics)
    }

    @Test func reportRendersAndRoundTrips() async throws {
        let report = try await evaluator.run(try syntheticDataset(), plan: plan, date: "2026-10-07")

        let decoded = try JSONDecoder().decode(VoiceIDEvaluationReport.self, from: report.json())
        #expect(decoded == report)

        let markdown = report.markdown()
        for heading in [
            "# Voice ID evaluation: synthetic", "## Proposed thresholds", "## Equal error rate by window",
            "## Operating points", "## Equal error rate by condition", "## Decisions at the proposed thresholds",
        ] {
            #expect(markdown.contains(heading), "\(heading)")
        }
        #expect(markdown.contains("FAR @ FRR <= 1.00%"))
        #expect(markdown.contains("short: VoiceIDThresholds(accept: "))
        #expect(!markdown.contains("## Preprocessors"))

        let svgs = [
            VoiceIDEvaluationPlots.detByWindow(report), VoiceIDEvaluationPlots.detByScoring(report),
            VoiceIDEvaluationPlots.detByCondition(report, window: 1.5),
            VoiceIDEvaluationPlots.histogram(report.histograms[0], title: "Scores <1.5 s> & \"T\""),
        ]
        for svg in svgs {
            #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
            #expect(SVGChecker.isWellFormed(svg))
            #expect(svg.contains("<polyline") || svg.contains("T_hi"))
        }
        #expect(svgs[3].contains("&lt;1.5 s&gt; &amp; &quot;T&quot;"))
    }

    @Test func histogramCountsEveryScore() {
        let scores = VoiceIDScores(target: [0.61, 0.7, 0.95], nonTarget: [-0.1, 0.05, 0.05, 0.3])
        let histogram = VoiceIDScoreHistogram(
            window: .short, scores: scores, thresholds: VoiceIDThresholds(accept: 0.5, reject: 0.2))
        #expect(histogram.targetCounts.reduce(0, +) == 3)
        #expect(histogram.nonTargetCounts.reduce(0, +) == 4)
        #expect(abs(histogram.lowerBound - -0.1) < 1e-6)
        #expect(histogram.targetCounts.count == histogram.nonTargetCounts.count)
        #expect(histogram.window == 1.5)
    }
}

/// Parses SVG text as XML.
enum SVGChecker {
    static func isWellFormed(_ svg: String) -> Bool {
        XMLParser(data: Data(svg.utf8)).parse()
    }
}
