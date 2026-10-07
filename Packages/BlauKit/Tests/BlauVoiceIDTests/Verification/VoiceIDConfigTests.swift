import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Voice ID config")
struct VoiceIDConfigTests {
    let thresholds = VoiceIDThresholds(accept: 0.5, reject: 0.3)

    @Test func scoresFallIntoThreeBands() {
        #expect(thresholds.decision(for: 0.5) == .accept)
        #expect(thresholds.decision(for: 0.9) == .accept)
        #expect(thresholds.decision(for: 0.49) == .uncertain)
        #expect(thresholds.decision(for: 0.3) == .uncertain)
        #expect(thresholds.decision(for: 0.29) == .reject)
        #expect(thresholds.decision(for: -1) == .reject)
        #expect(abs(thresholds.uncertainWidth - 0.2) < 1e-6)
    }

    @Test func nonFiniteScoresAreNeverDecided() {
        #expect(thresholds.decision(for: .nan) == .uncertain)
    }

    @Test func equalThresholdsLeaveNoUncertainBand() {
        let sharp = VoiceIDThresholds(accept: 0.4, reject: 0.4)
        #expect(sharp.decision(for: 0.4) == .accept)
        #expect(sharp.decision(for: 0.399) == .reject)
    }

    @Test func windowPicksTheThresholds() {
        let config = VoiceIDConfig(
            modelIdentifier: "m", scoring: .cosineCentroid, short: VoiceIDThresholds(accept: 0.6, reject: 0.2),
            long: VoiceIDThresholds(accept: 0.5, reject: 0.3))
        #expect(config.longWindow == .seconds(3))
        #expect(config.thresholds(forAudioDuration: .milliseconds(1_500)) == config.short)
        #expect(config.thresholds(forAudioDuration: .milliseconds(2_999)) == config.short)
        #expect(config.thresholds(forAudioDuration: .seconds(3)) == config.long)
        #expect(config.thresholds(forAudioDuration: .seconds(10)) == config.long)
        #expect(config.decision(score: 0.55, audioDuration: .milliseconds(1_500)) == .uncertain)
        #expect(config.decision(score: 0.55, audioDuration: .seconds(3)) == .accept)
        #expect(config.decision(score: 0.25, audioDuration: .milliseconds(1_500)) == .uncertain)
        #expect(config.decision(score: 0.25, audioDuration: .seconds(3)) == .reject)
    }

    /// The committed thresholds: for the shipped model, ordered, calibrated
    /// to the standard budgets with the method the gate uses.
    @Test func calibratedConfigIsConsistent() {
        let config = VoiceIDConfig.calibrated
        #expect(config.applies(to: .weSpeakerResNet34LM))
        #expect(!config.applies(to: SpeakerEmbeddingModelInfo(identifier: "other", dimension: 256)))
        #expect(config.scoring == .cosineCentroid)
        #expect(config.longWindow == SpeakerEmbeddingWindow.long.duration)
        for thresholds in [config.short, config.long] {
            #expect(thresholds.reject <= thresholds.accept)
            #expect((-1...1).contains(thresholds.reject) && (-1...1).contains(thresholds.accept))
        }
        let calibration = config.calibration
        #expect(calibration?.maximumFalseAcceptRate == VoiceIDCalibrationTargets.standard.maximumFalseAcceptRate)
        #expect(calibration?.maximumFalseRejectRate == VoiceIDCalibrationTargets.standard.maximumFalseRejectRate)
        #expect(calibration?.date.isEmpty == false)
    }

    /// docs/voice-id-eval.md quotes the shipped thresholds; a change to one
    /// must change the other.
    @Test func committedThresholdsAreDocumented() throws {
        let doc = try String(contentsOf: RepoFiles.url("docs/voice-id-eval.md"), encoding: .utf8)
        let config = VoiceIDConfig.calibrated
        for (name, thresholds) in [("short", config.short), ("long", config.long)] {
            let line =
                "\(name): VoiceIDThresholds(accept: \(String(format: "%.2f", thresholds.accept)), "
                + "reject: \(String(format: "%.2f", thresholds.reject)))"
            #expect(doc.contains(line), "docs/voice-id-eval.md should contain `\(line)`")
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let config = VoiceIDConfig(
            modelIdentifier: "m", scoring: VoiceIDScoring(comparison: .bestMatch, normalization: .asNorm(topK: 50)),
            short: VoiceIDThresholds(accept: 2.5, reject: 1), long: VoiceIDThresholds(accept: 2, reject: 1.5),
            calibration: VoiceIDCalibration(
                dataset: "d", date: "2026-10-07", maximumFalseAcceptRate: 0.01, maximumFalseRejectRate: 0.02))
        let decoded = try JSONDecoder().decode(VoiceIDConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        let calibrated = try JSONDecoder().decode(
            VoiceIDConfig.self, from: JSONEncoder().encode(VoiceIDConfig.calibrated))
        #expect(calibrated == .calibrated)
    }

    @Test func scoringDescriptions() {
        #expect(VoiceIDScoring.cosineCentroid.description == "cosine/centroid")
        #expect(VoiceIDScoring.cosineBestMatch.description == "cosine/bestMatch")
        #expect(VoiceIDScoring.asNormCentroid.description == "as-norm(100)/centroid")
        #expect(VoiceIDScoring.asNormCentroid.needsCohort)
        #expect(!VoiceIDScoring.cosineCentroid.needsCohort)
    }
}

@Suite("Voiceprint scoring and AS-norm")
struct VoiceprintScorerTests {
    func embedding(_ values: [Float], model: String = "m") -> SpeakerEmbedding {
        SpeakerEmbedding(normalizing: values, modelIdentifier: model, audioDuration: .seconds(3))!
    }

    @Test func centroidScoreIsCosineWithTheMean() throws {
        let enrollment = [embedding([1, 0, 0]), embedding([0, 1, 0])]
        let scorer = try VoiceprintScorer(enrollment: enrollment, scoring: .cosineCentroid)
        let probe = embedding([1, 1, 0])
        #expect(abs(scorer.score(probe) - 1) < 1e-6)
        #expect(abs(scorer.score(embedding([1, 0, 0])) - Float(0.5).squareRoot()) < 1e-6)
        #expect(scorer.score(embedding([0, 0, 1])) == 0)
    }

    @Test func bestMatchTakesTheClosestOfCentroidAndClips() throws {
        let enrollment = [embedding([1, 0, 0]), embedding([0, 1, 0])]
        let best = try VoiceprintScorer(enrollment: enrollment, scoring: .cosineBestMatch)
        let centroid = try VoiceprintScorer(enrollment: enrollment, scoring: .cosineCentroid)
        // Exactly one enrollment clip.
        #expect(abs(best.score(embedding([1, 0, 0])) - 1) < 1e-6)
        // Between the clips the centroid wins.
        #expect(abs(best.score(embedding([1, 1, 0])) - 1) < 1e-6)
        for probe in [embedding([1, 0.2, 0.3]), embedding([-1, 0.5, 0]), embedding([0, 0, 1])] {
            #expect(best.score(probe) >= centroid.score(probe))
        }
    }

    @Test func cohortStatisticsUseTheTopScores() throws {
        let cohort = try #require(
            SpeakerCohort(embeddings: [embedding([1, 0, 0]), embedding([0, 1, 0]), embedding([0, 0, 1])]))
        #expect(cohort.count == 3 && cohort.dimension == 3)
        let probe = embedding([3, 4, 0])  // (0.6, 0.8, 0)
        let scores = cohort.scores(probe)
        #expect(zip(scores, [Float(0.6), 0.8, 0]).allSatisfy { abs($0 - $1) < 1e-6 })
        let top2 = cohort.statistics(for: probe, topK: 2)
        #expect(abs(top2.mean - 0.7) < 1e-6)
        #expect(abs(top2.standardDeviation - 0.1) < 1e-6)
        // topK larger than the cohort uses all of it.
        let all = cohort.statistics(for: probe, topK: 10)
        #expect(abs(all.mean - Float(1.4 / 3)) < 1e-6)
    }

    @Test func asNormAveragesBothSidesZScores() throws {
        let enrollment = SpeakerCohort.Statistics(mean: 0.2, standardDeviation: 0.1)
        let probe = SpeakerCohort.Statistics(mean: 0.4, standardDeviation: 0.2)
        // ½ ((0.6 − 0.2) / 0.1 + (0.6 − 0.4) / 0.2) = ½ (4 + 1).
        #expect(abs(SpeakerCohort.asNorm(0.6, enrollment: enrollment, probe: probe) - 2.5) < 1e-5)
        // A degenerate cohort can't divide by zero.
        let flat = SpeakerCohort.Statistics(mean: 0.2, standardDeviation: 0)
        #expect(SpeakerCohort.asNorm(0.3, enrollment: flat, probe: flat).isFinite)
    }

    @Test func asNormScorerMatchesTheFormula() throws {
        let cohortEmbeddings = [embedding([1, 0, 0, 0]), embedding([0, 1, 0, 0]), embedding([1, 1, 1, 0])]
        let cohort = try #require(SpeakerCohort(embeddings: cohortEmbeddings))
        let enrollment = [embedding([0, 0, 1, 1]), embedding([0, 0.2, 1, 1])]
        let scoring = VoiceIDScoring(comparison: .centroid, normalization: .asNorm(topK: 2))
        let scorer = try VoiceprintScorer(enrollment: enrollment, scoring: scoring, cohort: cohort)
        let probe = embedding([0.1, 0, 1, 0.8])

        let raw = probe.cosineSimilarity(to: scorer.centroid)
        let expected = SpeakerCohort.asNorm(
            raw, enrollment: cohort.statistics(for: scorer.centroid, topK: 2),
            probe: cohort.statistics(for: probe, topK: 2))
        #expect(abs(scorer.rawScore(probe) - raw) < 1e-6)
        #expect(abs(scorer.score(probe) - expected) < 1e-5)
        #expect(scorer.probeStatistics(probe) == cohort.statistics(for: probe, topK: 2))
    }

    @Test func invalidSetupsThrow() throws {
        #expect(throws: VoiceprintScorer.Error.invalidEnrollment) {
            try VoiceprintScorer(enrollment: [], scoring: .cosineCentroid)
        }
        #expect(throws: VoiceprintScorer.Error.missingCohort) {
            try VoiceprintScorer(enrollment: [embedding([1, 0])], scoring: .asNormCentroid)
        }
        let otherModel = try #require(SpeakerCohort(embeddings: [embedding([1, 0], model: "other")]))
        #expect(throws: VoiceprintScorer.Error.cohortModelMismatch) {
            try VoiceprintScorer(enrollment: [embedding([1, 0])], scoring: .asNormCentroid, cohort: otherModel)
        }
        #expect(SpeakerCohort(embeddings: []) == nil)
        #expect(SpeakerCohort(embeddings: [embedding([1, 0]), embedding([1, 0], model: "other")]) == nil)
    }

    @Test func withoutNormalizationTheCohortIsIgnored() throws {
        let cohort = try #require(SpeakerCohort(embeddings: [embedding([1, 0])]))
        let scorer = try VoiceprintScorer(enrollment: [embedding([1, 1])], scoring: .cosineCentroid, cohort: cohort)
        #expect(scorer.probeStatistics(embedding([1, 0])) == nil)
        #expect(abs(scorer.score(embedding([1, 0])) - Float(0.5).squareRoot()) < 1e-6)
    }
}
