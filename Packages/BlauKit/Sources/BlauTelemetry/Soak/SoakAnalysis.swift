import Foundation

/// The limits a soak run (#76) is judged against. The defaults are the
/// ones `make soak` and the nightly job use (docs/soak.md).
public struct SoakThresholds: Codable, Hashable, Sendable {
    /// The share of the run, from the start, left out of the trend checks:
    /// caches, the first SQLite pages and the first topic fill up there.
    public var warmUpFraction: Double
    /// The steepest the physical footprint may climb, in MB per hour of
    /// session audio, after the warm-up. Per hour of audio rather than of
    /// wall time, so a leak per frame, chunk or turn reads the same at any
    /// playback speed.
    public var maximumMemorySlopeMegabytesPerHour: Double
    /// How much slower the late third of the run may be than the early
    /// third (late median over early median) for a latency to pass...
    public var maximumLatencyGrowthRatio: Double
    /// ...unless it grew by less than this in absolute terms: the floor
    /// below which a ratio is just timer noise. For the recognizer's chunk
    /// time.
    public var asrLatencyNoiseFloorMilliseconds: Double
    /// The same floor for the time to first reply audio.
    public var firstAudioNoiseFloorMilliseconds: Double
    /// The share of capture frames that may be lost.
    public var maximumDroppedFrameFraction: Double
    /// The fewest topic boundaries, as a share of the script's topic
    /// changes (the segmenter may merge two short topics).
    public var minimumTopicRecall: Double
    /// The most topic boundaries, as a multiple of the script's topic
    /// changes, plus one: more means the segmenter flaps.
    public var maximumTopicRatio: Double

    public init(
        warmUpFraction: Double = 0.1,
        maximumMemorySlopeMegabytesPerHour: Double = 2,
        maximumLatencyGrowthRatio: Double = 1.5,
        asrLatencyNoiseFloorMilliseconds: Double = 2,
        firstAudioNoiseFloorMilliseconds: Double = 50,
        maximumDroppedFrameFraction: Double = 0.001,
        minimumTopicRecall: Double = 0.5,
        maximumTopicRatio: Double = 1.5
    ) {
        self.warmUpFraction = warmUpFraction
        self.maximumMemorySlopeMegabytesPerHour = maximumMemorySlopeMegabytesPerHour
        self.maximumLatencyGrowthRatio = maximumLatencyGrowthRatio
        self.asrLatencyNoiseFloorMilliseconds = asrLatencyNoiseFloorMilliseconds
        self.firstAudioNoiseFloorMilliseconds = firstAudioNoiseFloorMilliseconds
        self.maximumDroppedFrameFraction = maximumDroppedFrameFraction
        self.minimumTopicRecall = minimumTopicRecall
        self.maximumTopicRatio = maximumTopicRatio
    }

    public static let standard = SoakThresholds()
}

/// One pass/fail rule of a soak run and what it measured.
public struct SoakCheck: Codable, Hashable, Sendable {
    /// A stable identifier, such as `memory.slope`.
    public var name: String
    public var passed: Bool
    /// What was measured, for the report: `+0.4 MB/h`.
    public var measured: String
    /// The limit it was held to: `≤ 2 MB/h`.
    public var limit: String
    /// Why it failed, or extra context.
    public var detail: String?

    public init(name: String, passed: Bool, measured: String, limit: String, detail: String? = nil) {
        self.name = name
        self.passed = passed
        self.measured = measured
        self.limit = limit
        self.detail = detail
    }
}

/// Judges a soak run from its samples and outcome: memory flat, latencies
/// not creeping up, frames not dropped, the conversation answered end to
/// end across session renewals, background speech rejected and a sane
/// number of topics (#76).
public enum SoakAnalysis {
    /// A trend summary of one series over the run.
    public struct Trend: Codable, Hashable, Sendable {
        /// The median of the early third, after the warm-up.
        public var early: Double
        /// The median of the late third.
        public var late: Double

        /// `late / early`, or `nil` when `early` is zero.
        public var ratio: Double? { early > 0 ? late / early : nil }
    }

    /// Every check, in report order.
    public static func checks(
        samples: [SoakSample], outcome: SoakOutcome, thresholds: SoakThresholds = .standard
    ) -> [SoakCheck] {
        [
            memoryCheck(samples, thresholds),
            asrLatencyCheck(samples, thresholds),
            firstAudioCheck(samples, thresholds),
            droppedFramesCheck(samples, thresholds),
            conversationCheck(outcome),
            rolloverCheck(outcome),
            backgroundCheck(outcome),
            topicCheck(outcome, thresholds),
        ]
    }

    // MARK: Series

    /// The samples after the warm-up: at least the last three when there
    /// are that many.
    public static func steadyState(_ samples: [SoakSample], warmUpFraction: Double) -> [SoakSample] {
        guard let last = samples.last else { return [] }
        let cutoff = last.audioSeconds * min(max(warmUpFraction, 0), 0.9)
        let steady = samples.filter { $0.audioSeconds >= cutoff }
        return steady.count >= 3 ? steady : Array(samples.suffix(3))
    }

    /// The footprint's growth in MB per hour of audio after the warm-up,
    /// as the Theil–Sen estimate (the median of the slopes between every
    /// pair of samples), which a few transient spikes don't move. `nil`
    /// with fewer than three readings.
    public static func memorySlope(_ samples: [SoakSample], warmUpFraction: Double) -> Double? {
        let points = steadyState(samples, warmUpFraction: warmUpFraction).compactMap { sample in
            sample.footprintBytes.map { (hours: sample.audioSeconds / 3_600, megabytes: Double($0) / 1_048_576) }
        }
        guard points.count >= 3 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(points.count * (points.count - 1) / 2)
        for (index, first) in points.enumerated() {
            for second in points[(index + 1)...] where second.hours > first.hours {
                slopes.append((second.megabytes - first.megabytes) / (second.hours - first.hours))
            }
        }
        return median(slopes)
    }

    /// The recognizer's mean time per chunk in each interval between
    /// samples, in milliseconds, after the warm-up (intervals without a
    /// chunk are skipped).
    public static func asrChunkMilliseconds(_ samples: [SoakSample], warmUpFraction: Double) -> [Double] {
        let steady = steadyState(samples, warmUpFraction: warmUpFraction)
        return zip(steady, steady.dropFirst()).compactMap { previous, next in
            let chunks = next.asrChunks - previous.asrChunks
            guard chunks > 0 else { return nil }
            return (next.asrSeconds - previous.asrSeconds) * 1_000 / Double(chunks)
        }
    }

    /// The mean time to first reply audio in each interval, after the
    /// warm-up.
    public static func firstAudioMilliseconds(_ samples: [SoakSample], warmUpFraction: Double) -> [Double] {
        steadyState(samples, warmUpFraction: warmUpFraction).dropFirst().compactMap { sample in
            sample.firstAudioCount > 0 ? sample.firstAudioMilliseconds : nil
        }
    }

    /// The early and late thirds' medians of `values`, or `nil` with fewer
    /// than three values.
    public static func trend(_ values: [Double]) -> Trend? {
        guard values.count >= 3 else { return nil }
        let third = max(1, values.count / 3)
        guard let early = median(Array(values.prefix(third))), let late = median(Array(values.suffix(third))) else {
            return nil
        }
        return Trend(early: early, late: late)
    }

    // MARK: Checks

    static func memoryCheck(_ samples: [SoakSample], _ thresholds: SoakThresholds) -> SoakCheck {
        let limit = "≤ \(format(thresholds.maximumMemorySlopeMegabytesPerHour)) MB/h of audio"
        guard let slope = memorySlope(samples, warmUpFraction: thresholds.warmUpFraction) else {
            return SoakCheck(
                name: "memory.slope", passed: false, measured: "n/a", limit: limit,
                detail: "Fewer than three footprint readings after the warm-up")
        }
        let readings = samples.compactMap(\.footprintBytes)
        let span = readings.first.flatMap { first in
            readings.last.map { "\(megabytes(first)) → \(megabytes($0)), peak \(megabytes(readings.max() ?? $0))" }
        }
        return SoakCheck(
            name: "memory.slope", passed: slope <= thresholds.maximumMemorySlopeMegabytesPerHour,
            measured: "\(signed(slope)) MB/h", limit: limit, detail: span)
    }

    static func asrLatencyCheck(_ samples: [SoakSample], _ thresholds: SoakThresholds) -> SoakCheck {
        latencyCheck(
            name: "asr.chunkLatency",
            values: asrChunkMilliseconds(samples, warmUpFraction: thresholds.warmUpFraction),
            floor: thresholds.asrLatencyNoiseFloorMilliseconds, thresholds: thresholds, unit: "per chunk")
    }

    static func firstAudioCheck(_ samples: [SoakSample], _ thresholds: SoakThresholds) -> SoakCheck {
        latencyCheck(
            name: "realtime.firstAudio",
            values: firstAudioMilliseconds(samples, warmUpFraction: thresholds.warmUpFraction),
            floor: thresholds.firstAudioNoiseFloorMilliseconds, thresholds: thresholds, unit: "to first audio")
    }

    private static func latencyCheck(
        name: String, values: [Double], floor: Double, thresholds: SoakThresholds, unit: String
    ) -> SoakCheck {
        let limit =
            "late ≤ \(format(thresholds.maximumLatencyGrowthRatio))× early, or +\(format(floor)) ms at most"
        guard let trend = trend(values) else {
            return SoakCheck(
                name: name, passed: false, measured: "n/a", limit: limit,
                detail: "Fewer than three intervals with a measurement after the warm-up")
        }
        let grewBy = trend.late - trend.early
        let passed = grewBy <= floor || trend.late <= trend.early * thresholds.maximumLatencyGrowthRatio
        return SoakCheck(
            name: name, passed: passed,
            measured: "\(milliseconds(trend.early)) → \(milliseconds(trend.late)) \(unit)", limit: limit,
            detail: "\(values.count) intervals; median of the early and late thirds")
    }

    static func droppedFramesCheck(_ samples: [SoakSample], _ thresholds: SoakThresholds) -> SoakCheck {
        let limit = "≤ \(format(thresholds.maximumDroppedFrameFraction * 100))% of frames"
        guard let last = samples.last, last.framesDelivered > 0 else {
            return SoakCheck(
                name: "capture.droppedFrames", passed: false, measured: "n/a", limit: limit,
                detail: "No frames were delivered")
        }
        let fraction = Double(last.framesDropped) / Double(last.framesDelivered + last.framesDropped)
        return SoakCheck(
            name: "capture.droppedFrames", passed: fraction <= thresholds.maximumDroppedFrameFraction,
            measured: "\(last.framesDropped) of \(last.framesDelivered + last.framesDropped)", limit: limit)
    }

    static func conversationCheck(_ outcome: SoakOutcome) -> SoakCheck {
        let passed =
            outcome.lines > 0 && outcome.userUtterances == outcome.lines && outcome.agentReplies == outcome.lines
            && outcome.failedTurns == 0
        return SoakCheck(
            name: "conversation.complete", passed: passed,
            measured:
                "\(outcome.userUtterances) transcribed, \(outcome.agentReplies) answered, \(outcome.failedTurns) failed",
            limit: "all \(outcome.lines) lines, no failed turn")
    }

    static func rolloverCheck(_ outcome: SoakOutcome) -> SoakCheck {
        let required = max(outcome.expectedRollovers, 0)
        let passed =
            outcome.rollovers >= required && outcome.reseeds >= outcome.rollovers
            && outcome.connections >= outcome.rollovers + 1
        return SoakCheck(
            name: "realtime.rollover", passed: passed,
            measured: "\(outcome.rollovers) renewed, \(outcome.reseeds) reseeded, \(outcome.connections) connections",
            limit: "≥ \(required) renewed, each reseeded on a new connection",
            detail: required == 0 ? "The run was too short on the session clock to need a renewal" : nil)
    }

    static func backgroundCheck(_ outcome: SoakOutcome) -> SoakCheck {
        let heard = outcome.backgroundBursts == 0 || outcome.backgroundScores > 0
        let passed =
            heard && outcome.backgroundRejected == outcome.backgroundScores
            && outcome.userAccepted == outcome.userScores && outcome.gateCommitted == outcome.lines
        return SoakCheck(
            name: "voiceid.background", passed: passed,
            measured:
                "\(outcome.backgroundRejected) of \(outcome.backgroundScores) background scores rejected, "
                + "\(outcome.userAccepted) of \(outcome.userScores) user scores accepted; the gate passed on "
                + "\(outcome.gateCommitted) and kept back \(outcome.gateDiscarded)",
            limit: "every background score rejected, every user score accepted, every line passed on",
            detail: heard ? nil : "None of the \(outcome.backgroundBursts) background bursts reached voice ID")
    }

    static func topicCheck(_ outcome: SoakOutcome, _ thresholds: SoakThresholds) -> SoakCheck {
        let changes = Double(outcome.scriptedTopicChanges)
        let lower = max(1, Int((changes * thresholds.minimumTopicRecall).rounded(.down)))
        let upper = Int((changes * thresholds.maximumTopicRatio).rounded(.up)) + 1
        let passed = (lower...max(lower, upper)).contains(outcome.topicBoundaries)
        return SoakCheck(
            name: "topics.count", passed: passed,
            measured: "\(outcome.topicBoundaries) boundaries for \(outcome.scriptedTopicChanges) topic changes",
            limit: "\(lower)...\(max(lower, upper))")
    }

    // MARK: Helpers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...3)).locale(Locale(identifier: "en_US_POSIX")))
    }

    static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "")
            + value.formatted(
                .number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// `12.3 ms`, `4.567 ms`, or `42.00 µs` below a tenth of a millisecond
    /// (the scripted recognizer's chunks).
    static func milliseconds(_ value: Double) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        if abs(value) < 0.1 {
            return (value * 1_000).formatted(.number.precision(.fractionLength(2)).locale(posix)) + " µs"
        }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 3 : 1)).locale(posix)) + " ms"
    }

    static func megabytes(_ bytes: UInt64) -> String {
        bytes.megabytes.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
            + " MB"
    }
}
