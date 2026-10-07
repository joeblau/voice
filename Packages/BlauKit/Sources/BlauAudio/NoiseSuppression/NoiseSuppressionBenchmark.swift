import BlauCore
import BlauTelemetry
import Foundation

/// What a noise suppressor costs on this device (#51): load time, compute
/// per 20 ms capture frame, real-time factor and memory, streaming the
/// benchmark speech through it the way the capture chain would.
///
/// | Metric | |
/// | --- | --- |
/// | `load` | Loading the model (Core ML compile on first use) or the audio unit |
/// | `frame` (latencies) | Compute per 20 ms frame, warm |
/// | `frame.p95OfFrame` | The p95 as a share of the frame's 20 ms |
/// | `rtfx` | Seconds of audio per second of compute |
/// | `delay` | The suppressor's algorithmic delay, before compute |
public struct NoiseSuppressionBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        /// Audio streamed through the suppressor, from the start of the clip
        /// (repeated if shorter).
        public var seconds: Double
        /// Samples per call: a 20 ms capture frame.
        public var frameLength: Int
        /// Frames run before timing starts.
        public var warmupFrames: Int

        public init(seconds: Double = 60, frameLength: Int = 320, warmupFrames: Int = 50) {
            self.seconds = seconds
            self.frameLength = frameLength
            self.warmupFrames = warmupFrames
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .audio }

    private let load: @Sendable () async throws -> NoiseSuppressorFactory
    private let audio: AudioFixtureStore
    private let configuration: Configuration
    private let notes: [String]

    /// - Parameter load: Loads the model and returns a suppressor factory;
    ///   timed as `load`.
    public init(
        id: String, title: String, audio: AudioFixtureStore, configuration: Configuration = Configuration(),
        notes: [String] = [], load: @escaping @Sendable () async throws -> NoiseSuppressorFactory
    ) {
        self.id = id
        self.title = title
        self.audio = audio
        self.configuration = configuration
        self.notes = notes
        self.load = load
    }

    /// DeepFilterNet3 from `directory` on `computeUnits`, id
    /// `audio.ns.dfn3.<computeUnits>`. Skipped when the directory is missing.
    public static func deepFilterNet3(
        directory: URL?, computeUnits: NoiseSuppressionComputeUnits = .cpuAndNeuralEngine, audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) -> NoiseSuppressionBenchmark {
        NoiseSuppressionBenchmark(
            id: "audio.ns.dfn3.\(computeUnits.rawValue)", title: "DeepFilterNet3 (\(computeUnits.rawValue))",
            audio: audio, configuration: configuration,
            notes: [
                "\(DeepFilterNet3Model.repository)@\(DeepFilterNet3Model.revision.prefix(8)); "
                    + "16 kHz in and out through 48 kHz resamplers"
            ]
        ) {
            guard let directory, FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
                throw BenchmarkSkip("No DeepFilterNet3 model (scripts/fetch-deepfilternet3.sh)")
            }
            return try await NoiseSuppressorKind.deepFilterNet3.factory(
                deepFilterNet3Directory: directory, computeUnits: computeUnits)
        }
    }

    /// Apple's `AUSoundIsolation`, id `audio.ns.apple-voice-isolation[-hq]`.
    public static func soundIsolation(
        _ model: SoundIsolationSuppressor.Model = .voice, audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) -> NoiseSuppressionBenchmark {
        let kind: NoiseSuppressorKind = model == .voice ? .appleVoiceIsolation : .appleVoiceIsolationHighQuality
        return NoiseSuppressionBenchmark(
            id: "audio.ns.\(kind.rawValue)", title: "Apple AUSoundIsolation (\(model.rawValue))", audio: audio,
            configuration: configuration
        ) {
            guard SoundIsolationSuppressor.isAvailable else {
                throw BenchmarkSkip("AUSoundIsolation isn't available on this OS")
            }
            return try await kind.factory(deepFilterNet3Directory: nil)
        }
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        notes.forEach(recorder.note)
        var memory = context.memoryWatermark()
        recorder.progress(nil, "Loading")
        let (factory, loadTime) = try await context.measure { () async throws -> NoiseSuppressorFactory in
            let factory = try await load()
            _ = try factory()  // the first instance initializes the model
            return factory
        }
        recorder.record("load", loadTime)
        memory.sample()

        let fixture = try await audio.fixture()
        guard !fixture.samples.isEmpty else { throw BenchmarkSkip("The benchmark audio is empty") }
        recorder.note("Audio: \(fixture.source)")
        let total = Int(configuration.seconds * Double(AudioFrame.captureSampleRate))
        let samples = (0..<total).map { fixture.samples[$0 % fixture.samples.count] }

        let suppressor = try factory()
        recorder.record("delay", suppressor.descriptor.latency.milliseconds, unit: .milliseconds)
        let frames = stride(from: 0, to: samples.count, by: configuration.frameLength).map {
            Array(samples[$0..<min($0 + configuration.frameLength, samples.count)])
        }
        var latencies: [Duration] = []
        var compute = Duration.zero
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let (_, elapsed) = try context.measure { try suppressor.process(frame) }
            if index >= configuration.warmupFrames {
                latencies.append(elapsed)
                compute += elapsed
            }
            if index % 250 == 0 {
                recorder.progress(Double(index) / Double(frames.count), "Streaming")
                memory.sample()
            }
        }
        _ = try suppressor.finish()
        recorder.recordLatencies("frame", latencies)
        if let summary = LatencySummary(latencies) {
            let frameMilliseconds = Double(configuration.frameLength) / Double(AudioFrame.captureSampleRate) * 1_000
            recorder.record("frame.p95OfFrame", summary.p95 / frameMilliseconds * 100, unit: .percent)
        }
        let timedAudio = Double(latencies.count * configuration.frameLength) / Double(AudioFrame.captureSampleRate)
        if compute > .zero {
            recorder.record("rtfx", timedAudio / compute.timeInterval, unit: .realTimeFactor)
        }
        memory.sample()
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }
}
