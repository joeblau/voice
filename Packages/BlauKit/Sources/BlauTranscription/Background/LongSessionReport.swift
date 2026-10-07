import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation

/// What a long-session soak run on a device produced (#26): how the
/// conversation's audio, capture, VAD and background inference fared over
/// a session that spent most of its time with the screen locked.
///
/// The debug "Long session" screen builds one when a run stops and shares
/// it as JSON; `verdict` applies the acceptance rules in docs/background.md.
public struct LongSessionReport: Codable, Hashable, Sendable {
    /// `CaptureStatistics`, as saved.
    public struct Capture: Codable, Hashable, Sendable {
        public var framesPublished: Int64
        public var droppedBuffers: Int64
        public var droppedSamples: Int64
        public var gaps: Int64
        public var subscriberDroppedFrames: Int64
        public var conversionFailures: Int64
        public var segments: Int64

        public init(_ statistics: CaptureStatistics) {
            framesPublished = statistics.framesPublished
            droppedBuffers = statistics.droppedBuffers
            droppedSamples = statistics.droppedSamples
            gaps = statistics.gaps
            subscriberDroppedFrames = statistics.subscriberDroppedFrames
            conversionFailures = statistics.conversionFailures
            segments = statistics.segments
        }
    }

    /// `VoiceActivityStatistics`, as saved.
    public struct VAD: Codable, Hashable, Sendable {
        /// Which model ran (Silero on Core ML, or the energy fallback).
        public var model: String
        public var secondsProcessed: Double
        public var chunksAnalyzed: Int64
        public var chunksSkipped: Int64
        public var modelFailures: Int64
        public var segments: Int64
        public var modelLoad: Double

        public init(model: String, statistics: VoiceActivityStatistics) {
            self.model = model
            secondsProcessed = Double(statistics.samplesProcessed) / Double(AudioFrame.captureSampleRate)
            chunksAnalyzed = statistics.chunksAnalyzed
            chunksSkipped = statistics.chunksSkipped
            modelFailures = statistics.modelFailures
            segments = statistics.segments
            modelLoad = statistics.modelLoad
        }
    }

    /// Whether the run meets the acceptance rules, and why not.
    public struct Verdict: Codable, Hashable, Sendable {
        public var passed: Bool
        /// One line per rule that failed; empty when it passed.
        public var findings: [String]
    }

    /// The thresholds `verdict` checks.
    public struct Rules: Codable, Hashable, Sendable {
        /// The acceptance criterion: 30 minutes locked.
        public var minimumLockedSeconds: Double = 30 * 60
        /// Time not live, outside interruptions, as a share of the session.
        public var maximumNotLiveShare: Double = 0.01
        /// Audio the VAD analysed as a share of the session's duration: it
        /// kept up the whole time, locked included.
        public var minimumVADCoverage: Double = 0.95

        public init() {}
    }

    public var device: BenchmarkDevice
    public var startedAt: Date
    public var endedAt: Date
    /// The keeper's status when the run stopped.
    public var finalStatus: String
    public var keeper: AudioSessionKeeper.Statistics
    public var capture: Capture
    public var vad: VAD?
    public var inference: BackgroundInferenceMonitor.Snapshot
    public var rules: Rules
    public var verdict: Verdict

    public init(
        device: BenchmarkDevice,
        startedAt: Date,
        endedAt: Date,
        finalStatus: String,
        keeper: AudioSessionKeeper.Statistics,
        capture: Capture,
        vad: VAD?,
        inference: BackgroundInferenceMonitor.Snapshot,
        rules: Rules = Rules()
    ) {
        self.device = device
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finalStatus = finalStatus
        self.keeper = keeper
        self.capture = capture
        self.vad = vad
        self.inference = inference
        self.rules = rules
        self.verdict = Self.evaluate(keeper: keeper, vad: vad, inference: inference, rules: rules)
    }

    /// Applies `rules`. Interruptions (a call during the run) don't fail it;
    /// time not live without one does, and so does a stall the keeper
    /// couldn't clear, a VAD that fell behind, or a model stage with no
    /// backend left.
    public static func evaluate(
        keeper: AudioSessionKeeper.Statistics,
        vad: VAD?,
        inference: BackgroundInferenceMonitor.Snapshot,
        rules: Rules
    ) -> Verdict {
        var findings: [String] = []
        if keeper.lockedSeconds < rules.minimumLockedSeconds {
            findings.append(
                "Locked for \(minutes(keeper.lockedSeconds)) min; the test needs \(minutes(rules.minimumLockedSeconds))"
            )
        }
        if keeper.stallsDetected > keeper.stallsRecovered {
            findings.append(
                "\(keeper.stallsDetected - keeper.stallsRecovered) of \(keeper.stallsDetected) capture stall(s) not recovered"
            )
        }
        if keeper.interruptions == 0, keeper.totalSeconds > 0,
            keeper.notLiveSeconds / keeper.totalSeconds > rules.maximumNotLiveShare
        {
            findings.append("Audio wasn't live for \(Int(keeper.notLiveSeconds.rounded())) s without an interruption")
        }
        if let vad, keeper.totalSeconds > 0 {
            let coverage = vad.secondsProcessed / keeper.totalSeconds
            if coverage < rules.minimumVADCoverage {
                findings.append("The VAD analysed \(Int((coverage * 100).rounded()))% of the session's audio")
            }
        }
        for stage in inference.stages where stage.isExhausted {
            findings.append("The \(stage.stage) stage couldn't keep up on any backend")
        }
        return Verdict(passed: findings.isEmpty, findings: findings)
    }

    private static func minutes(_ seconds: Double) -> String {
        (seconds / 60).formatted(.number.precision(.fractionLength(1)))
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
