import BlauCore
import Foundation

/// Evaluates the second pass (#30) the way Blau runs it: a
/// `SecondPassRecognizer` (`ParakeetTdtRecognizer` in production) over each
/// utterance once it has ended, on the audio `SecondPassTranscriber` would
/// read for it.
///
/// Each reference utterance is cut from the fixture with the padding of
/// `configuration` (`SecondPassConfiguration`'s defaults: 100 ms before,
/// never reaching back into the previous utterance, and 120 ms after),
/// clamped exactly as `SecondPassTranscriber` clamps it, and transcribed on
/// its own. Segmenting by the labels isolates recognition accuracy from
/// endpointing, which the streaming engine measures. The final for an
/// utterance is available at the end of its padded audio plus the time the
/// model took, so its "end of utterance" latency is the trailing padding
/// plus the compute: what the second pass adds once an utterance has been
/// handed to it.
///
/// Fixtures are transcribed one at a time (as the evaluator does, and as
/// `SecondPassTranscriber`'s single worker calls the recognizer).
public struct OfflineASREvaluationEngine: ASREvaluationEngine {
    public let descriptor: ASREngineDescriptor
    private let recognizer: any SecondPassRecognizer
    private let configuration: SecondPassConfiguration

    public init(
        descriptor: ASREngineDescriptor, recognizer: any SecondPassRecognizer,
        configuration: SecondPassConfiguration = .standard
    ) {
        self.descriptor = descriptor
        self.recognizer = recognizer
        self.configuration = configuration
    }

    public func prepare() async throws {
        // Two passes: Core ML's first prediction is much slower than the rest.
        let samples = (0..<(AudioFrame.captureSampleRate * 2)).map { Float(sin(Double($0) * 0.07)) * 0.05 }
        _ = try await recognizer.transcribe(samples)
        _ = try await recognizer.transcribe(samples)
    }

    public func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript {
        let clock = ContinuousClock()
        var events: [ASRTimedEvent] = []
        var compute = Duration.zero
        for (index, segment) in segments(of: fixture).enumerated() {
            let audio = Array(fixture.samples[Int(segment.lowerBound)..<Int(segment.upperBound)])
            let started = clock.now
            let transcript = try await recognizer.transcribe(audio)
            let elapsed = clock.now - started
            compute += elapsed
            events.append(
                ASRTimedEvent(
                    kind: .final, text: ParakeetStreamingTranscriber.normalized(transcript.text),
                    range: fixture.utterances[index].range, audioPosition: segment.upperBound, computeLag: elapsed))
        }
        return ASREngineTranscript(events: events, computeTime: compute)
    }

    /// The audio the second pass reads for each utterance
    /// (`SecondPassConfiguration.audioRange`), clamped to the fixture the
    /// way the capture history clamps it live.
    func segments(of fixture: ASREvaluationFixture) -> [Range<Int64>] {
        var previousEnd: Int64 = 0
        return fixture.utterances.map { utterance in
            let range = configuration.audioRange(
                start: utterance.range.lowerBound, end: utterance.range.upperBound, previousEnd: previousEnd)
            previousEnd = max(previousEnd, utterance.range.upperBound)
            let upper = min(range.upperBound, fixture.sampleCount)
            return min(range.lowerBound, upper)..<upper
        }
    }
}

extension OfflineASREvaluationEngine {
    /// Parakeet TDT 0.6B v3 through `ParakeetTdtRecognizer`, the second
    /// pass's recognizer, loaded from the directory `ModelManager` installed,
    /// with `SecondPassConfiguration`'s padding. Id `parakeet-tdt-v3`.
    public static func parakeetTDTv3(
        modelDirectory: URL, configuration: SecondPassConfiguration = .standard, revision: String? = nil
    ) async throws -> OfflineASREvaluationEngine {
        let recognizer = try await ParakeetTdtRecognizer.load(modelDirectory: modelDirectory)
        return OfflineASREvaluationEngine(
            descriptor: tdtDescriptor(configuration: configuration, revision: revision), recognizer: recognizer,
            configuration: configuration)
    }

    /// The `parakeet-tdt-v3` engine's descriptor, with the padding it runs.
    static func tdtDescriptor(configuration: SecondPassConfiguration, revision: String?) -> ASREngineDescriptor {
        func milliseconds(_ duration: Duration) -> String {
            "\(Int((duration.timeInterval * 1_000).rounded())) ms"
        }
        return ASREngineDescriptor(
            id: "parakeet-tdt-v3", title: "Parakeet TDT 0.6B v3 per utterance (second pass, offline)",
            kind: .offline,
            model: revision.map { "\(ModelID.parakeetTDTv3.rawValue)@\($0.prefix(8))" },
            settings: [
                "segmentation": "reference labels",
                "leadingPadding": milliseconds(configuration.leadingPadding),
                "trailingPadding": milliseconds(configuration.trailingPadding),
            ])
    }
}
