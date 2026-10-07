import Accelerate
import BlauCore
import Foundation

@testable import BlauVoiceID

/// A stand-in for the WeSpeaker model that still listens to the audio: the
/// embedding is the energy in 16 frequency bands (Goertzel at 150, 250 ...
/// 1650 Hz). Synthetic speakers with different pitches land in different
/// bands, and noise, rooms and other talkers blur them, so scores behave
/// like a (much weaker) speaker model's: separable when clean, overlapping
/// under the harder conditions.
struct BandEnergyEmbedder: SpeakerEmbedder {
    static let bands: [Double] = (0..<16).map { 150 + 100 * Double($0) }

    let model = SpeakerEmbeddingModelInfo(identifier: "band-energy@test", dimension: 16)
    let minimumDuration: Duration = .milliseconds(500)

    func embed(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding] {
        try segments.map { segment in
            guard segment.duration >= minimumDuration else {
                throw SpeakerEmbedderError.segmentTooShort(segment.duration, minimum: minimumDuration)
            }
            let energies = Self.bands.map {
                Self.goertzel(segment.samples, frequency: $0, sampleRate: segment.sampleRate)
            }
            // Log compression, like a filterbank front end, then centre.
            let logs = energies.map { Float(log10($0 + 1e-6)) }
            let centred = vDSP.add(-vDSP.mean(logs), logs)
            guard
                let embedding = SpeakerEmbedding(
                    normalizing: centred, modelIdentifier: model.identifier, audioDuration: segment.duration)
            else { throw SpeakerEmbedderError.invalidOutput }
            return embedding
        }
    }

    static func goertzel(_ samples: [Float], frequency: Double, sampleRate: Int) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / Double(sampleRate))
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(samples.count * samples.count)
    }
}

/// Synthetic "speech": a speaker-specific pitch with two harmonics, syllable
/// rate amplitude modulation and a little noise. `variant` changes the
/// pitch slightly and the noise, like another utterance by the same person.
func syntheticVoice(pitch: Double, seconds: Double, variant: Int) -> AudioFrame {
    let rate = Double(AudioFrame.captureSampleRate)
    var random = EvaluationDSP.Random(seed: UInt64(pitch * 100) &+ UInt64(variant))
    let jitter = 1 + 0.02 * Double(random.nextSigned())
    let f0 = pitch * jitter
    let samples = (0..<Int(seconds * rate)).map { index -> Float in
        let time = Double(index) / rate
        let envelope = 0.55 + 0.45 * sin(2 * .pi * (3.5 + Double(variant % 3) * 0.5) * time)
        let voiced = sin(2 * .pi * f0 * time) + 0.5 * sin(2 * .pi * 2 * f0 * time) + 0.25 * sin(2 * .pi * 3 * f0 * time)
        return Float(0.2 * envelope * voiced) + 0.01 * random.nextGaussian()
    }
    return AudioFrame(samples: samples, sampleOffset: 0)
}

/// A dataset of synthetic speakers: `targets` speakers with 3 enrollment
/// clips and `probesPerSpeaker` probes each, and `cohort` other speakers
/// with 3 clips each (or none).
func syntheticDataset(
    targets: Int = 5, probesPerSpeaker: Int = 3, cohort: Int = 4, probeSeconds: Double = 3.2,
    consent: String = "synthetic test audio"
) throws -> VoiceIDEvaluationDataset {
    var recordings: [VoiceIDEvaluationRecording] = []
    for speaker in 0..<targets {
        let pitch = 180 + 130 * Double(speaker)
        for clip in 0..<3 {
            recordings.append(
                VoiceIDEvaluationRecording(
                    id: "t\(speaker)/enroll\(clip)", speaker: "t\(speaker)", role: .enrollment,
                    audio: syntheticVoice(pitch: pitch, seconds: 4, variant: clip)))
        }
        for probe in 0..<probesPerSpeaker {
            recordings.append(
                VoiceIDEvaluationRecording(
                    id: "t\(speaker)/probe\(probe)", speaker: "t\(speaker)", role: .probe,
                    source: speaker == targets - 1 ? .tv : .person,
                    tags: ["room": probe % 2 == 0 ? "kitchen" : "office"],
                    audio: syntheticVoice(pitch: pitch, seconds: probeSeconds, variant: 10 + probe)))
        }
    }
    for speaker in 0..<cohort {
        for clip in 0..<3 {
            recordings.append(
                VoiceIDEvaluationRecording(
                    id: "c\(speaker)/\(clip)", speaker: "c\(speaker)", role: .cohort,
                    audio: syntheticVoice(pitch: 240 + 130 * Double(speaker), seconds: 3, variant: 20 + clip)))
        }
    }
    return try VoiceIDEvaluationDataset(name: "synthetic", consent: consent, recordings: recordings)
}

/// Halves the level: a stand-in preprocessor.
struct HalfGainPreprocessor: VoiceIDAudioPreprocessor {
    let name = "half-gain"

    func process(_ audio: AudioFrame) async throws -> AudioFrame {
        AudioFrame(samples: vDSP.multiply(0.5, audio.samples), sampleOffset: audio.sampleOffset)
    }
}

/// Files in the repository, found relative to this source file.
enum RepoFiles {
    static func url(_ path: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // Evaluation
            .deletingLastPathComponent()  // BlauVoiceIDTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // BlauKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appending(path: path)
    }
}

/// Returns 8 kHz audio: a broken preprocessor.
struct WrongRatePreprocessor: VoiceIDAudioPreprocessor {
    let name = "wrong-rate"

    func process(_ audio: AudioFrame) async throws -> AudioFrame {
        AudioFrame(samples: audio.samples, sampleRate: 8_000, sampleOffset: 0)
    }
}
