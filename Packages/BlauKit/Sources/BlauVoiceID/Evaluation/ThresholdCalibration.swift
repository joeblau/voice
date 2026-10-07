import Foundation

/// The error budgets the accept and reject thresholds are calibrated to.
public struct VoiceIDCalibrationTargets: Hashable, Codable, Sendable {
    /// `T_hi` is the lowest threshold that accepts at most this share of
    /// non-target trials.
    public let maximumFalseAcceptRate: Double
    /// `T_lo` is the highest threshold that rejects at most this share of
    /// target trials.
    public let maximumFalseRejectRate: Double

    public init(maximumFalseAcceptRate: Double, maximumFalseRejectRate: Double) {
        precondition((0...1).contains(maximumFalseAcceptRate) && (0...1).contains(maximumFalseRejectRate))
        self.maximumFalseAcceptRate = maximumFalseAcceptRate
        self.maximumFalseRejectRate = maximumFalseRejectRate
    }

    /// Accept with at most 0.5% false accepts (TV, podcasts and other people
    /// reaching Grok is the failure the gate exists to stop); reject with at
    /// most 2% false rejects (#47 budgets owner FRR under 3% after the
    /// re-scores, and an uncertain score gets another look).
    public static let standard = VoiceIDCalibrationTargets(maximumFalseAcceptRate: 0.005, maximumFalseRejectRate: 0.02)
}

/// One calibrated window: the thresholds and the error rates they give on
/// the calibration scores.
public struct VoiceIDCalibratedThresholds: Hashable, Codable, Sendable {
    public let thresholds: VoiceIDThresholds
    /// FAR and FRR at `T_hi` (rounded) on the calibration scores.
    public let atAccept: VoiceIDOperatingPoint
    /// FAR and FRR at `T_lo` (rounded) on the calibration scores.
    public let atReject: VoiceIDOperatingPoint
    /// The unrounded `T_hi` and `T_lo`.
    public let exactAccept: Float
    public let exactReject: Float
    /// Non-target trials at or above `T_hi`: the false accepts behind the
    /// FAR. Fewer than about 30 means the FAR is a rough estimate.
    public let falseAccepts: Int
    /// Target trials below `T_lo`.
    public let falseRejects: Int
    public let targetCount: Int
    public let nonTargetCount: Int

    /// Share of target trials in the uncertain band.
    public let targetUncertainRate: Double
    /// Share of non-target trials in the uncertain band.
    public let nonTargetUncertainRate: Double
}

/// Picks `T_hi` and `T_lo` from evaluation scores.
public enum VoiceIDThresholdCalibrator {
    /// Calibrates one window.
    ///
    /// `T_hi` is the lowest threshold whose FAR meets the budget and `T_lo`
    /// the highest whose FRR does, each rounded outward to `step` (`T_hi`
    /// up, `T_lo` down) so the shipped values only ever err on the safe
    /// side. When the two cross (the scores separate well enough that both
    /// budgets are met by one threshold), `T_lo` is lowered to `T_hi`: no
    /// uncertain band, every score is decided at once.
    ///
    /// - Precondition: `scores` has target and non-target trials.
    public static func calibrate(
        _ scores: VoiceIDScores,
        targets: VoiceIDCalibrationTargets = .standard,
        step: Float = 0.01
    ) -> VoiceIDCalibratedThresholds {
        precondition(step > 0)
        let curve = DETCurve(scores)
        let accept = curve.threshold(forFalseAcceptRate: targets.maximumFalseAcceptRate).threshold
        let reject = curve.threshold(forFalseRejectRate: targets.maximumFalseRejectRate).threshold
        let roundedAccept = roundUp(accept, step: step)
        let roundedReject = min(roundDown(reject, step: step), roundedAccept)
        let thresholds = VoiceIDThresholds(accept: roundedAccept, reject: roundedReject)

        let atAccept = curve.rates(at: roundedAccept)
        let atReject = curve.rates(at: roundedReject)
        let falseAccepts = curve.nonTarget.count - DETCurve.lowerBound(of: roundedAccept, in: curve.nonTarget)
        let falseRejects = DETCurve.lowerBound(of: roundedReject, in: curve.target)
        let targetUncertain =
            DETCurve.lowerBound(of: roundedAccept, in: curve.target) - falseRejects
        let nonTargetUncertain =
            DETCurve.lowerBound(of: roundedAccept, in: curve.nonTarget)
            - DETCurve.lowerBound(of: roundedReject, in: curve.nonTarget)
        return VoiceIDCalibratedThresholds(
            thresholds: thresholds,
            atAccept: atAccept,
            atReject: atReject,
            exactAccept: accept,
            exactReject: reject,
            falseAccepts: falseAccepts,
            falseRejects: falseRejects,
            targetCount: curve.target.count,
            nonTargetCount: curve.nonTarget.count,
            targetUncertainRate: Double(targetUncertain) / Double(curve.target.count),
            nonTargetUncertainRate: Double(nonTargetUncertain) / Double(curve.nonTarget.count)
        )
    }

    /// `value` rounded up to a multiple of `step` (values already on the
    /// grid, give or take float noise, stay put).
    static func roundUp(_ value: Float, step: Float) -> Float {
        round(value, step: step, .up)
    }

    /// `value` rounded down to a multiple of `step`.
    static func roundDown(_ value: Float, step: Float) -> Float {
        round(value, step: step, .down)
    }

    private static func round(_ value: Float, step: Float, _ rule: FloatingPointRoundingRule) -> Float {
        // Work in grid units per 1 (100 for 0.01), so 0.2 comes out as the
        // Float nearest 0.2, not 20 × Float(0.01) = 0.19999999.
        let perUnit = (1 / Double(step)).rounded()
        let exactGrid = abs(perUnit * Double(step) - 1) < 1e-6
        let scaled = exactGrid ? Double(value) * perUnit : Double(value) / Double(step)
        let nearest = scaled.rounded()
        let units = abs(scaled - nearest) < 1e-4 ? nearest : scaled.rounded(rule)
        return Float(exactGrid ? units / perUnit : units * Double(step))
    }
}

/// The probit function (inverse of the standard normal CDF), the axis scale
/// of DET plots.
public enum Probit {
    /// Rates are clamped to `[floor, 1 - floor]` so 0 and 1 stay plottable.
    public static let floor = 1e-5

    /// The standard normal deviate whose lower tail probability is `p`.
    ///
    /// Peter Acklam's rational approximation (relative error below 1.2e-9),
    /// with `p` clamped to `[floor, 1 - floor]`.
    public static func deviate(_ p: Double) -> Double {
        let p = min(max(p, floor), 1 - floor)
        let a = [
            -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
            1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00,
        ]
        let b = [
            -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
            6.680131188771972e+01, -1.328068155288572e+01,
        ]
        let c = [
            -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
            -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00,
        ]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 1 - low {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }
}
