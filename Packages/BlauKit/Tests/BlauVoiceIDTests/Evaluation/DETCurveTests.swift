import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("DET curve")
struct DETCurveTests {
    /// Targets 0.6 ... 0.9, one non-target (0.65) above the lowest target.
    let small = VoiceIDScores(target: [0.6, 0.7, 0.8, 0.9], nonTarget: [0.1, 0.2, 0.65, 0.3])

    @Test func ratesFollowTheAcceptRule() {
        let curve = DETCurve(small)
        // Accept when score >= threshold.
        #expect(
            curve.rates(at: 0.65)
                == VoiceIDOperatingPoint(threshold: 0.65, falseAcceptRate: 0.25, falseRejectRate: 0.25))
        #expect(curve.rates(at: 0.0).falseAcceptRate == 1)
        #expect(curve.rates(at: 0.0).falseRejectRate == 0)
        #expect(curve.rates(at: 1.0).falseAcceptRate == 0)
        #expect(curve.rates(at: 1.0).falseRejectRate == 1)
        #expect(curve.rates(at: 0.61).falseRejectRate == 0.25)
    }

    @Test func pointsRunFromAcceptAllToAcceptNone() {
        let curve = DETCurve(small)
        #expect(curve.points.first?.falseAcceptRate == 1)
        #expect(curve.points.first?.falseRejectRate == 0)
        #expect(curve.points.last?.falseAcceptRate == 0)
        #expect(curve.points.last?.falseRejectRate == 1)
        // One point per distinct score plus one past the top.
        #expect(curve.points.count == 9)
        for (before, after) in zip(curve.points, curve.points.dropFirst()) {
            #expect(before.threshold < after.threshold)
            #expect(before.falseAcceptRate >= after.falseAcceptRate)
            #expect(before.falseRejectRate <= after.falseRejectRate)
        }
    }

    @Test func equalErrorRateOfTheSmallSet() {
        let point = DETCurve(small).equalErrorPoint
        #expect(point.falseAcceptRate == 0.25)
        #expect(point.falseRejectRate == 0.25)
        #expect(point.threshold == 0.65)
    }

    @Test func separatedScoresHaveZeroEER() {
        let curve = DETCurve(VoiceIDScores(target: [0.7, 0.8], nonTarget: [0.1, 0.2, 0.3]))
        #expect(curve.equalErrorRate == 0)
        #expect(curve.falseAcceptRate(atFalseRejectRate: 0) == 0)
        #expect(curve.falseRejectRate(atFalseAcceptRate: 0) == 0)
    }

    @Test func equalErrorRateInterpolatesBetweenSteps() {
        // At 0.55 FAR = 1/2 and FRR = 1/3; at 0.6 FAR = 1/2 and FRR = 2/3.
        // FAR - FRR changes sign half way between them.
        let curve = DETCurve(VoiceIDScores(target: [0.5, 0.55, 0.9], nonTarget: [0.1, 0.6]))
        let point = curve.equalErrorPoint
        #expect(abs(point.falseAcceptRate - 0.5) < 1e-12)
        #expect(abs(point.threshold - 0.575) < 1e-6)
    }

    @Test func gaussianScoresMatchTheoreticalEER() {
        // Target N(2, 1) against non-target N(0, 1): EER = Φ(-1) ≈ 0.1587.
        var random = EvaluationDSP.Random(seed: 7)
        let target = (0..<20_000).map { _ in 2 + random.nextGaussian() }
        let nonTarget = (0..<20_000).map { _ in random.nextGaussian() }
        let curve = DETCurve(VoiceIDScores(target: target, nonTarget: nonTarget))
        #expect(abs(curve.equalErrorRate - 0.1587) < 0.01)
        #expect(abs(curve.equalErrorPoint.threshold - 1) < 0.05)
        // FAR at FRR 1%: threshold ≈ 2 - 2.326 = -0.326, FAR ≈ 1 - Φ(-0.326) ≈ 0.628.
        #expect(abs(curve.falseAcceptRate(atFalseRejectRate: 0.01) - 0.628) < 0.02)
    }

    @Test func thresholdsForTargetRates() {
        let curve = DETCurve(small)
        // Lowest threshold with FAR <= 25%: 0.3 still accepts 0.3 and 0.65
        // (50%); just above 0.3 only 0.65 remains.
        let accept = curve.threshold(forFalseAcceptRate: 0.25)
        #expect(accept.falseAcceptRate <= 0.25)
        #expect(accept.threshold == 0.6)
        // FAR 0 needs a threshold above 0.65.
        #expect(curve.threshold(forFalseAcceptRate: 0).threshold == 0.7)
        // Highest threshold with FRR <= 25%: 0.7 rejects only 0.6.
        let reject = curve.threshold(forFalseRejectRate: 0.25)
        #expect(reject.threshold == 0.7)
        #expect(reject.falseRejectRate == 0.25)
        #expect(curve.threshold(forFalseRejectRate: 0).threshold == 0.6)
    }

    @Test func tiedScoresCountOnBothSides() {
        let curve = DETCurve(VoiceIDScores(target: [0.5, 0.5, 0.9], nonTarget: [0.5, 0.1]))
        #expect(curve.rates(at: 0.5).falseAcceptRate == 0.5)
        #expect(curve.rates(at: 0.5).falseRejectRate == 0)
        #expect(curve.rates(at: Float(0.5).nextUp).falseRejectRate == 2.0 / 3.0)
    }

    @Test func thinnedPointsKeepTheEndsAndOrder() {
        var random = EvaluationDSP.Random(seed: 3)
        let curve = DETCurve(
            VoiceIDScores(
                target: (0..<5_000).map { _ in 1.5 + random.nextGaussian() },
                nonTarget: (0..<5_000).map { _ in random.nextGaussian() }))
        let thinned = curve.thinnedPoints(maximumCount: 50)
        #expect(thinned.count <= 51)
        #expect(thinned.count > 20)
        #expect(thinned.first == curve.points.first)
        #expect(thinned.last == curve.points.last)
        for (before, after) in zip(thinned, thinned.dropFirst()) {
            #expect(before.threshold < after.threshold)
        }
        // A short curve comes back whole.
        #expect(DETCurve(small).thinnedPoints(maximumCount: 50) == DETCurve(small).points)
    }

    @Test func probitIsTheInverseNormalCDF() {
        #expect(abs(Probit.deviate(0.5)) < 1e-9)
        #expect(abs(Probit.deviate(0.841_344_746) - 1) < 1e-6)
        #expect(abs(Probit.deviate(0.001) + 3.090_232) < 1e-5)
        #expect(abs(Probit.deviate(0.2) + Probit.deviate(0.8)) < 1e-9)
        // Clamped at the ends instead of infinite.
        #expect(Probit.deviate(0).isFinite)
        #expect(Probit.deviate(1).isFinite)
        #expect(Probit.deviate(0) < Probit.deviate(0.001))
    }
}

@Suite("Threshold calibration")
struct ThresholdCalibrationTests {
    @Test func roundsOutward() {
        #expect(VoiceIDThresholdCalibrator.roundUp(0.4321, step: 0.01) == Float(0.44))
        #expect(VoiceIDThresholdCalibrator.roundUp(0.43, step: 0.01) == Float(0.43))
        #expect(VoiceIDThresholdCalibrator.roundDown(0.4399, step: 0.01) == Float(0.43))
        #expect(VoiceIDThresholdCalibrator.roundDown(0.44, step: 0.01) == Float(0.44))
        #expect(VoiceIDThresholdCalibrator.roundDown(-0.031, step: 0.01) == Float(-0.04))
    }

    @Test func overlappingScoresGetAnUncertainBandWithinBudget() {
        var random = EvaluationDSP.Random(seed: 11)
        let scores = VoiceIDScores(
            target: (0..<4_000).map { _ in 0.6 + 0.1 * random.nextGaussian() },
            nonTarget: (0..<20_000).map { _ in 0.1 + 0.1 * random.nextGaussian() })
        let targets = VoiceIDCalibrationTargets(maximumFalseAcceptRate: 0.005, maximumFalseRejectRate: 0.02)
        let result = VoiceIDThresholdCalibrator.calibrate(scores, targets: targets)
        let thresholds = result.thresholds

        // The FRR budget alone would allow T_lo ≈ 0.6 - 2.054 σ ≈ 0.39, above
        // T_hi ≈ 0.1 + 2.576 σ ≈ 0.36, so T_lo comes down to T_hi.
        #expect(result.exactReject > result.exactAccept)
        #expect(thresholds.reject == thresholds.accept)
        #expect(result.atAccept.falseAcceptRate <= 0.005)
        #expect(result.atReject.falseRejectRate <= 0.02)
        // Rounded outward from the exact values, on a 0.01 grid.
        #expect(thresholds.accept >= result.exactAccept)
        #expect(thresholds.reject <= result.exactReject)
        #expect(abs(thresholds.accept * 100 - (thresholds.accept * 100).rounded()) < 1e-3)
        // ≈ 0.1 + 2.576 σ and 0.6 - 2.054 σ.
        #expect(abs(thresholds.accept - 0.36) <= 0.02)
        #expect(abs(result.exactReject - 0.39) <= 0.02)
        #expect(result.falseAccepts == Int((result.atAccept.falseAcceptRate * 20_000).rounded()))
        #expect(result.targetCount == 4_000 && result.nonTargetCount == 20_000)
    }

    @Test func wideOverlapLeavesSomeTrialsUncertain() {
        var random = EvaluationDSP.Random(seed: 12)
        let scores = VoiceIDScores(
            target: (0..<4_000).map { _ in 0.5 + 0.15 * random.nextGaussian() },
            nonTarget: (0..<20_000).map { _ in 0.1 + 0.15 * random.nextGaussian() })
        let result = VoiceIDThresholdCalibrator.calibrate(scores)
        #expect(result.thresholds.reject < result.thresholds.accept)
        #expect(result.targetUncertainRate > 0.1)
        #expect(result.nonTargetUncertainRate > 0.01)
        // Every trial is in exactly one band.
        let accepted = scores.target.filter { $0 >= result.thresholds.accept }.count
        let rejected = scores.target.filter { $0 < result.thresholds.reject }.count
        let uncertain = Double(scores.target.count - accepted - rejected) / Double(scores.target.count)
        #expect(abs(uncertain - result.targetUncertainRate) < 1e-12)
        #expect(rejected == result.falseRejects)
    }

    @Test func separatedScoresHaveNoUncertainBand() {
        let scores = VoiceIDScores(target: [0.7, 0.75, 0.8], nonTarget: [0.1, 0.2, 0.3])
        let result = VoiceIDThresholdCalibrator.calibrate(scores)
        #expect(result.thresholds.reject == result.thresholds.accept)
        #expect(result.atAccept.falseAcceptRate == 0)
        #expect(result.atReject.falseRejectRate == 0)
        #expect(result.thresholds.decision(for: 0.75) == .accept)
        #expect(result.thresholds.decision(for: 0.2) == .reject)
    }
}
