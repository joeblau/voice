import BlauAudio
import BlauCore
import Foundation

/// An ASR engine behind a noise suppressor, for the noise suppression A/B
/// (#51): every fixture is enhanced first, then transcribed by the wrapped
/// engine, as if the suppressor sat in the capture chain in front of VAD and
/// ASR.
///
/// The fixture's labels still apply, because the enhanced audio is aligned
/// with the original (`NoiseSuppressor.enhance(_:)`). What the suppressor
/// costs live is charged to the results:
///
/// - **Latency.** Live, the recognizer would see every sample the
///   suppressor's delay later, plus the compute of the frame it came in.
///   Each event's `computeLag` grows by the delay and the mean compute per
///   20 ms capture frame.
/// - **Compute.** The suppressor's time is added to the fixture's compute,
///   so RTF covers both.
///
/// Its id is the wrapped engine's with the suppressor's appended:
/// `parakeet-eou-320ms+dfn3`.
public struct NoiseSuppressedASREvaluationEngine: ASREvaluationEngine {
    public let descriptor: ASREngineDescriptor
    public let suppressor: NoiseSuppressorDescriptor
    private let base: any ASREvaluationEngine
    private let makeSuppressor: NoiseSuppressorFactory

    /// Samples per capture frame, the unit the suppressor's compute is
    /// charged in.
    static let captureFrame = 320

    /// - Parameters:
    ///   - base: The engine that transcribes the enhanced audio.
    ///   - makeSuppressor: A fresh suppressor per fixture. Called once here
    ///     to read its descriptor.
    public init(base: any ASREvaluationEngine, makeSuppressor: @escaping NoiseSuppressorFactory) throws {
        let suppressor = try makeSuppressor().descriptor
        var settings = base.descriptor.settings
        settings["noiseSuppression"] = suppressor.id
        settings["noiseSuppressionDelay"] = "\(Int((suppressor.latency.timeInterval * 1_000).rounded())) ms"
        for (key, value) in suppressor.settings {
            settings["noiseSuppression.\(key)"] = value
        }
        self.base = base
        self.suppressor = suppressor
        self.makeSuppressor = makeSuppressor
        self.descriptor = ASREngineDescriptor(
            id: "\(base.descriptor.id)+\(suppressor.id)",
            title: "\(base.descriptor.title), after \(suppressor.title)",
            kind: base.descriptor.kind,
            model: base.descriptor.model,
            settings: settings)
    }

    public func prepare() async throws {
        try await base.prepare()
        // Warm the suppressor's model up too (Core ML's first prediction).
        let warmUp = (0..<(AudioFrame.captureSampleRate * 2)).map { Float(sin(Double($0) * 0.07)) * 0.05 }
        _ = try makeSuppressor().enhance(warmUp)
    }

    public func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript {
        let suppressor = try makeSuppressor()
        let clock = ContinuousClock()
        let started = clock.now
        let enhanced = try suppressor.enhance(fixture.samples)
        let compute = clock.now - started

        var transcript = try await base.transcribe(
            ASREvaluationFixture(
                id: fixture.id, category: fixture.category, description: fixture.description, tags: fixture.tags,
                samples: enhanced, utterances: fixture.utterances))
        let frames = max(1, (fixture.samples.count + Self.captureFrame - 1) / Self.captureFrame)
        let lag = self.suppressor.latency + compute / frames
        for index in transcript.events.indices {
            transcript.events[index].computeLag += lag
        }
        transcript.computeTime += compute
        return transcript
    }
}
