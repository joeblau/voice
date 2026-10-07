import BlauAudio
import BlauCore

/// A noise suppressor in front of the speaker embedder, for the voice ID
/// side of the noise suppression A/B (#51): `VoiceIDEvaluator` runs every
/// enrollment clip and probe through it and reports it next to the
/// unprocessed baseline.
///
/// Each recording gets a fresh suppressor and comes back aligned with the
/// original (`NoiseSuppressor.enhance(_:)`), so the evaluator's windows cut
/// the same speech.
public struct NoiseSuppressionPreprocessor: VoiceIDAudioPreprocessor {
    public let name: String
    public let suppressor: NoiseSuppressorDescriptor
    private let makeSuppressor: NoiseSuppressorFactory

    /// - Parameter makeSuppressor: A fresh suppressor per recording. Called
    ///   once here to read its descriptor; its id names the variant.
    public init(makeSuppressor: @escaping NoiseSuppressorFactory) throws {
        let descriptor = try makeSuppressor().descriptor
        self.name = descriptor.id
        self.suppressor = descriptor
        self.makeSuppressor = makeSuppressor
    }

    public func process(_ audio: AudioFrame) async throws -> AudioFrame {
        precondition(audio.sampleRate == AudioFrame.captureSampleRate, "Suppressors take 16 kHz audio")
        let enhanced = try makeSuppressor().enhance(audio.samples)
        return AudioFrame(samples: enhanced, sampleOffset: audio.sampleOffset, hostTime: audio.hostTime)
    }
}
