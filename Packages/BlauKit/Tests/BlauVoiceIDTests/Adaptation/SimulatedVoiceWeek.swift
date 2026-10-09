import Foundation

@testable import BlauVoiceID

/// A deterministic random number generator (SplitMix64), so every
/// simulated week is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A standard normal sample (Box-Muller).
    mutating func gaussian() -> Float {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }

    /// A random unit vector.
    mutating func direction(dimension: Int) -> [Float] {
        normalized((0..<dimension).map { _ in gaussian() })
    }
}

func normalized(_ vector: [Float]) -> [Float] {
    let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return vector.map { $0 / norm }
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

/// `cosine · a + sin · (the part of b orthogonal to a)`: a unit vector at
/// `cosine` from `a`, towards `b`.
func rotate(_ a: [Float], toward b: [Float], cosine: Float) -> [Float] {
    let along = dot(a, b)
    let orthogonal = normalized(zip(b, a).map { $0 - along * $1 })
    let sine = (1 - cosine * cosine).squareRoot()
    return normalized(zip(a, orthogonal).map { cosine * $0 + sine * $1 })
}

/// A synthetic week of conversations for adaptive voiceprint updates (#49):
/// WeSpeaker-like 256-d embeddings of the owner, whose voice changes over
/// the days, and of other people and loudspeakers in the room.
///
/// **Geometry.** Every speaker has a true voice direction. A segment's
/// embedding is that direction plus Gaussian noise whose size grows as the
/// segment gets shorter and the room noisier, normalized: about 0.6 cosine
/// with the true direction for a clean 3 s segment. Each conversation adds a
/// small channel offset of its own (where the phone is, which microphone).
/// The owner enrolled on day 0 with four clean 5 s clips.
///
/// **Other speakers** are a pool of voices at random angles to the owner,
/// most nearly orthogonal, a few close (a relative, a similar-sounding
/// presenter), plus optional `housemates` close to the owner who talk in
/// every conversation.
///
/// Scores against the enrollment centroid at 3 s come out at about
/// 0.55 ± 0.08 for the owner and 0.0 ± 0.1 for others, with a tail past
/// `T_hi` for the close voices: the same picture as the calibration set
/// (docs/voice-id-eval.md).
struct SimulatedVoiceWeek {
    struct Parameters {
        var seed: UInt64 = 49
        var dimension = 256
        var days = 7
        var sessionsPerDay = 3
        var ownerSegmentsPerSession = 40
        var otherSegmentsPerSession = 200
        /// Cosine between the owner's voice on the last day and on the
        /// enrollment day: a gradual, steady change (1 = none).
        var finalDayCosine: Float = 1
        /// Days with an extra, temporary change (a cold), and its size.
        var temporaryChange: (days: ClosedRange<Int>, cosine: Float)?
        /// The other voices' pool.
        var otherSpeakers = 40
        /// Speakers close to the owner who talk in every conversation, and
        /// their cosine with the owner's voice.
        var housemates = 0
        var housemateCosine: Float = 0.55
        /// The share of segments recorded in a noisy room (more noise, lower
        /// SNR).
        var noisyShare = 0.25
        /// Noise size for a clean 3 s segment (`|noise|` relative to the
        /// unit voice).
        var cleanNoise: Float = 1.25
        /// Per-conversation channel offset size.
        var channelNoise: Float = 0.3
    }

    let parameters: Parameters
    let voiceprint: Voiceprint
    let sessions: [VoiceprintAdaptationSession]
    /// The owner's true voice on each day.
    let ownerVoice: [[Float]]

    static let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM

    init(_ parameters: Parameters = Parameters()) {
        self.parameters = parameters
        var random = SeededGenerator(seed: parameters.seed)
        let dimension = parameters.dimension
        let owner = random.direction(dimension: dimension)
        let trend = random.direction(dimension: dimension)
        let coldDirection = random.direction(dimension: dimension)

        // The owner's voice, day by day.
        var voices: [[Float]] = []
        for day in 0..<parameters.days {
            let progress = parameters.days > 1 ? Float(day) / Float(parameters.days - 1) : 0
            // Interpolate the angle so the change is steady.
            let angle = acos(min(1, parameters.finalDayCosine)) * progress
            var voice = rotate(owner, toward: trend, cosine: cos(angle))
            if let change = parameters.temporaryChange, change.days.contains(day) {
                voice = rotate(voice, toward: coldDirection, cosine: change.cosine)
            }
            voices.append(voice)
        }
        ownerVoice = voices

        var others: [[Float]] = []
        for index in 0..<parameters.otherSpeakers {
            // Mostly unrelated voices; the closest few reach 0.5.
            let closeness = 0.5 * pow(Float(index) / Float(max(1, parameters.otherSpeakers - 1)), 3)
            others.append(rotate(owner, toward: random.direction(dimension: dimension), cosine: closeness))
        }
        let housemates = (0..<parameters.housemates).map { _ in
            rotate(owner, toward: random.direction(dimension: dimension), cosine: parameters.housemateCosine)
        }

        // Enrollment: four clean 5 s clips on day 0.
        let clips = (0..<4).map { _ in
            Self.embedding(
                voices[0], duration: 5, noise: parameters.cleanNoise * 0.85, channel: nil, random: &random)
        }
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        voiceprint = Voiceprint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000049")!, name: "Me",
            modelIdentifier: Self.model.identifier, centroid: SpeakerEmbedding.mean(of: clips)!,
            sets: [VoiceprintSet(deviceModel: "iPhone18,1", embeddings: clips, createdAt: createdAt)],
            createdAt: createdAt, updatedAt: createdAt)

        var sessions: [VoiceprintAdaptationSession] = []
        for day in 0..<parameters.days {
            for _ in 0..<parameters.sessionsPerDay {
                let channel = (0..<dimension).map { _ in
                    random.gaussian() * parameters.channelNoise / Float(dimension).squareRoot()
                }
                var trials: [VoiceprintAdaptationTrial] = []
                for _ in 0..<parameters.ownerSegmentsPerSession {
                    trials.append(Self.trial(voices[day], isOwner: true, channel: channel, parameters, &random))
                }
                for index in 0..<parameters.otherSegmentsPerSession {
                    let voice: [Float]
                    if !housemates.isEmpty, index % 2 == 0 {
                        voice = housemates[index / 2 % housemates.count]
                    } else {
                        voice = others[Int.random(in: 0..<others.count, using: &random)]
                    }
                    // Other voices come through their own channel (a TV, the
                    // other side of the room), not the owner's.
                    trials.append(Self.trial(voice, isOwner: false, channel: nil, parameters, &random))
                }
                trials.shuffle(using: &random)
                sessions.append(VoiceprintAdaptationSession(day: day, trials: trials))
            }
        }
        self.sessions = sessions
    }

    /// One segment: 1.5 - 8 s of speech, clean or noisy.
    static func trial(
        _ voice: [Float], isOwner: Bool, channel: [Float]?, _ parameters: Parameters, _ random: inout SeededGenerator
    ) -> VoiceprintAdaptationTrial {
        let duration = Double.random(in: 1.5...8, using: &random)
        let noisy = Double.random(in: 0..<1, using: &random) < parameters.noisyShare
        let snr: Float = noisy ? Float.random(in: 5...16, using: &random) : Float.random(in: 16...35, using: &random)
        // Shorter and noisier segments carry less of the voice.
        var noise = parameters.cleanNoise * Float(pow(3 / duration, 0.35))
        if noisy { noise *= 1.3 }
        noise *= Float.random(in: 0.85...1.15, using: &random)
        let embedding = embedding(voice, duration: duration, noise: noise, channel: channel, random: &random)
        return VoiceprintAdaptationTrial(
            embedding: embedding, isOwner: isOwner, speechDuration: .seconds(duration), signalToNoise: snr)
    }

    static func embedding(
        _ voice: [Float], duration: Double, noise: Float, channel: [Float]?, random: inout SeededGenerator
    ) -> SpeakerEmbedding {
        let scale = noise / Float(voice.count).squareRoot()
        var vector = voice.map { $0 + random.gaussian() * scale }
        if let channel { vector = zip(vector, channel).map(+) }
        return SpeakerEmbedding(
            normalizing: vector, modelIdentifier: model.identifier, audioDuration: .seconds(duration))!
    }
}
