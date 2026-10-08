import BlauCore
import Foundation

@testable import BlauVoiceID

/// Synthetic audio for the enrollment tests: `ScriptedEnrollmentAudio`'s
/// voices rendered to one clip.
enum EnrollmentAudio {
    /// `duration` of `voice`, as one 16 kHz frame.
    static func clip(_ voice: ScriptedEnrollmentAudio.Voice = .owner, duration: Duration = .seconds(8)) -> AudioFrame {
        var synthesizer = ScriptedEnrollmentAudio.Synthesizer(voice: voice, seed: 1)
        var samples: [Float] = []
        let count = Int(duration.sampleCount(sampleRate: AudioFrame.captureSampleRate))
        while samples.count < count {
            samples.append(contentsOf: synthesizer.next().samples)
        }
        return AudioFrame(samples: Array(samples.prefix(count)), sampleOffset: 0)
    }

    /// Splits `clip` into 20 ms frames, as the capture hub delivers them.
    static func frames(of clip: AudioFrame) -> [AudioFrame] {
        stride(from: 0, to: clip.sampleCount, by: 320).map { start in
            let end = min(start + 320, clip.sampleCount)
            return AudioFrame(
                samples: Array(clip.samples[start..<end]), sampleOffset: clip.sampleOffset + Int64(start))
        }
    }
}

/// Unit embeddings along chosen directions, for consistency tests.
enum TestEmbeddings {
    static let model = SpeakerEmbeddingModelInfo.weSpeakerResNet34LM

    /// A unit vector that is `base` axis mixed with `other` axis by `mix`.
    static func embedding(axis: Int, mix: Float = 0, mixAxis: Int = 255) -> SpeakerEmbedding {
        var vector = [Float](repeating: 0, count: model.dimension)
        vector[axis] = 1
        vector[mixAxis] += mix
        return SpeakerEmbedding(normalizing: vector, modelIdentifier: model.identifier, audioDuration: .seconds(5))!
    }

    /// Embeddings of one speaker: the same main axis, each with a small
    /// individual component.
    static func speaker(_ axis: Int, count: Int) -> [SpeakerEmbedding] {
        (0..<count).map { embedding(axis: axis, mix: 0.3, mixAxis: 100 + axis * 10 + $0) }
    }

    /// The normalized sum of `axes`.
    static func blend(_ axes: [Int]) -> SpeakerEmbedding {
        var vector = [Float](repeating: 0, count: model.dimension)
        for axis in axes { vector[axis] += 1 }
        return SpeakerEmbedding(normalizing: vector, modelIdentifier: model.identifier, audioDuration: .seconds(5))!
    }

    static func vector(_ axis: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: model.dimension)
        vector[axis] = 1
        return vector
    }
}
