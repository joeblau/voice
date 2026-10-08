import BlauCore
import Foundation
import Synchronization

/// A ``SpeakerEmbedder`` without a model, for tests, previews and UI tests.
///
/// It recognizes ``ScriptedEnrollmentAudio``'s voices: the zero-crossing
/// rate of the loud samples gives the tone's fundamental, which picks a
/// fixed pseudo-random direction (one per 25 Hz band, so different voices
/// are nearly orthogonal), and each segment adds a small perturbation of its
/// own. Same-voice embeddings score about 0.9 with each other, different
/// voices near 0.
public final class ScriptedSpeakerEmbedder: SpeakerEmbedder {
    public let model: SpeakerEmbeddingModelInfo
    public let minimumDuration: Duration
    private let delay: Duration
    private let clock: any BlauClock
    private let segments = Mutex<[AudioFrame]>([])

    /// - Parameters:
    ///   - model: The model the embeddings claim to come from.
    ///   - delay: How long each call takes, on `clock`.
    public init(
        model: SpeakerEmbeddingModelInfo = .weSpeakerResNet34LM, minimumDuration: Duration = .milliseconds(500),
        delay: Duration = .zero, clock: any BlauClock = SystemClock()
    ) {
        self.model = model
        self.minimumDuration = minimumDuration
        self.delay = delay
        self.clock = clock
    }

    /// Every segment embedded so far.
    public var embeddedSegments: [AudioFrame] { segments.withLock { $0 } }

    public func embed(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding] {
        if delay > .zero { try await clock.sleep(for: delay) }
        self.segments.withLock { $0.append(contentsOf: segments) }
        return try segments.map { segment in
            guard segment.duration >= minimumDuration else {
                throw SpeakerEmbedderError.segmentTooShort(segment.duration, minimum: minimumDuration)
            }
            let band = Self.band(of: segment)
            var vector = Self.direction(seed: UInt64(band) &+ 1, dimension: model.dimension)
            let perturbation = Self.direction(seed: UInt64(segment.sampleCount) &* 31 &+ 7, dimension: model.dimension)
            for index in vector.indices { vector[index] += 0.35 * perturbation[index] }
            guard
                let embedding = SpeakerEmbedding(
                    normalizing: vector, modelIdentifier: model.identifier, audioDuration: segment.duration)
            else { throw SpeakerEmbedderError.invalidOutput }
            return embedding
        }
    }

    /// The 25 Hz band of the segment's fundamental, from the zero-crossing
    /// rate of its loud samples.
    static func band(of segment: AudioFrame) -> Int {
        var crossings = 0
        var loud = 0
        var previous: Float = 0
        for sample in segment.samples {
            // Quiet samples (near a crossing, between syllables) are skipped;
            // the sign is compared with the previous loud sample.
            guard abs(sample) > 0.005 else { continue }
            loud += 1
            if previous != 0, (previous < 0) != (sample < 0) { crossings += 1 }
            previous = sample
        }
        guard loud > 0 else { return 0 }
        // A tone at f Hz crosses zero 2f times a second (its harmonic adds
        // a few more; the band absorbs them).
        let frequency = Double(crossings) / 2 / (Double(loud) / Double(segment.sampleRate))
        return Int((frequency / 25).rounded())
    }

    /// A deterministic unit-ish vector for `seed`.
    static func direction(seed: UInt64, dimension: Int) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<dimension).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1) / Float(dimension).squareRoot() * 1.7
        }
    }
}
