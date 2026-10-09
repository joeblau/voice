import BlauCore
import Foundation

/// One scored speech segment in a replayed conversation: who really spoke
/// and what voice ID saw.
public struct VoiceprintAdaptationTrial: Hashable, Sendable {
    /// The segment's embedding; its `audioDuration` picks the thresholds.
    public let embedding: SpeakerEmbedding
    /// Whether the enrolled owner spoke it.
    public let isOwner: Bool
    /// How long the segment's speech is.
    public let speechDuration: Duration
    /// Speech over noise in dB, `nil` if unmeasured.
    public let signalToNoise: Float?
    /// The fraction of clipped samples.
    public let clippedFraction: Double

    public init(
        embedding: SpeakerEmbedding, isOwner: Bool, speechDuration: Duration, signalToNoise: Float?,
        clippedFraction: Double = 0
    ) {
        self.embedding = embedding
        self.isOwner = isOwner
        self.speechDuration = speechDuration
        self.signalToNoise = signalToNoise
        self.clippedFraction = clippedFraction
    }
}

/// One replayed conversation: its day and its segments in order.
public struct VoiceprintAdaptationSession: Hashable, Sendable {
    /// The day it belongs to (0 is the enrollment day).
    public let day: Int
    public let trials: [VoiceprintAdaptationTrial]

    public init(day: Int, trials: [VoiceprintAdaptationTrial]) {
        self.day = day
        self.trials = trials
    }
}

/// Replays conversations through voice ID's decision and adaptive
/// voiceprint updates (#49), the way the app runs them: each conversation
/// loads the stored voiceprint, scores every segment against the adapted
/// voiceprint with the gate's thresholds, offers accepted segments to
/// ``AdaptiveVoiceprint``, and saves the centroid when it ends.
///
/// Run it twice, with a policy and without (`policy: nil`, the static
/// voiceprint), on the same sessions to see what adaptation changes: the
/// owner's false rejections and impostors' false accepts, day by day.
/// `VoiceprintAdaptationSimulationTests` replays a simulated week; recorded
/// owner sessions (Datasets/voice-id) can be replayed the same way.
public struct VoiceprintAdaptationReplay: Sendable {
    public let config: VoiceIDConfig
    /// `nil` replays the static voiceprint (no adaptation).
    public let policy: VoiceprintAdaptationPolicy?

    public init(config: VoiceIDConfig = .calibrated, policy: VoiceprintAdaptationPolicy?) {
        self.config = config
        self.policy = policy
    }

    /// Replays `sessions` in order, starting from `voiceprint`.
    ///
    /// - Throws: `VoiceprintScorer.Error` when the scoring method can't run.
    public func run(
        _ sessions: [VoiceprintAdaptationSession], voiceprint: Voiceprint, cohort: SpeakerCohort? = nil
    ) throws(VoiceprintScorer.Error) -> VoiceprintAdaptationReport {
        var stored = voiceprint
        let enrollment = voiceprint.enrollmentCentroid ?? voiceprint.centroid
        var days: [Int: VoiceprintAdaptationReport.Day] = [:]
        var maximumDrift: Float = 0

        for session in sessions {
            var day = days[session.day] ?? VoiceprintAdaptationReport.Day(day: session.day)
            let adaptive = try policy.flatMap { policy throws(VoiceprintScorer.Error) in
                try AdaptiveVoiceprint(voiceprint: stored, scoring: config.scoring, cohort: cohort, policy: policy)
            }
            let fixed =
                adaptive == nil
                ? try VoiceprintMatcher(voiceprint: stored, scoring: config.scoring, cohort: cohort) : nil

            for trial in session.trials {
                guard let matcher = adaptive?.matcher ?? fixed else { break }
                let score = matcher.score(trial.embedding)
                let thresholds = config.thresholds(forAudioDuration: trial.embedding.audioDuration)
                let decision = thresholds.decision(for: score)
                day.record(decision, isOwner: trial.isOwner)
                guard decision == .accept, let adaptive else { continue }
                let outcome = adaptive.consider(
                    VoiceprintAdaptationEvidence(
                        embedding: trial.embedding, score: score, thresholds: thresholds,
                        speechDuration: trial.speechDuration, signalToNoise: trial.signalToNoise,
                        clippedFraction: trial.clippedFraction))
                switch outcome {
                case .updated(let update):
                    day.updates += 1
                    if trial.isOwner { day.ownerUpdates += 1 } else { day.impostorUpdates += 1 }
                    maximumDrift = max(maximumDrift, update.drift)
                case .rolledBack: day.rollbacks += 1
                case .skipped: break
                }
            }
            if let adaptive, adaptive.adaptation.hasChanges {
                // What `VoiceprintAdapter.finish()` saves.
                stored = stored.withCentroid(adaptive.adaptation.centroid)
            }
            day.drift = VoiceprintAdaptation.drift(of: stored.centroid, from: enrollment)
            days[session.day] = day
        }
        return VoiceprintAdaptationReport(
            days: days.values.sorted { $0.day < $1.day }, maximumDrift: maximumDrift, finalCentroid: stored.centroid)
    }
}

/// What a ``VoiceprintAdaptationReplay`` measured.
public struct VoiceprintAdaptationReport: Hashable, Sendable {
    /// One day's decisions and updates.
    public struct Day: Hashable, Sendable {
        public let day: Int
        public var ownerTrials = 0
        public var ownerAccepted = 0
        public var ownerRejected = 0
        public var impostorTrials = 0
        public var impostorAccepted = 0
        public var impostorRejected = 0
        /// Updates, and which speaker's segments made them.
        public var updates = 0
        public var ownerUpdates = 0
        public var impostorUpdates = 0
        public var rollbacks = 0
        /// The stored centroid's distance from the enrollment centroid at
        /// the end of the day.
        public var drift: Float = 0

        public init(day: Int) {
            self.day = day
        }

        mutating func record(_ decision: SpeakerDecision, isOwner: Bool) {
            if isOwner {
                ownerTrials += 1
                if decision == .accept { ownerAccepted += 1 }
                if decision == .reject { ownerRejected += 1 }
            } else {
                impostorTrials += 1
                if decision == .accept { impostorAccepted += 1 }
                if decision == .reject { impostorRejected += 1 }
            }
        }

        /// Owner segments not accepted (rejected or uncertain): what the
        /// owner loses outside an active turn.
        public var falseRejectRate: Double { Self.rate(ownerTrials - ownerAccepted, of: ownerTrials) }
        /// Owner segments rejected outright.
        public var ownerRejectRate: Double { Self.rate(ownerRejected, of: ownerTrials) }
        /// Impostor segments accepted.
        public var falseAcceptRate: Double { Self.rate(impostorAccepted, of: impostorTrials) }
        /// Impostor segments not rejected (accepted or uncertain): what can
        /// leak during an active turn.
        public var impostorNotRejectedRate: Double { Self.rate(impostorTrials - impostorRejected, of: impostorTrials) }

        /// `days` added up under the number `day`; the drift is the last
        /// one's.
        public static func pooled(_ days: [Day], as day: Int) -> Day {
            days.reduce(into: Day(day: day)) { total, day in
                total.ownerTrials += day.ownerTrials
                total.ownerAccepted += day.ownerAccepted
                total.ownerRejected += day.ownerRejected
                total.impostorTrials += day.impostorTrials
                total.impostorAccepted += day.impostorAccepted
                total.impostorRejected += day.impostorRejected
                total.updates += day.updates
                total.ownerUpdates += day.ownerUpdates
                total.impostorUpdates += day.impostorUpdates
                total.rollbacks += day.rollbacks
                total.drift = day.drift
            }
        }

        static func rate(_ count: Int, of total: Int) -> Double {
            total == 0 ? 0 : Double(count) / Double(total)
        }
    }

    public let days: [Day]
    /// The largest drift any update reached.
    public let maximumDrift: Float
    /// The stored centroid after the last session.
    public let finalCentroid: SpeakerEmbedding

    /// Every day pooled.
    public var total: Day { Day.pooled(days, as: -1) }

    /// A Markdown table, one row per day, with `baseline` (the static
    /// voiceprint on the same sessions) alongside when given.
    public func markdownTable(baseline: VoiceprintAdaptationReport? = nil) -> String {
        func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
        var lines: [String] = []
        if baseline != nil {
            lines.append("| Day | FRR static | FRR adaptive | FAR static | FAR adaptive | Updates (impostor) | Drift |")
            lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        } else {
            lines.append("| Day | FRR | Owner rejected | FAR | Updates (impostor) | Drift |")
            lines.append("| ---: | ---: | ---: | ---: | ---: | ---: |")
        }
        for day in days {
            let updates = "\(day.updates) (\(day.impostorUpdates))"
            let drift = String(format: "%.3f", day.drift)
            if let reference = baseline?.days.first(where: { $0.day == day.day }) {
                lines.append(
                    "| \(day.day) | \(percent(reference.falseRejectRate)) | \(percent(day.falseRejectRate)) | "
                        + "\(percent(reference.falseAcceptRate)) | \(percent(day.falseAcceptRate)) | \(updates) | \(drift) |"
                )
            } else {
                lines.append(
                    "| \(day.day) | \(percent(day.falseRejectRate)) | \(percent(day.ownerRejectRate)) | "
                        + "\(percent(day.falseAcceptRate)) | \(updates) | \(drift) |")
            }
        }
        return lines.joined(separator: "\n")
    }
}
