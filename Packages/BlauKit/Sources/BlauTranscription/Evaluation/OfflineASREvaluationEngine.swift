import BlauCore
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// A recognizer that transcribes a whole utterance at once.
public protocol UtteranceTranscriptionModel: Sendable {
    /// Transcribes 16 kHz mono samples of one utterance.
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Evaluates an offline recognizer the way Blau uses one: the second pass
/// over each utterance once it has ended (#30).
///
/// Each reference utterance is cut from the fixture with `padding` of audio
/// on both sides (clamped to the file and to the neighbouring utterances)
/// and transcribed on its own. Segmenting by the labels isolates
/// recognition accuracy from endpointing, which the streaming engine
/// measures. The final for an utterance is available at the end of its
/// padded audio plus the time the model took, so its "end of utterance"
/// latency is `padding` plus the compute: what the second pass adds once
/// an utterance has been handed to it.
public struct OfflineASREvaluationEngine: ASREvaluationEngine {
    public let descriptor: ASREngineDescriptor
    private let model: any UtteranceTranscriptionModel
    private let padding: Int64

    public init(
        descriptor: ASREngineDescriptor, model: any UtteranceTranscriptionModel,
        padding: Duration = .milliseconds(200)
    ) {
        self.descriptor = descriptor
        self.model = model
        self.padding = padding.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    public func prepare() async throws {
        // Two passes: Core ML's first prediction is much slower than the rest.
        let samples = (0..<(AudioFrame.captureSampleRate * 2)).map { Float(sin(Double($0) * 0.07)) * 0.05 }
        _ = try await model.transcribe(samples)
        _ = try await model.transcribe(samples)
    }

    public func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript {
        let clock = ContinuousClock()
        var events: [ASRTimedEvent] = []
        var compute = Duration.zero
        for (index, segment) in segments(of: fixture).enumerated() {
            let audio = Array(fixture.samples[Int(segment.lowerBound)..<Int(segment.upperBound)])
            let started = clock.now
            let text = try await model.transcribe(audio)
            let elapsed = clock.now - started
            compute += elapsed
            events.append(
                ASRTimedEvent(
                    kind: .final, text: ParakeetStreamingTranscriber.normalized(text),
                    range: fixture.utterances[index].range, audioPosition: segment.upperBound, computeLag: elapsed))
        }
        return ASREngineTranscript(events: events, computeTime: compute)
    }

    /// Each utterance's range widened by `padding`, without reaching into
    /// the neighbouring utterances' speech.
    func segments(of fixture: ASREvaluationFixture) -> [Range<Int64>] {
        let utterances = fixture.utterances
        return utterances.indices.map { index in
            let range = utterances[index].range
            let previousEnd = index > 0 ? utterances[index - 1].range.upperBound : 0
            let nextStart = index + 1 < utterances.count ? utterances[index + 1].range.lowerBound : fixture.sampleCount
            let lower = max(range.lowerBound - padding, previousEnd, 0)
            let upper = min(range.upperBound + padding, nextStart, fixture.sampleCount)
            return lower..<upper
        }
    }
}

extension OfflineASREvaluationEngine {
    /// Parakeet TDT 0.6B v3 loaded from the directory `ModelManager`
    /// installed. Id `parakeet-tdt-v3`.
    public static func parakeetTDTv3(modelDirectory: URL, revision: String? = nil) async throws
        -> OfflineASREvaluationEngine
    {
        let model = try await ParakeetTdtUtteranceModel(modelDirectory: modelDirectory)
        let descriptor = ASREngineDescriptor(
            id: "parakeet-tdt-v3", title: "Parakeet TDT 0.6B v3 per utterance (second pass, offline)",
            kind: .offline,
            model: revision.map { "\(ModelID.parakeetTDTv3.rawValue)@\($0.prefix(8))" },
            settings: ["segmentation": "reference labels + 200 ms padding"])
        return OfflineASREvaluationEngine(descriptor: descriptor, model: model)
    }
}

/// Parakeet TDT 0.6B v3 through FluidAudio's `AsrManager`, one utterance per
/// call with a fresh decoder state.
public actor ParakeetTdtUtteranceModel: UtteranceTranscriptionModel {
    private let models: AsrModels
    private let manager: AsrManager

    /// Loads the models from an installed `.parakeetTDTv3` directory.
    public init(modelDirectory: URL) async throws {
        let models = try AsrModels.loadLocal(from: modelDirectory, version: .v3)
        self.models = models
        self.manager = AsrManager(config: .default, models: models)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        // FluidAudio refuses less than 0.3 s; pad very short cuts with silence.
        var audio = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: AudioFrame.captureSampleRate)
        if audio.count < minimum {
            audio += [Float](repeating: 0, count: minimum - audio.count)
        }
        var state = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
