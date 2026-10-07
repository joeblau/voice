import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation

/// A speaker-embedding model as the benchmark sees it.
public protocol SpeakerEmbeddingExtractor: Sendable {
    /// Makes sure the model files are on disk. Not timed.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the model. Timed as `load`.
    func load() async throws
    /// The embedding of 16 kHz mono `samples`.
    func embed(_ samples: [Float]) async throws -> [Float]
    func unload() async
}

/// Measures speaker-embedding latency for the window lengths the voice ID
/// gate scores: a first verdict at 1.5 s and a re-score at 3 s (#1, #47).
///
/// Also records `cosine.sameSpeaker`: the cosine similarity between the
/// embeddings of two different windows of the benchmark speech (one
/// speaker). It is a sanity check that the extractor produces meaningful
/// embeddings on this device, not a calibration (#48 does that).
public struct SpeakerEmbeddingBenchmarkCase: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        public var windowSeconds: [Double]
        public var iterations: Int
        public var warmupIterations: Int

        public init(windowSeconds: [Double] = [1.5, 3], iterations: Int = 30, warmupIterations: Int = 3) {
            self.windowSeconds = windowSeconds
            self.iterations = iterations
            self.warmupIterations = warmupIterations
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .voiceID }

    private let extractor: any SpeakerEmbeddingExtractor
    private let audio: AudioFixtureStore
    private let configuration: Configuration
    private let notes: [String]
    private let signposter: Signposter

    public init(
        id: String,
        title: String,
        extractor: any SpeakerEmbeddingExtractor,
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration(),
        notes: [String] = [],
        signposter: Signposter = Signposts.voiceID
    ) {
        self.id = id
        self.title = title
        self.extractor = extractor
        self.audio = audio
        self.configuration = configuration
        self.notes = notes
        self.signposter = signposter
    }

    /// WeSpeaker ResNet34-LM (FluidAudio `wespeaker_v2`), id
    /// `voiceid.wespeaker`.
    public static func weSpeaker(audio: AudioFixtureStore, configuration: Configuration = Configuration())
        -> SpeakerEmbeddingBenchmarkCase
    {
        SpeakerEmbeddingBenchmarkCase(
            id: "voiceid.wespeaker", title: "WeSpeaker ResNet34-LM embedding", extractor: WeSpeakerExtractor(),
            audio: audio, configuration: configuration,
            notes: [
                "FluidAudio's export takes a fixed 10 s input and repeat-pads shorter windows, "
                    + "so compute is the same for every window length"
            ])
    }

    /// CAM++ (FluidAudio, beta), the challenger in #1, id `voiceid.campplus`.
    public static func camPlusPlus(audio: AudioFixtureStore, configuration: Configuration = Configuration())
        -> SpeakerEmbeddingBenchmarkCase
    {
        SpeakerEmbeddingBenchmarkCase(
            id: "voiceid.campplus", title: "CAM++ embedding (challenger)", extractor: CamPlusPlusExtractor(),
            audio: audio, configuration: configuration,
            notes: [
                "FluidAudio loads CAM++ with .cpuAndGPU (its dynamic time axis is rejected by the ANE compiler); "
                    + "GPU work is not allowed in the background"
            ])
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        notes.forEach(recorder.note)
        recorder.progress(nil, "Preparing model")
        try await extractor.prepare { fraction in recorder.progress(fraction * 0.3, "Downloading model") }

        var memory = context.memoryWatermark()
        let (_, loadTime) = try await context.measure { try await extractor.load() }
        recorder.record("load", loadTime)
        memory.sample()

        let fixture = try await audio.fixture()
        guard !fixture.samples.isEmpty else { throw BenchmarkSkip("The benchmark audio is empty") }
        recorder.note("Audio: \(fixture.source)")

        var dimensions = 0
        for (index, seconds) in configuration.windowSeconds.enumerated() {
            var latencies: [Duration] = []
            let total = configuration.warmupIterations + configuration.iterations
            for iteration in 0..<total {
                try Task.checkCancellation()
                let window = fixture.window(seconds: seconds, offset: Double(iteration) * seconds)
                let (embedding, elapsed) = try await context.measure {
                    try await signposter.withInterval(.voiceIDEmbed) { try await extractor.embed(window) }
                }
                dimensions = embedding.count
                if iteration >= configuration.warmupIterations { latencies.append(elapsed) }
                let done = Double(index * total + iteration + 1) / Double(configuration.windowSeconds.count * total)
                recorder.progress(0.3 + 0.6 * done, "\(Self.label(seconds)) windows")
            }
            recorder.recordLatencies("embed.\(Self.label(seconds))", latencies)
            memory.sample()
        }
        recorder.record("dimensions", Double(dimensions), unit: .count)

        if let longest = configuration.windowSeconds.max() {
            let first = try await extractor.embed(fixture.window(seconds: longest, offset: 0))
            let second = try await extractor.embed(fixture.window(seconds: longest, offset: fixture.seconds / 2))
            if let cosine = Self.cosine(first, second) {
                recorder.record("cosine.sameSpeaker", cosine, unit: .score)
            }
        }

        recorder.recordMemory(memory)
        await extractor.unload()
        recorder.progress(1, "Done")
    }

    /// `1.5s`, `3s`, whatever the device's locale (metric keys must line up
    /// across devices in the comparison table).
    static func label(_ seconds: Double) -> String {
        seconds.formatted(
            .number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
            + "s"
    }

    /// Cosine similarity, or `nil` for mismatched or zero vectors.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for (left, right) in zip(lhs, rhs) {
            dot += Double(left) * Double(right)
            lhsNorm += Double(left) * Double(left)
            rhsNorm += Double(right) * Double(right)
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }
}
