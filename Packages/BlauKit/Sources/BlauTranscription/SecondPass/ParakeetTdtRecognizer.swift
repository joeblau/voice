@preconcurrency import CoreML
import FluidAudio
import Foundation

/// The second pass on Parakeet TDT 0.6B v3 through FluidAudio's
/// `AsrManager`: punctuated, capitalized text for one utterance at a time.
///
/// ```swift
/// guard let directory = modelManager.directory(for: .parakeetTDTv3) else { return }
/// let recognizer = try await ParakeetTdtRecognizer.load(modelDirectory: directory)
/// let transcript = try await recognizer.transcribe(samples)   // "Yes, let's do Tuesday."
/// ```
///
/// It loads from Blau's own model store (`AsrModels.loadLocal`, never
/// FluidAudio's downloader, see `FluidAudioModels`), with FluidAudio's
/// default compute units: the preprocessor on the CPU and the encoder,
/// decoder and joint network on the Neural Engine with CPU fallback.
///
/// Every call decodes from a fresh `TdtDecoderState`, so utterances are
/// independent. FluidAudio pads audio up to its 15 s encoder window and
/// splits longer audio into overlapping windows; audio shorter than its
/// 0.3 s minimum is padded with silence here.
public actor ParakeetTdtRecognizer: SecondPassRecognizer {
    private let manager: AsrManager
    private let decoderLayers: Int

    /// The shortest audio FluidAudio's `AsrManager` accepts (0.3 s).
    public static let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)

    init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// Loads Parakeet TDT v3 from `modelDirectory`
    /// (`ModelManager.directory(for: .parakeetTDTv3)`). Takes a few seconds
    /// the first time on a device (the Neural Engine compile, which
    /// `ModelManager` usually did already when it warmed the model up).
    @concurrent
    public static func load(modelDirectory: URL) async throws -> ParakeetTdtRecognizer {
        let models = try AsrModels.loadLocal(from: modelDirectory, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        return ParakeetTdtRecognizer(manager: manager, decoderLayers: models.version.decoderLayers)
    }

    public func transcribe(_ samples: [Float]) async throws -> SecondPassTranscript {
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio += [Float](repeating: 0, count: Self.minimumSamples - audio.count)
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let confidence = result.text.isEmpty ? nil : Double(result.confidence)
        return SecondPassTranscript(text: result.text, confidence: confidence)
    }
}

extension ParakeetTdtRecognizer {
    /// A provider that loads the recognizer from `modelManager` once Parakeet
    /// TDT v3 is installed, and returns `nil` until then.
    public static func provider(modelManager: ModelManager) -> SecondPassRecognizerProvider {
        {
            guard let directory = await modelManager.directory(for: .parakeetTDTv3) else { return nil }
            return try await load(modelDirectory: directory)
        }
    }
}
