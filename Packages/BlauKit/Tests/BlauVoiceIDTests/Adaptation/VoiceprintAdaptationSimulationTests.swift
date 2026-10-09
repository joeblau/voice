import Foundation
import Testing

@testable import BlauVoiceID

/// Issue #49's acceptance criterion: a simulated week of sessions keeps the
/// false reject rate stable without raising the false accept rate.
///
/// Each scenario is a week of conversations (`SimulatedVoiceWeek`: three a
/// day, 40 owner segments and 200 segments of other voices each) replayed
/// twice through the gate's decision with the calibrated thresholds: once
/// with the static voiceprint, once with adaptive updates
/// (`VoiceprintAdaptationReplay`). Five seeds per scenario are pooled.
///
/// FRR here is the share of the owner's segments *not accepted* (rejected
/// or uncertain): what the owner loses outside an active turn. FAR is the
/// share of other voices' segments accepted.
@Suite("Voiceprint adaptation: simulated week")
struct VoiceprintAdaptationSimulationTests {
    static let seeds: [UInt64] = [49, 7, 99, 1234, 2026]

    /// One scenario's static and adaptive replays, pooled over the seeds.
    struct Outcome {
        let fixed: [VoiceprintAdaptationReport.Day]
        let adaptive: [VoiceprintAdaptationReport.Day]
        let maximumDrift: Float
        let rollbacks: Int

        var fixedTotal: VoiceprintAdaptationReport.Day { Self.pool(fixed) }
        var adaptiveTotal: VoiceprintAdaptationReport.Day { Self.pool(adaptive) }

        /// The static and adaptive days `days`, pooled.
        func pooled(_ days: ClosedRange<Int>) -> (
            fixed: VoiceprintAdaptationReport.Day, adaptive: VoiceprintAdaptationReport.Day
        ) {
            (Self.pool(fixed.filter { days.contains($0.day) }), Self.pool(adaptive.filter { days.contains($0.day) }))
        }

        static func pool(_ days: [VoiceprintAdaptationReport.Day]) -> VoiceprintAdaptationReport.Day {
            .pooled(days, as: -1)
        }

        var table: String {
            func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
            var lines = [
                "| Day | FRR static | FRR adaptive | FAR static | FAR adaptive | Updates (from others) | Drift |",
                "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
            for (fixed, adaptive) in zip(fixed, adaptive) {
                lines.append(
                    "| \(fixed.day) | \(percent(fixed.falseRejectRate)) | \(percent(adaptive.falseRejectRate)) | "
                        + "\(percent(fixed.falseAcceptRate)) | \(percent(adaptive.falseAcceptRate)) | "
                        + "\(adaptive.updates) (\(adaptive.impostorUpdates)) | \(String(format: "%.3f", adaptive.drift)) |"
                )
            }
            let fixedTotal = fixedTotal
            let adaptiveTotal = adaptiveTotal
            lines.append(
                "| All | \(percent(fixedTotal.falseRejectRate)) | \(percent(adaptiveTotal.falseRejectRate)) | "
                    + "\(percent(fixedTotal.falseAcceptRate)) | \(percent(adaptiveTotal.falseAcceptRate)) | "
                    + "\(adaptiveTotal.updates) (\(adaptiveTotal.impostorUpdates)) | max \(String(format: "%.3f", maximumDrift)) |"
            )
            return lines.joined(separator: "\n")
        }
    }

    static func run(
        _ parameters: SimulatedVoiceWeek.Parameters, policy: VoiceprintAdaptationPolicy = .standard
    ) throws -> Outcome {
        var fixed: [Int: [VoiceprintAdaptationReport.Day]] = [:]
        var adaptive: [Int: [VoiceprintAdaptationReport.Day]] = [:]
        var maximumDrift: Float = 0
        var rollbacks = 0
        for seed in seeds {
            var parameters = parameters
            parameters.seed = seed
            let week = SimulatedVoiceWeek(parameters)
            let staticReport = try VoiceprintAdaptationReplay(policy: nil).run(
                week.sessions, voiceprint: week.voiceprint)
            let adaptiveReport = try VoiceprintAdaptationReplay(policy: policy).run(
                week.sessions, voiceprint: week.voiceprint)
            for day in staticReport.days { fixed[day.day, default: []].append(day) }
            for day in adaptiveReport.days { adaptive[day.day, default: []].append(day) }
            maximumDrift = max(maximumDrift, adaptiveReport.maximumDrift)
            rollbacks += adaptiveReport.total.rollbacks
        }
        func pooledByDay(_ days: [Int: [VoiceprintAdaptationReport.Day]]) -> [VoiceprintAdaptationReport.Day] {
            days.keys.sorted().map { key in
                var day = VoiceprintAdaptationReport.Day.pooled(days[key] ?? [], as: key)
                // The drift reported is the mean over the seeds.
                let drifts = (days[key] ?? []).map(\.drift)
                day.drift = drifts.reduce(0, +) / Float(max(1, drifts.count))
                return day
            }
        }
        return Outcome(
            fixed: pooledByDay(fixed), adaptive: pooledByDay(adaptive), maximumDrift: maximumDrift,
            rollbacks: rollbacks)
    }

    /// Other voices accepted with adaptation: at most two segments (of the
    /// week's 21,000) more than with the static voiceprint, or
    /// `relativeAllowance` more, whichever is larger.
    static func expectFARNotRaised(
        _ outcome: Outcome, relativeAllowance: Double = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let fixed = outcome.fixedTotal
        let adaptive = outcome.adaptiveTotal
        let allowance = max(2, Int((Double(fixed.impostorAccepted) * relativeAllowance).rounded(.up)))
        #expect(
            adaptive.impostorAccepted <= fixed.impostorAccepted + allowance,
            "FAR \(adaptive.falseAcceptRate) adaptive vs \(fixed.falseAcceptRate) static",
            sourceLocation: sourceLocation)
        // ... and other voices barely ever move the centroid.
        #expect(
            adaptive.impostorUpdates * 200 <= max(1, adaptive.updates),
            "\(adaptive.impostorUpdates) updates from others",
            sourceLocation: sourceLocation)
    }

    // MARK: Scenarios

    /// The owner's voice doesn't change. Adaptation must do no harm.
    @Test func aSteadyVoiceKeepsItsRates() throws {
        let outcome = try Self.run(SimulatedVoiceWeek.Parameters())
        print("Steady voice:\n\(outcome.table)")

        #expect(outcome.adaptiveTotal.falseRejectRate <= outcome.fixedTotal.falseRejectRate)
        let (firstFixed, _) = outcome.pooled(0...1)
        let (_, lastAdaptive) = outcome.pooled(5...6)
        #expect(lastAdaptive.falseRejectRate <= firstFixed.falseRejectRate + 0.01)
        Self.expectFARNotRaised(outcome)
        #expect(outcome.maximumDrift <= VoiceprintAdaptationPolicy.standard.maximumDrift + 1e-4)
        #expect(outcome.rollbacks == 0)
    }

    /// The owner's voice changes steadily over the week (cosine 0.85
    /// between the last day's voice and the enrollment day's). The static
    /// voiceprint's FRR climbs; the adapted one stays near day 0's.
    @Test func aGraduallyChangingVoiceKeepsFRRStable() throws {
        var parameters = SimulatedVoiceWeek.Parameters()
        parameters.finalDayCosine = 0.85
        let outcome = try Self.run(parameters)
        print("Gradual change:\n\(outcome.table)")

        let (firstFixed, firstAdaptive) = outcome.pooled(0...1)
        let (lastFixed, lastAdaptive) = outcome.pooled(5...6)
        // The change is real: the static voiceprint loses the owner.
        #expect(lastFixed.falseRejectRate >= firstFixed.falseRejectRate + 0.04)
        // Adapted, the end of the week is about where it started.
        #expect(lastAdaptive.falseRejectRate <= firstFixed.falseRejectRate + 0.015)
        #expect(lastAdaptive.falseRejectRate <= firstAdaptive.falseRejectRate + 0.02)
        #expect(lastAdaptive.falseRejectRate < lastFixed.falseRejectRate / 2)
        Self.expectFARNotRaised(outcome)
        #expect(outcome.maximumDrift <= VoiceprintAdaptationPolicy.standard.maximumDrift + 1e-4)
    }

    /// A cold on days 2 to 4 changes the voice, then it comes back.
    /// Adaptation follows it there and back.
    @Test func aTemporaryChangeIsFollowedAndUndone() throws {
        var parameters = SimulatedVoiceWeek.Parameters()
        parameters.temporaryChange = (2...4, 0.85)
        let outcome = try Self.run(parameters)
        print("A cold on days 2-4:\n\(outcome.table)")

        let (coldFixed, coldAdaptive) = outcome.pooled(2...4)
        let (afterFixed, afterAdaptive) = outcome.pooled(5...6)
        let (beforeFixed, _) = outcome.pooled(0...1)
        #expect(coldFixed.falseRejectRate >= beforeFixed.falseRejectRate + 0.03)
        #expect(coldAdaptive.falseRejectRate < coldFixed.falseRejectRate * 0.6)
        // Back to normal: no worse than the static voiceprint.
        #expect(afterAdaptive.falseRejectRate <= afterFixed.falseRejectRate + 0.01)
        Self.expectFARNotRaised(outcome)
    }

    /// Two housemates whose voices are close to the owner's (cosine 0.55:
    /// closer than any voice in the calibration set) talk in every
    /// conversation, while the owner's voice changes. A centroid closer to
    /// the owner would score them higher too; the adapted centroid's
    /// handicap (`VoiceprintMatcher.adaptedCentroidPenalty`) keeps their
    /// accept rate where the static voiceprint has it.
    @Test func lookAlikeHousematesBarelyGain() throws {
        var parameters = SimulatedVoiceWeek.Parameters()
        parameters.housemates = 2
        parameters.finalDayCosine = 0.85
        let outcome = try Self.run(parameters)
        print("Look-alike housemates:\n\(outcome.table)")

        // Static FAR is already 2.5% here (five times the calibration
        // target): the handicap keeps it within 10% of that.
        Self.expectFARNotRaised(outcome, relativeAllowance: 0.10)
        let (lastFixed, lastAdaptive) = outcome.pooled(5...6)
        #expect(lastAdaptive.falseRejectRate < lastFixed.falseRejectRate / 2)

        // Without the handicap, they would get through far more often.
        var unguarded = VoiceprintAdaptationPolicy.standard
        unguarded.adaptedCentroidPenalty = 0
        let withoutPenalty = try Self.run(parameters, policy: unguarded)
        print("Look-alike housemates, without the handicap:\n\(withoutPenalty.table)")
        #expect(withoutPenalty.adaptiveTotal.falseAcceptRate > outcome.adaptiveTotal.falseAcceptRate * 1.5)
    }

    /// The drift cap holds however far the voice goes: a voice that ends
    /// the week at cosine 0.6 from enrollment (a different microphone, a
    /// long illness) pulls the centroid only to the cap.
    @Test func theDriftCapHolds() throws {
        var parameters = SimulatedVoiceWeek.Parameters()
        parameters.finalDayCosine = 0.6
        parameters.seed = 49
        let week = SimulatedVoiceWeek(parameters)
        let report = try VoiceprintAdaptationReplay(policy: .standard).run(week.sessions, voiceprint: week.voiceprint)
        let cap = VoiceprintAdaptationPolicy.standard.maximumDrift
        #expect(report.maximumDrift <= cap + 1e-4)
        #expect(report.maximumDrift >= cap - 0.01)
        let enrollment = try #require(week.voiceprint.enrollmentCentroid)
        #expect(VoiceprintAdaptation.drift(of: report.finalCentroid, from: enrollment) <= cap + 1e-4)
    }
}
