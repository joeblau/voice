import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation

/// A streaming recognizer as the benchmark sees it: audio goes in a hop at a
/// time and the model runs one encoder window per hop.
///
/// The production implementation is `ParakeetEouChunkProcessor` (FluidAudio
/// `StreamingEouAsrManager`); tests use a fake that advances a
/// `ManualClock`.
public protocol StreamingChunkProcessor: Sendable {
    /// Samples the encoder sees per window.
    var windowSamples: Int { get }
    /// Samples the window advances by: the streaming latency step.
    var hopSamples: Int { get }

    /// Makes sure the model files are on disk (downloading them if needed).
    /// Not timed.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the models into memory. Timed as `load`.
    func load() async throws
    /// Appends 16 kHz mono `samples` and runs every complete window.
    func process(_ samples: [Float]) async throws
    /// Ends the utterance: pads and decodes the buffered tail and clears the
    /// buffer, as the pipeline does at each end of utterance. Returns the
    /// transcript.
    func finishUtterance() async throws -> String
    /// Releases the models.
    func unload() async
}

/// Measures a streaming ASR model the way Blau runs it: per-window latency,
/// real-time factor and memory.
///
/// Two passes over the same audio:
///
/// - **Burst**: hops are fed back to back. Gives the throughput, as RTFx
///   (seconds of audio per second of compute) and `window.burst` latency.
/// - **Paced**: one hop per hop duration, like live capture. Gives
///   `window` latency as the user experiences it, which can be worse than
///   burst latency because the Neural Engine clocks down between bursts of
///   work.
///
/// The first `warmupWindows` windows of each pass are excluded. Every
/// `utteranceSeconds` of audio the utterance is finished (`finish`
/// latency), as the pipeline does at each end of utterance.
public struct StreamingAsrBenchmark: BenchmarkCase {
    public struct Configuration: Hashable, Sendable {
        public var burstSeconds: Double
        public var pacedSeconds: Double
        public var warmupWindows: Int
        public var utteranceSeconds: Double

        public init(
            burstSeconds: Double = 60, pacedSeconds: Double = 30, warmupWindows: Int = 4, utteranceSeconds: Double = 10
        ) {
            self.burstSeconds = burstSeconds
            self.pacedSeconds = pacedSeconds
            self.warmupWindows = warmupWindows
            self.utteranceSeconds = utteranceSeconds
        }
    }

    public let id: String
    public let title: String
    public var category: LogCategory { .asr }

    private let processor: any StreamingChunkProcessor
    private let audio: AudioFixtureStore
    private let configuration: Configuration
    private let signposter: Signposter

    public init(
        id: String,
        title: String,
        processor: any StreamingChunkProcessor,
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration(),
        signposter: Signposter = Signposts.asr
    ) {
        self.id = id
        self.title = title
        self.processor = processor
        self.audio = audio
        self.configuration = configuration
        self.signposter = signposter
    }

    /// The Parakeet realtime EOU 120M case for `chunkSize`, with id
    /// `asr.eou.<chunk>` (for example `asr.eou.320ms`).
    public static func parakeetEou(
        _ chunkSize: ParakeetEouChunkSize,
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) -> StreamingAsrBenchmark {
        StreamingAsrBenchmark(
            id: chunkSize.benchmarkID,
            title: "Parakeet EOU 120M, \(chunkSize.rawValue) chunks",
            processor: ParakeetEouChunkProcessor(chunkSize: chunkSize),
            audio: audio,
            configuration: configuration
        )
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        recorder.progress(nil, "Preparing models")
        try await processor.prepare { fraction in recorder.progress(fraction * 0.3, "Downloading models") }

        var memory = context.memoryWatermark()
        recorder.progress(0.3, "Loading models")
        let (_, loadTime) = try await context.measure { try await processor.load() }
        recorder.record("load", loadTime)
        memory.sample()

        let fixture = try await audio.fixture()
        guard !fixture.samples.isEmpty else { throw BenchmarkSkip("The benchmark audio is empty") }
        recorder.note("Audio: \(fixture.source)")
        recorder.note(
            "Window \(processor.windowSamples) samples, hop \(processor.hopSamples) samples "
                + "(\(Duration.samples(Int64(processor.hopSamples), sampleRate: AudioFixture.sampleRate).milliseconds) ms)"
        )
        let hop = Duration.samples(Int64(processor.hopSamples), sampleRate: AudioFixture.sampleRate)

        recorder.progress(0.35, "Burst pass")
        let burst = try await feed(
            fixture.looped(to: .seconds(configuration.burstSeconds)).samples, paced: false, context: context,
            memory: &memory)
        recorder.recordLatencies("window.burst", burst.windowLatencies)
        recorder.recordLatencies("finish", burst.finishLatencies)
        if burst.computeTime > .zero {
            recorder.record(
                "rtfx", burst.measuredAudio.timeInterval / burst.computeTime.timeInterval, unit: .realTimeFactor)
        }
        _ = try await processor.finishUtterance()
        memory.sample()

        recorder.progress(0.7, "Paced pass")
        let paced = try await feed(
            fixture.looped(to: .seconds(configuration.pacedSeconds)).samples, paced: true, context: context,
            memory: &memory)
        recorder.recordLatencies("window", paced.windowLatencies)
        if let summary = LatencySummary(paced.windowLatencies), hop > .zero {
            recorder.record("window.p95OfHop", summary.p95 / hop.milliseconds * 100, unit: .percent)
        }
        _ = try await processor.finishUtterance()

        memory.sample()
        recorder.recordMemory(memory)
        await processor.unload()
        recorder.progress(1, "Done")
    }

    struct PassResult {
        var windowLatencies: [Duration] = []
        var finishLatencies: [Duration] = []
        /// Compute time after warm-up, including utterance finishes.
        var computeTime: Duration = .zero
        /// Audio fed after warm-up.
        var measuredAudio: Duration = .zero
    }

    /// Feeds `samples` a hop at a time, mirroring the processor's windowing
    /// to know how many windows each call ran.
    func feed(
        _ samples: [Float],
        paced: Bool,
        context: BenchmarkContext,
        memory: inout MemoryWatermark
    ) async throws -> PassResult {
        let hopSamples = processor.hopSamples
        let hop = Duration.samples(Int64(hopSamples), sampleRate: AudioFixture.sampleRate)
        let utteranceSamples = max(hopSamples, Int(configuration.utteranceSeconds * Double(AudioFixture.sampleRate)))

        var result = PassResult()
        var counter = WindowCounter(windowSamples: processor.windowSamples, hopSamples: hopSamples)
        var windowsSeen = 0
        var sinceUtterance = 0
        let start = context.clock.uptime

        for (step, offset) in stride(from: 0, to: samples.count, by: hopSamples).enumerated() {
            try Task.checkCancellation()
            if paced {
                let wait = (start + hop * step) - context.clock.uptime
                if wait > .zero { try await context.clock.sleep(for: wait) }
            }
            let slice = Array(samples[offset..<min(offset + hopSamples, samples.count)])
            let warmedUp = windowsSeen >= configuration.warmupWindows

            let windows = counter.append(slice.count)
            let (_, elapsed) = try await context.measure {
                try await signposter.withInterval(.asrChunk) { try await processor.process(slice) }
            }
            if warmedUp {
                result.measuredAudio += .samples(Int64(slice.count), sampleRate: AudioFixture.sampleRate)
                result.computeTime += elapsed
                if windows > 0 { result.windowLatencies.append(elapsed / windows) }
            }
            windowsSeen += windows

            sinceUtterance += slice.count
            if sinceUtterance >= utteranceSamples {
                let (_, finish) = try await context.measure { try await processor.finishUtterance() }
                if warmedUp {
                    result.finishLatencies.append(finish)
                    result.computeTime += finish
                }
                counter.reset()
                sinceUtterance = 0
            }
            if step % 25 == 0 { memory.sample() }
        }
        return result
    }
}

/// Mirrors a streaming recognizer's buffering to tell how many encoder
/// windows each append runs: a window runs whenever `windowSamples` are
/// buffered, then the buffer advances by `hopSamples`.
struct WindowCounter: Hashable, Sendable {
    let windowSamples: Int
    let hopSamples: Int
    private(set) var buffered = 0

    init(windowSamples: Int, hopSamples: Int) {
        precondition(hopSamples > 0 && windowSamples >= hopSamples, "Invalid window or hop")
        self.windowSamples = windowSamples
        self.hopSamples = hopSamples
    }

    /// Adds `samples` to the buffer and returns the number of windows that
    /// run.
    mutating func append(_ samples: Int) -> Int {
        buffered += samples
        var windows = 0
        while buffered >= windowSamples {
            windows += 1
            buffered -= hopSamples
        }
        return windows
    }

    /// Empties the buffer, as finishing an utterance does.
    mutating func reset() {
        buffered = 0
    }
}
