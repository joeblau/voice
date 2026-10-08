import Accelerate
import BlauCore

/// Level, noise and speech measurements of one recorded enrollment clip:
/// what the quality meter shows and ``EnrollmentQualityPolicy`` judges.
///
/// The clip is cut into 20 ms frames and each frame's energy taken in dBFS.
/// The noise floor is a low percentile of those energies (the room between
/// words and before the user starts), and frames well above it are speech.
/// Gaps between speech frames of up to ``EnrollmentLevelAnalyzer/bridgedGap``
/// (the pauses between syllables and words) count as speech, so
/// ``speechDuration`` is talking time rather than voiced time.
///
/// Capture runs through voice processing (VPIO), which already suppresses
/// steady noise, so the noise floor is usually low; what this catches is
/// what VPIO can't remove: a TV, other voices, wind, a clip that is mostly
/// silence, or a voice so loud it clips.
public struct EnrollmentClipAnalysis: Hashable, Sendable {
    /// The whole clip's length.
    public let duration: Duration

    /// Talking time: speech frames plus the short pauses between them.
    public let speechDuration: Duration

    /// Mean energy of the speech frames, in dBFS. Equal to ``noiseLevel``
    /// when the clip has no speech.
    public let speechLevel: Float

    /// Mean energy of the frames that aren't speech, in dBFS (the noise
    /// floor percentile when every frame is speech).
    public let noiseLevel: Float

    /// The fraction of samples at or near full scale.
    public let clippedFraction: Double

    /// The samples from just before the first speech frame to just after the
    /// last one: what gets embedded, so leading and trailing silence don't
    /// dilute the voiceprint. Empty when the clip has no speech.
    public let speechRange: Range<Int>

    public init(
        duration: Duration,
        speechDuration: Duration,
        speechLevel: Float,
        noiseLevel: Float,
        clippedFraction: Double,
        speechRange: Range<Int>
    ) {
        self.duration = duration
        self.speechDuration = speechDuration
        self.speechLevel = speechLevel
        self.noiseLevel = noiseLevel
        self.clippedFraction = clippedFraction
        self.speechRange = speechRange
    }

    /// Speech level over noise level, in dB. `0` without speech.
    public var signalToNoise: Float { speechLevel - noiseLevel }

    /// Whether any speech was detected.
    public var hasSpeech: Bool { speechDuration > .zero }

    /// Analyzes `clip`.
    public init(analyzing clip: AudioFrame, analyzer: EnrollmentLevelAnalyzer = EnrollmentLevelAnalyzer()) {
        self = analyzer.analyze(clip)
    }
}

/// Measures clips for ``EnrollmentClipAnalysis`` and drives the live meter
/// (``EnrollmentLevelTracker``) with the same thresholds.
public struct EnrollmentLevelAnalyzer: Hashable, Sendable {
    /// Analysis frame: 20 ms, the capture hub's frame length.
    public static let frameDuration: Duration = .milliseconds(20)

    /// Pauses between speech frames up to this long count as speech.
    public static let bridgedGap: Duration = .milliseconds(160)

    /// Speech context kept on each side of ``EnrollmentClipAnalysis/speechRange``.
    public static let speechPadding: Duration = .milliseconds(100)

    /// The energy reported for digital silence, in dBFS.
    public static let floorDecibels: Float = -100

    /// A frame is speech when it is at least this far above the noise floor.
    public var speechMargin: Float

    /// ...and at least this loud in absolute terms, so a near-silent room's
    /// faint rustle never counts as speech.
    public var minimumSpeechEnergy: Float

    /// The percentile of frame energies taken as the noise floor.
    public var noisePercentile: Double

    /// Samples at or above this magnitude count as clipped.
    public var clipLevel: Float

    public init(
        speechMargin: Float = 10,
        minimumSpeechEnergy: Float = -60,
        noisePercentile: Double = 0.1,
        clipLevel: Float = 0.999
    ) {
        precondition((0...1).contains(noisePercentile), "The noise percentile must be in 0...1")
        self.speechMargin = speechMargin
        self.minimumSpeechEnergy = minimumSpeechEnergy
        self.noisePercentile = noisePercentile
        self.clipLevel = clipLevel
    }

    /// Samples in one analysis frame at `sampleRate`.
    static func frameLength(sampleRate: Int) -> Int {
        max(1, Int(frameDuration.sampleCount(sampleRate: sampleRate)))
    }

    /// The energy of `samples` in dBFS (mean square, so a full-scale sine is
    /// about -3 dBFS), floored at ``floorDecibels``.
    static func decibels(meanSquare: Float) -> Float {
        guard meanSquare > 0, meanSquare.isFinite else { return floorDecibels }
        return max(10 * log10(meanSquare), floorDecibels)
    }

    static func meanSquare(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { vDSP.meanSquare($0) }
    }

    /// Whether a frame of `energy` dBFS is speech over a `noiseFloor`.
    func isSpeech(_ energy: Float, noiseFloor: Float) -> Bool {
        energy >= max(noiseFloor + speechMargin, minimumSpeechEnergy)
    }

    public func analyze(_ clip: AudioFrame) -> EnrollmentClipAnalysis {
        let frameLength = Self.frameLength(sampleRate: clip.sampleRate)
        let samples = clip.samples
        var energies: [Float] = []
        var powers: [Float] = []
        energies.reserveCapacity(samples.count / frameLength + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frameLength, samples.count)
            let power = Self.meanSquare(samples[start..<end])
            powers.append(power)
            energies.append(Self.decibels(meanSquare: power))
            start = end
        }
        let clipped = samples.isEmpty ? 0 : Double(samples.count { abs($0) >= clipLevel }) / Double(samples.count)
        guard !energies.isEmpty else {
            return EnrollmentClipAnalysis(
                duration: .zero, speechDuration: .zero, speechLevel: Self.floorDecibels,
                noiseLevel: Self.floorDecibels, clippedFraction: 0, speechRange: 0..<0)
        }

        let sorted = energies.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * noisePercentile).rounded()))]
        let voiced = energies.map { isSpeech($0, noiseFloor: noiseFloor) }

        // Talking time: voiced frames with short pauses between them filled.
        let bridged = Self.bridge(voiced, maximumGap: Self.frames(in: Self.bridgedGap))
        let speechFrames = bridged.count(where: \.self)

        var speechPower: Float = 0
        var speechCount = 0
        var noisePower: Float = 0
        var noiseCount = 0
        for index in powers.indices {
            if voiced[index] {
                speechPower += powers[index]
                speechCount += 1
            } else if !bridged[index] {
                noisePower += powers[index]
                noiseCount += 1
            }
        }
        let noiseLevel = noiseCount > 0 ? Self.decibels(meanSquare: noisePower / Float(noiseCount)) : noiseFloor
        let speechLevel = speechCount > 0 ? Self.decibels(meanSquare: speechPower / Float(speechCount)) : noiseLevel

        var speechRange = 0..<0
        if let first = bridged.firstIndex(of: true), let last = bridged.lastIndex(of: true) {
            let padding = Int(Self.speechPadding.sampleCount(sampleRate: clip.sampleRate))
            let lower = max(0, first * frameLength - padding)
            let upper = min(samples.count, (last + 1) * frameLength + padding)
            speechRange = lower..<upper
        }

        return EnrollmentClipAnalysis(
            duration: clip.duration,
            speechDuration: Self.frameDuration * speechFrames,
            speechLevel: speechLevel,
            noiseLevel: noiseLevel,
            clippedFraction: clipped,
            speechRange: speechRange
        )
    }

    /// Whole analysis frames in `duration`.
    static func frames(in duration: Duration) -> Int {
        Int(duration / frameDuration)
    }

    /// `flags` with every run of `false` of at most `maximumGap` between two
    /// `true`s set to `true`.
    static func bridge(_ flags: [Bool], maximumGap: Int) -> [Bool] {
        var result = flags
        var lastTrue: Int?
        for index in flags.indices where flags[index] {
            if let previous = lastTrue, index - previous - 1 <= maximumGap {
                for gap in (previous + 1)..<index { result[gap] = true }
            }
            lastTrue = index
        }
        return result
    }
}

/// Follows a clip while it records, for the live quality meter and for
/// deciding when the clip has enough speech.
///
/// The noise floor tracks the quietest recent frame: it drops at once to a
/// quieter frame and otherwise rises slowly (``noiseRise`` per second), so a
/// burst of speech never becomes the floor but a room that gets noisier is
/// followed. The final judgement uses ``EnrollmentClipAnalysis`` over the
/// whole clip, which can look ahead.
public struct EnrollmentLevelTracker: Hashable, Sendable {
    /// How fast the noise floor rises when no frame is quieter, in dB per
    /// second.
    public static let noiseRise: Float = 3

    public let analyzer: EnrollmentLevelAnalyzer
    public let sampleRate: Int

    /// The latest frame's energy, in dBFS.
    public private(set) var energy: Float = EnrollmentLevelAnalyzer.floorDecibels
    /// The tracked noise floor, in dBFS, or `nil` before the first frame.
    public private(set) var noiseFloor: Float?
    /// Talking time so far (speech frames and the pauses bridged between
    /// them).
    public private(set) var speechDuration: Duration = .zero
    /// How long since the last speech frame (or since the start, before
    /// any speech).
    public private(set) var silenceSinceSpeech: Duration = .zero
    /// Mean speech energy so far in dBFS, `nil` before any speech.
    public private(set) var speechLevel: Float?

    private var pending: [Float] = []
    private var gapFrames = 0
    private var hasSpeech = false
    private var speechPower: Double = 0
    private var speechFrames = 0

    public init(
        analyzer: EnrollmentLevelAnalyzer = EnrollmentLevelAnalyzer(), sampleRate: Int = AudioFrame.captureSampleRate
    ) {
        self.analyzer = analyzer
        self.sampleRate = sampleRate
    }

    /// The live signal-to-noise estimate in dB, `nil` before any speech.
    public var signalToNoise: Float? {
        guard let speechLevel, let noiseFloor else { return nil }
        return speechLevel - noiseFloor
    }

    /// Feeds captured samples; whole 20 ms frames are measured, the rest
    /// waits for the next call.
    public mutating func append(_ samples: [Float]) {
        let frameLength = EnrollmentLevelAnalyzer.frameLength(sampleRate: sampleRate)
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= frameLength {
            measure(pending[start..<(start + frameLength)])
            start += frameLength
        }
        pending.removeFirst(start)
    }

    private mutating func measure(_ frame: ArraySlice<Float>) {
        let power = EnrollmentLevelAnalyzer.meanSquare(frame)
        let energy = EnrollmentLevelAnalyzer.decibels(meanSquare: power)
        self.energy = energy
        let rise = Self.noiseRise * Float(EnrollmentLevelAnalyzer.frameDuration / .seconds(1))
        let floor = noiseFloor.map { min(energy, $0 + rise) } ?? energy
        noiseFloor = floor

        let frameDuration = EnrollmentLevelAnalyzer.frameDuration
        if analyzer.isSpeech(energy, noiseFloor: floor) {
            if hasSpeech, gapFrames <= EnrollmentLevelAnalyzer.frames(in: EnrollmentLevelAnalyzer.bridgedGap) {
                speechDuration += frameDuration * gapFrames
            }
            hasSpeech = true
            gapFrames = 0
            speechDuration += frameDuration
            silenceSinceSpeech = .zero
            speechPower += Double(power)
            speechFrames += 1
            speechLevel = EnrollmentLevelAnalyzer.decibels(meanSquare: Float(speechPower / Double(speechFrames)))
        } else {
            gapFrames += 1
            silenceSinceSpeech += frameDuration
        }
    }
}
