import Foundation

/// The artifact a long-session soak run (#76) leaves behind: how it ran,
/// a sample per interval, what the pipeline did and every check's verdict.
/// Saved as JSON (`jsonData()`) and summarized as Markdown (`markdown`) for
/// the CI summary page and the pull request.
public struct SoakReport: Codable, Hashable, Sendable {
    /// How the run was set up.
    public struct Setup: Codable, Hashable, Sendable {
        /// The session's length on the audio timeline, in seconds.
        public var audioSeconds: Double
        /// How many times faster than real time the audio played, or `nil`
        /// for as fast as the pipeline took it.
        public var speed: Double?
        /// The speech recognizer and voice activity model used.
        public var recognizer: String
        public var voiceActivity: String
        /// What the audio holds: `owner speech, TV, silence`.
        public var audio: String
        /// When the realtime session is renewed, in seconds of wall time
        /// (xAI's 110 minutes scaled to the run).
        public var rolloverAfterSeconds: Double?
        /// Seconds of audio between samples.
        public var sampleIntervalSeconds: Double

        public init(
            audioSeconds: Double, speed: Double?, recognizer: String, voiceActivity: String, audio: String,
            rolloverAfterSeconds: Double?, sampleIntervalSeconds: Double
        ) {
            self.audioSeconds = audioSeconds
            self.speed = speed
            self.recognizer = recognizer
            self.voiceActivity = voiceActivity
            self.audio = audio
            self.rolloverAfterSeconds = rolloverAfterSeconds
            self.sampleIntervalSeconds = sampleIntervalSeconds
        }
    }

    public var device: BenchmarkDevice
    public var startedAt: Date
    public var wallSeconds: Double
    public var setup: Setup
    public var thresholds: SoakThresholds
    public var outcome: SoakOutcome
    public var samples: [SoakSample]
    public var checks: [SoakCheck]

    /// Whether every check passed.
    public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }

    /// The names of the checks that failed.
    public var failures: [String] { checks.filter { !$0.passed }.map(\.name) }

    /// Judges `samples` and `outcome` against `thresholds`.
    public init(
        device: BenchmarkDevice, startedAt: Date, wallSeconds: Double, setup: Setup,
        thresholds: SoakThresholds = .standard, outcome: SoakOutcome, samples: [SoakSample]
    ) {
        self.device = device
        self.startedAt = startedAt
        self.wallSeconds = wallSeconds
        self.setup = setup
        self.thresholds = thresholds
        self.outcome = outcome
        self.samples = samples
        checks = SoakAnalysis.checks(samples: samples, outcome: outcome, thresholds: thresholds)
    }

    /// A one-line result: `passed: 120 min of audio in 13.2 min, 8/8 checks`.
    public var summary: String {
        let passedCount = checks.filter(\.passed).count
        return "\(passed ? "passed" : "failed"): \(Self.minutes(setup.audioSeconds)) of audio in "
            + "\(Self.minutes(wallSeconds)), \(passedCount)/\(checks.count) checks"
            + (passed ? "" : " (failed: \(failures.joined(separator: ", ")))")
    }

    /// The report as pretty-printed JSON with sorted keys and ISO 8601 dates.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SoakReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SoakReport.self, from: data)
    }

    /// The report as Markdown: the verdict, the setup, the checks table and
    /// the samples.
    public var markdown: String {
        var lines: [String] = []
        lines.append("## Long-session soak: \(passed ? "passed" : "FAILED")")
        lines.append("")
        let speed = setup.speed.map { "\(SoakAnalysis.format($0))× real time" } ?? "as fast as the pipeline went"
        lines.append(
            "\(Self.minutes(setup.audioSeconds)) of audio (\(setup.audio)) at \(speed), "
                + "in \(Self.minutes(wallSeconds)) on \(device.displayName), \(device.operatingSystem). "
                + "\(setup.recognizer), \(setup.voiceActivity).")
        if let rollover = setup.rolloverAfterSeconds {
            lines.append("")
            lines.append(
                "Realtime session renewed after \(Self.minutes(rollover)) of wall time (xAI's 110 minutes, scaled).")
        }
        lines.append("")
        lines.append("| Check | Result | Measured | Limit |")
        lines.append("| --- | --- | --- | --- |")
        for check in checks {
            let detail = check.detail.map { " (\($0))" } ?? ""
            lines.append(
                "| `\(check.name)` | \(check.passed ? "pass" : "**FAIL**") | \(check.measured)\(detail) | \(check.limit) |"
            )
        }
        lines.append("")
        lines.append(
            "\(outcome.lines) lines, \(outcome.backgroundBursts) background bursts, "
                + "\(outcome.scriptedTopicChanges) scripted topic changes; \(outcome.connections) realtime connections."
        )
        lines.append("")
        lines.append("<details><summary>Samples</summary>")
        lines.append("")
        lines.append(
            "| Audio | Wall | Footprint | ASR chunks | ms/chunk | First audio | Dropped | Utterances | Replies | Topics | Renewed |"
        )
        lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        var previous: SoakSample?
        for sample in samples {
            let chunks = sample.asrChunks - (previous?.asrChunks ?? 0)
            let perChunk =
                chunks > 0
                ? SoakAnalysis.milliseconds((sample.asrSeconds - (previous?.asrSeconds ?? 0)) * 1_000 / Double(chunks))
                : "–"
            let firstAudio = sample.firstAudioMilliseconds.map { SoakAnalysis.milliseconds($0) } ?? "–"
            let footprint = sample.footprintBytes.map { SoakAnalysis.megabytes($0) } ?? "–"
            lines.append(
                "| \(Self.minutes(sample.audioSeconds)) | \(Self.minutes(sample.wallSeconds)) | \(footprint) | "
                    + "\(sample.asrChunks) | \(perChunk) | \(firstAudio) | \(sample.framesDropped) | "
                    + "\(sample.userUtterances) | \(sample.agentReplies) | \(sample.topicBoundaries) | \(sample.rollovers) |"
            )
            previous = sample
        }
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func minutes(_ seconds: Double) -> String {
        "\((seconds / 60).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))) min"
    }
}
