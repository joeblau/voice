import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation

/// A whole-utterance (offline) recognizer as the benchmark sees it.
///
/// The production implementation is `ParakeetTdtEngine` (FluidAudio
/// `AsrManager` with Parakeet TDT 0.6B v3), Blau's second pass.
public protocol OfflineTranscriptionEngine: Sendable {
    /// Makes sure the model files are on disk. Not timed.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the models so that the OS must compile them for this device
    /// again (the first-launch experience). Timed as `load.cold`.
    func loadCold() async throws
    /// Loads the models again from the same place, with the OS compile cache
    /// warm (every later launch). Timed as `load.warm`.
    func loadWarm() async throws
    /// Transcribes 16 kHz mono samples with the loaded models.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Releases the models (and any temporary copies).
    func unload() async
}

/// Measures an offline recognizer: cold and warm model load, real-time
/// factor on long audio, and latency for one utterance (the second pass
/// runs once per committed utterance).
public struct OfflineAsrBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        /// Length of the long-audio clip used for RTFx.
        public var longAudioSeconds: Double
        public var longAudioIterations: Int
        /// Length of one utterance for the per-utterance latency.
        public var utteranceSeconds: Double
        public var utteranceIterations: Int
        public var warmLoadIterations: Int

        public init(
            longAudioSeconds: Double = 60,
            longAudioIterations: Int = 3,
            utteranceSeconds: Double = 5,
            utteranceIterations: Int = 10,
            warmLoadIterations: Int = 3
        ) {
            self.longAudioSeconds = longAudioSeconds
            self.longAudioIterations = longAudioIterations
            self.utteranceSeconds = utteranceSeconds
            self.utteranceIterations = utteranceIterations
            self.warmLoadIterations = warmLoadIterations
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .asr }

    private let engine: any OfflineTranscriptionEngine
    private let audio: AudioFixtureStore
    private let configuration: Configuration

    public init(
        id: String,
        title: String,
        engine: any OfflineTranscriptionEngine,
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.audio = audio
        self.configuration = configuration
    }

    /// Parakeet TDT 0.6B v3, id `asr.tdt.v3`.
    public static func parakeetTdtV3(
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) -> OfflineAsrBenchmark {
        OfflineAsrBenchmark(
            id: "asr.tdt.v3", title: "Parakeet TDT 0.6B v3 (second pass)", engine: ParakeetTdtEngine(), audio: audio,
            configuration: configuration)
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        recorder.progress(nil, "Preparing models")
        try await engine.prepare { fraction in recorder.progress(fraction * 0.3, "Downloading models") }

        var memory = context.memoryWatermark()
        recorder.progress(0.3, "Cold load (compiling for this device)")
        let (_, cold) = try await context.measure { try await engine.loadCold() }
        recorder.record("load.cold", cold)
        memory.sample()

        var warmLoads: [Duration] = []
        for iteration in 0..<configuration.warmLoadIterations {
            recorder.progress(0.4, "Warm load \(iteration + 1) of \(configuration.warmLoadIterations)")
            let (_, warm) = try await context.measure { try await engine.loadWarm() }
            warmLoads.append(warm)
            memory.sample()
        }
        if let warm = LatencySummary(warmLoads) {
            recorder.record("load.warm", warm.p50, unit: .milliseconds)
        }

        let fixture = try await audio.fixture()
        guard !fixture.samples.isEmpty else { throw BenchmarkSkip("The benchmark audio is empty") }
        recorder.note("Audio: \(fixture.source)")

        // One untimed pass so first-prediction setup isn't counted.
        _ = try await engine.transcribe(fixture.window(seconds: configuration.utteranceSeconds))

        let long = fixture.looped(to: .seconds(configuration.longAudioSeconds))
        var longTimes: [Duration] = []
        for iteration in 0..<configuration.longAudioIterations {
            recorder.progress(0.5, "Long audio \(iteration + 1) of \(configuration.longAudioIterations)")
            let (_, elapsed) = try await context.measure { try await engine.transcribe(long.samples) }
            longTimes.append(elapsed)
            memory.sample()
        }
        let longCompute = longTimes.reduce(Duration.zero, +)
        if longCompute > .zero {
            let audioSeconds = long.seconds * Double(longTimes.count)
            recorder.record("rtfx", audioSeconds / longCompute.timeInterval, unit: .realTimeFactor)
        }

        var utteranceTimes: [Duration] = []
        for iteration in 0..<configuration.utteranceIterations {
            recorder.progress(0.8, "Utterance \(iteration + 1) of \(configuration.utteranceIterations)")
            let window = fixture.window(
                seconds: configuration.utteranceSeconds, offset: Double(iteration) * configuration.utteranceSeconds)
            let (_, elapsed) = try await context.measure { try await engine.transcribe(window) }
            utteranceTimes.append(elapsed)
        }
        // POSIX locale so the key is the same on every device (`5s`, `2.5s`).
        let label = configuration.utteranceSeconds.formatted(
            .number.precision(.fractionLength(0...1)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        recorder.recordLatencies("utterance.\(label)s", utteranceTimes)

        memory.sample()
        recorder.recordMemory(memory)
        await engine.unload()
        recorder.progress(1, "Done")
    }
}
