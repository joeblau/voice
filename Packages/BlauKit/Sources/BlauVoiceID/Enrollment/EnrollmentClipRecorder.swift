import BlauCore

/// What the live quality meter shows while a clip records.
public struct EnrollmentMeter: Hashable, Sendable {
    /// The latest input level for the level bar, `0...1` (-60 dBFS to full
    /// scale, linear in decibels).
    public var level: Float
    /// Talking time detected so far.
    public var speech: Duration
    /// The talking time the clip is aiming for.
    public var speechTarget: Duration
    /// The live speech-over-background estimate in dB, `nil` before any
    /// speech.
    public var signalToNoise: Float?
    /// How long the clip has been recording.
    public var elapsed: Duration

    public init(
        level: Float = 0, speech: Duration = .zero, speechTarget: Duration, signalToNoise: Float? = nil,
        elapsed: Duration = .zero
    ) {
        self.level = level
        self.speech = speech
        self.speechTarget = speechTarget
        self.signalToNoise = signalToNoise
        self.elapsed = elapsed
    }

    /// Progress toward ``speechTarget``, `0...1`.
    public var progress: Double {
        guard speechTarget > .zero else { return 1 }
        return min(1, max(0, speech / speechTarget))
    }
}

/// Collects one enrollment clip from captured frames and decides when it is
/// done.
///
/// A clip ends by itself once it holds the plan's ``EnrollmentPlan/speechPerClip``
/// of talking time and the user has paused for ``EnrollmentPlan/trailingSilence``,
/// or when it reaches ``EnrollmentPlan/maximumClipDuration``. The user can
/// also end it early (the guided capture's Done button). Timing comes from
/// the audio itself (sample counts), not a wall clock, so a test feeding
/// fixture frames gets exactly what a device would.
public struct EnrollmentClipRecorder: Sendable {
    /// Why a clip ended.
    public enum Completion: Hashable, Sendable {
        /// Enough speech, then a pause.
        case enoughSpeech
        /// The maximum clip length.
        case timeLimit
    }

    public let plan: EnrollmentPlan
    public let sampleRate: Int

    private var samples: [Float] = []
    private var startOffset: Int64?
    private var tracker: EnrollmentLevelTracker
    public private(set) var completion: Completion?

    public init(plan: EnrollmentPlan, analyzer: EnrollmentLevelAnalyzer = EnrollmentLevelAnalyzer()) {
        self.plan = plan
        self.sampleRate = AudioFrame.captureSampleRate
        self.tracker = EnrollmentLevelTracker(analyzer: analyzer, sampleRate: sampleRate)
        samples.reserveCapacity(Int(plan.maximumClipDuration.sampleCount(sampleRate: sampleRate)))
    }

    /// Whether the clip has ended by itself.
    public var isComplete: Bool { completion != nil }

    /// How much audio has been recorded.
    public var duration: Duration { .samples(Int64(samples.count), sampleRate: sampleRate) }

    /// The meter's current reading.
    public var meter: EnrollmentMeter {
        EnrollmentMeter(
            level: Self.meterLevel(tracker.energy), speech: tracker.speechDuration, speechTarget: plan.speechPerClip,
            signalToNoise: tracker.signalToNoise, elapsed: duration)
    }

    /// Adds a captured frame. Frames after the clip completed are ignored,
    /// and a frame that would run past the maximum length is cut.
    ///
    /// - Precondition: `frame` is at the capture rate (16 kHz).
    public mutating func append(_ frame: AudioFrame) {
        precondition(frame.sampleRate == sampleRate, "Enrollment records \(sampleRate) Hz audio")
        guard completion == nil, !frame.isEmpty else { return }
        if startOffset == nil { startOffset = frame.sampleOffset }
        let limit = Int(plan.maximumClipDuration.sampleCount(sampleRate: sampleRate))
        let take = Array(frame.samples.prefix(limit - samples.count))
        samples.append(contentsOf: take)
        tracker.append(take)
        if samples.count >= limit {
            completion = .timeLimit
        } else if tracker.speechDuration >= plan.speechPerClip, tracker.silenceSinceSpeech >= plan.trailingSilence {
            completion = .enoughSpeech
        }
    }

    /// The audio recorded so far, positioned at the first frame's offset.
    public var clip: AudioFrame {
        AudioFrame(samples: samples, sampleRate: sampleRate, sampleOffset: startOffset ?? 0)
    }

    /// An energy in dBFS on the meter's `0...1` scale.
    static func meterLevel(_ decibels: Float, floor: Float = -60) -> Float {
        (min(max(decibels, floor), 0) - floor) / -floor
    }
}
