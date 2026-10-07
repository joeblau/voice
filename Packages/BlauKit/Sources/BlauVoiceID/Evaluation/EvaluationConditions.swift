import Accelerate
import BlauCore
import Foundation

/// A listening condition the harness simulates on top of each probe: a room,
/// background noise, a loudspeaker, another talker.
///
/// Real recordings in different rooms and at different distances are the
/// ground truth (tag them in the manifest); simulated conditions stretch a
/// small set of clean recordings over the situations the gate meets, so
/// thresholds aren't tuned on studio audio alone.
public struct VoiceIDCondition: Hashable, Codable, Sendable, Identifiable {
    /// Short identifier for reports, e.g. `room-far`.
    public let name: String
    /// One line for the report.
    public let summary: String
    /// Applied in order.
    public let steps: [Step]
    /// Whether target trials are scored under this condition. `false` for
    /// media playback: the owner's voice from a loudspeaker (a voice memo, a
    /// video) is not someone Blau should answer, so only its false accepts
    /// matter.
    public let scoresTargetTrials: Bool

    public var id: String { name }

    public enum NoiseKind: String, Hashable, Codable, Sendable {
        /// White Gaussian noise.
        case white
        /// Pink noise: room tone, fans, traffic.
        case pink
        /// Several cohort talkers at once: a café, a party.
        case babble
    }

    public enum Step: Hashable, Codable, Sendable {
        /// A simulated room (``EvaluationDSP/roomImpulseResponse(rt60:directToReverberantRatio:sampleRate:seed:)``).
        /// Output is scaled back to the input's level, as the capture AGC
        /// would.
        case reverberation(rt60: Double, directToReverberantRatio: Double)
        /// Additive noise at `snr` dB.
        case noise(NoiseKind, snr: Double)
        /// A small loudspeaker: band-limited to `lowCut...highCut` Hz
        /// (fourth-order slopes) and softly saturated (`drive` 1 is nearly
        /// clean, 4 is heavily compressed).
        case loudspeaker(lowCut: Double, highCut: Double, drive: Double)
        /// One cohort talker underneath, `signalToInterferenceRatio` dB
        /// quieter than the probe's talker.
        case overlap(signalToInterferenceRatio: Double)
    }

    public init(name: String, summary: String, steps: [Step], scoresTargetTrials: Bool = true) {
        self.name = name
        self.summary = summary
        self.steps = steps
        self.scoresTargetTrials = scoresTargetTrials
    }

    /// Whether the condition needs cohort recordings as interfering talkers.
    public var needsInterferers: Bool {
        steps.contains { step in
            switch step {
            case .noise(.babble, _), .overlap: true
            default: false
            }
        }
    }

    /// The recording as is.
    public static let clean = VoiceIDCondition(name: "clean", summary: "The recording as is", steps: [])

    /// Phone held close in a small, furnished room.
    public static let roomNear = VoiceIDCondition(
        name: "room-near",
        summary: "Small room, phone close (RT60 0.3 s, DRR +8 dB), room tone at 30 dB SNR",
        steps: [.reverberation(rt60: 0.3, directToReverberantRatio: 8), .noise(.pink, snr: 30)]
    )

    /// Phone on a table across a living room.
    public static let roomFar = VoiceIDCondition(
        name: "room-far",
        summary: "Living room, phone 2-3 m away (RT60 0.6 s, DRR -3 dB), room tone at 15 dB SNR",
        steps: [.reverberation(rt60: 0.6, directToReverberantRatio: -3), .noise(.pink, snr: 15)]
    )

    /// A busy café.
    public static let babble = VoiceIDCondition(
        name: "babble",
        summary: "Four background talkers at 10 dB SNR in a small room (RT60 0.4 s, DRR +3 dB)",
        steps: [.reverberation(rt60: 0.4, directToReverberantRatio: 3), .noise(.babble, snr: 10)]
    )

    /// A TV or a podcast on a speaker across the room. Impostor trials only.
    public static let loudspeaker = VoiceIDCondition(
        name: "loudspeaker",
        summary: "Played through a small speaker (200 Hz-5 kHz, saturated) across a living room (RT60 0.5 s, DRR 0 dB)",
        steps: [
            .loudspeaker(lowCut: 200, highCut: 5_000, drive: 2.5),
            .reverberation(rt60: 0.5, directToReverberantRatio: 0),
            .noise(.pink, snr: 25),
        ],
        scoresTargetTrials: false
    )

    /// Someone talking over the probe's talker.
    public static let overlap = VoiceIDCondition(
        name: "overlap",
        summary: "A second talker 6 dB below the probe's talker",
        steps: [.overlap(signalToInterferenceRatio: 6), .noise(.pink, snr: 30)]
    )

    /// Every built-in condition.
    public static let standard: [VoiceIDCondition] = [.clean, .roomNear, .roomFar, .babble, .loudspeaker, .overlap]

    /// Applies the steps to `samples` (16 kHz).
    ///
    /// - Parameters:
    ///   - seed: Seeds every random choice (noise, room, which interferers),
    ///     so the same probe always gets the same degraded audio.
    ///   - interferers: Cohort recordings to draw background talkers from.
    /// - Returns: `nil` if the condition needs interferers and none are
    ///   given.
    public func apply(to samples: [Float], seed: UInt64, interferers: [[Float]]) -> [Float]? {
        guard !samples.isEmpty else { return samples }
        if needsInterferers && interferers.isEmpty { return nil }
        let rate = AudioFrame.captureSampleRate
        var random = EvaluationDSP.Random(seed: seed)
        var audio = samples
        for step in steps {
            let stepSeed = random.next()
            switch step {
            case .reverberation(let rt60, let ratio):
                let response = EvaluationDSP.roomImpulseResponse(
                    rt60: rt60, directToReverberantRatio: ratio, sampleRate: rate, seed: stepSeed)
                let level = EvaluationDSP.power(audio)
                var wet = Array(EvaluationDSP.convolve(audio, response).prefix(audio.count))
                let wetLevel = EvaluationDSP.power(wet)
                if wetLevel > 0 { wet = vDSP.multiply((level / wetLevel).squareRoot(), wet) }
                audio = wet
            case .noise(let kind, let snr):
                let noise: [Float]
                switch kind {
                case .white: noise = EvaluationDSP.whiteNoise(count: audio.count, seed: stepSeed)
                case .pink: noise = EvaluationDSP.pinkNoise(count: audio.count, seed: stepSeed)
                case .babble: noise = Self.babble(count: audio.count, from: interferers, seed: stepSeed)
                }
                audio = EvaluationDSP.mix(audio, with: noise, snr: snr)
            case .loudspeaker(let lowCut, let highCut, let drive):
                audio = Self.loudspeaker(audio, lowCut: lowCut, highCut: highCut, drive: drive)
            case .overlap(let ratio):
                var choice = EvaluationDSP.Random(seed: stepSeed)
                let talker = interferers[Int(choice.next() % UInt64(interferers.count))]
                audio = EvaluationDSP.mix(audio, with: talker, snr: ratio)
            }
        }
        return EvaluationDSP.limitPeak(audio)
    }

    /// Four interferers at equal level, summed (each repeated or cut to
    /// `count` and started at a seeded offset).
    static func babble(count: Int, from interferers: [[Float]], seed: UInt64) -> [Float] {
        var random = EvaluationDSP.Random(seed: seed)
        var sum = [Float](repeating: 0, count: count)
        for _ in 0..<4 {
            let talker = interferers[Int(random.next() % UInt64(interferers.count))]
            guard !talker.isEmpty else { continue }
            let offset = Int(random.next() % UInt64(talker.count))
            let rotated = Array(talker[offset...] + talker[..<offset])
            let fitted = EvaluationDSP.fit(rotated, count: count)
            let level = EvaluationDSP.power(fitted)
            guard level > 0 else { continue }
            sum = vDSP.add(multiplication: (fitted, 1 / level.squareRoot()), sum)
        }
        return sum
    }

    static func loudspeaker(_ samples: [Float], lowCut: Double, highCut: Double, drive: Double) -> [Float] {
        let rate = AudioFrame.captureSampleRate
        let level = EvaluationDSP.power(samples)
        let band = EvaluationDSP.filter(
            samples,
            sections: [
                .highPass(cutoff: lowCut, sampleRate: rate), .highPass(cutoff: lowCut, sampleRate: rate),
                .lowPass(cutoff: highCut, sampleRate: rate), .lowPass(cutoff: highCut, sampleRate: rate),
            ])
        let peak = band.isEmpty ? 0 : vDSP.maximumMagnitude(band)
        guard peak > 0 else { return band }
        let gain = Float(drive) / peak
        let normalizer = tanh(Float(drive))
        var saturated = band.map { tanh($0 * gain) / normalizer }
        let saturatedLevel = EvaluationDSP.power(saturated)
        if saturatedLevel > 0 { saturated = vDSP.multiply((level / saturatedLevel).squareRoot(), saturated) }
        return saturated
    }
}

/// Audio processing to evaluate in front of the embedder, such as a noise
/// suppressor (DeepFilterNet3, #51). The harness runs every probe and
/// enrollment clip through it after the condition is applied, and reports
/// each preprocessor next to the unprocessed baseline.
public protocol VoiceIDAudioPreprocessor: Sendable {
    /// Short identifier for reports, e.g. `deepfilternet3`.
    var name: String { get }

    /// Processes 16 kHz mono audio. The output must be 16 kHz too.
    func process(_ audio: AudioFrame) async throws -> AudioFrame
}
