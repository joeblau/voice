import BlauAudio
import BlauCore
import BlauTelemetry
@preconcurrency import CoreML
import Foundation

/// Runs streaming ASR on a live cadence while the tester backgrounds the app
/// and locks the device, to learn what iOS does to Neural Engine inference
/// off screen (#22, #26).
///
/// 1. Measures a CPU-only baseline of the same model in the foreground.
/// 2. Loads the Neural Engine model and feeds one hop of audio per hop
///    duration for `duration`, recording each window's latency (or error),
///    the app's `ExecutionPhase` and whether Core ML still lists a Neural
///    Engine.
/// 3. Classifies the run with `BackgroundInferenceAnalysis` and maps the
///    verdict to a `BackgroundInferenceMitigation`.
///
/// The app must keep running off screen for the probe to mean anything, so
/// the caller keeps an audio session recording (the `audio` background
/// mode), exactly as a Blau conversation does. Errors are recorded, not
/// thrown, so one failed prediction doesn't end the run. Cancelling the
/// task ends the run early and still returns what was measured.
public struct BackgroundInferenceProbe: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// How long to run the live cadence.
        public var duration: Duration
        /// Windows timed for the CPU-only baseline (after warm-up).
        public var cpuBaselineWindows: Int
        /// Windows excluded at the start of each phase of the run.
        public var warmupWindows: Int
        /// Seconds of audio per utterance before `finishUtterance()`.
        public var utteranceSeconds: Double

        public init(
            duration: Duration = .seconds(600),
            cpuBaselineWindows: Int = 40,
            warmupWindows: Int = 4,
            utteranceSeconds: Double = 10
        ) {
            self.duration = duration
            self.cpuBaselineWindows = cpuBaselineWindows
            self.warmupWindows = warmupWindows
            self.utteranceSeconds = utteranceSeconds
        }
    }

    private let processor: any StreamingChunkProcessor
    private let cpuProcessor: (any StreamingChunkProcessor)?
    private let phases: any ExecutionPhaseProvider
    private let neuralEngineListed: @Sendable () -> Bool?
    private let audio: AudioFixtureStore
    private let configuration: Configuration

    public init(
        processor: any StreamingChunkProcessor,
        cpuProcessor: (any StreamingChunkProcessor)?,
        phases: any ExecutionPhaseProvider,
        neuralEngineListed: @escaping @Sendable () -> Bool? = { NeuralEngine.isListed },
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) {
        self.processor = processor
        self.cpuProcessor = cpuProcessor
        self.phases = phases
        self.neuralEngineListed = neuralEngineListed
        self.audio = audio
        self.configuration = configuration
    }

    /// The probe for Parakeet EOU at `chunkSize`: Neural Engine run with a
    /// CPU-only baseline of the same model.
    public static func parakeetEou(
        _ chunkSize: ParakeetEouChunkSize = .ms320,
        phases: any ExecutionPhaseProvider,
        audio: AudioFixtureStore,
        configuration: Configuration = Configuration()
    ) -> BackgroundInferenceProbe {
        BackgroundInferenceProbe(
            processor: ParakeetEouChunkProcessor(chunkSize: chunkSize, computeUnits: .cpuAndNeuralEngine),
            cpuProcessor: ParakeetEouChunkProcessor(chunkSize: chunkSize, computeUnits: .cpuOnly),
            phases: phases,
            audio: audio,
            configuration: configuration
        )
    }

    /// Runs the probe. `onSample` sees every sample as it is taken, for a
    /// live display.
    public func run(
        context: BenchmarkContext = BenchmarkContext(),
        onStatus: @escaping @Sendable (String) -> Void = { _ in },
        onSample: @escaping @Sendable (InferenceSample) -> Void = { _ in }
    ) async throws -> BackgroundProbeReport {
        let fixture = try await audio.fixture()
        guard !fixture.samples.isEmpty else { throw BenchmarkSkip("The benchmark audio is empty") }
        let hop = Duration.samples(Int64(processor.hopSamples), sampleRate: AudioFixture.sampleRate)
        let startedAt = context.clock.now

        var cpuBaseline: LatencySummary?
        if let cpuProcessor {
            onStatus("Measuring the CPU-only baseline")
            cpuBaseline = try await measureBaseline(cpuProcessor, fixture: fixture, context: context)
        }

        onStatus("Loading the Neural Engine model")
        try await processor.prepare { _ in }
        try await processor.load()
        onStatus("Running: move Blau to the background and lock the device")
        let (samples, endedAt) = try await liveRun(fixture: fixture, hop: hop, context: context, onSample: onSample)
        await processor.unload()

        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: cpuBaseline, expectedInterval: hop, runEndedAt: endedAt)
        onStatus(analysis.verdict.summary)
        return BackgroundProbeReport(
            device: .current,
            startedAt: startedAt,
            hopMilliseconds: hop.milliseconds,
            samples: samples,
            analysis: analysis,
            mitigation: BackgroundInferenceMitigation.recommended(for: analysis, hop: hop)
        )
    }

    /// Back-to-back windows on `processor`, after warm-up.
    func measureBaseline(
        _ processor: any StreamingChunkProcessor,
        fixture: AudioFixture,
        context: BenchmarkContext
    ) async throws -> LatencySummary? {
        try await processor.prepare { _ in }
        try await processor.load()
        var counter = WindowCounter(windowSamples: processor.windowSamples, hopSamples: processor.hopSamples)
        var latencies: [Duration] = []
        var windowsSeen = 0
        var offset = 0.0
        let hopSeconds = Double(processor.hopSamples) / Double(AudioFixture.sampleRate)
        while latencies.count < configuration.cpuBaselineWindows {
            try Task.checkCancellation()
            let slice = fixture.window(seconds: hopSeconds, offset: offset)
            offset += hopSeconds
            let windows = counter.append(slice.count)
            let (_, elapsed) = try await context.measure { try await processor.process(slice) }
            if windows > 0, windowsSeen >= configuration.warmupWindows {
                latencies.append(elapsed / windows)
            }
            windowsSeen += windows
        }
        await processor.unload()
        return LatencySummary(latencies)
    }

    /// The paced run. Returns the samples and the uptime the run ended at,
    /// which the analysis needs to see a suspension that lasted until the
    /// end (the step after resuming is a warm-up and records no sample).
    func liveRun(
        fixture: AudioFixture,
        hop: Duration,
        context: BenchmarkContext,
        onSample: @escaping @Sendable (InferenceSample) -> Void
    ) async throws -> (samples: [InferenceSample], endedAt: Duration) {
        let hopSamples = processor.hopSamples
        let utteranceSamples = max(hopSamples, Int(configuration.utteranceSeconds * Double(AudioFixture.sampleRate)))
        var counter = WindowCounter(windowSamples: processor.windowSamples, hopSamples: hopSamples)
        var samples: [InferenceSample] = []
        var sinceUtterance = 0
        var previousPhase: ExecutionPhase?
        var warmupRemaining = configuration.warmupWindows
        let start = context.clock.uptime
        let hopSeconds = hop.timeInterval

        var step = 0
        while context.clock.uptime - start < configuration.duration {
            // Skip the hops that are already past instead of replaying them
            // back to back, the way a live microphone loses the audio while
            // the process is frozen. Replaying them would fill a suspension
            // the app resumed from off screen with burst samples, hiding the
            // gap from the coverage check and timing those windows unpaced.
            let due = Int((context.clock.uptime - start) / hop)
            if due > step { step = due }
            do {
                let wait = (start + hop * step) - context.clock.uptime
                if wait > .zero { try await context.clock.sleep(for: wait) }
            } catch {
                break  // Cancelled: end the run and analyse what we have.
            }
            if Task.isCancelled { break }

            let phase = await phases.currentPhase()
            if phase != previousPhase {
                // Each phase gets its own warm-up, so a transition's one-off
                // cost isn't read as steady-state behaviour.
                warmupRemaining = previousPhase == nil ? configuration.warmupWindows : 1
                previousPhase = phase
            }
            let neuralEngine = neuralEngineListed()
            let slice = fixture.window(seconds: hopSeconds, offset: Double(step) * hopSeconds)
            let windows = counter.append(slice.count)
            let startedAt = context.clock.uptime

            var sample: InferenceSample?
            do {
                let (_, elapsed) = try await context.measure { try await processor.process(slice) }
                if windows > 0 {
                    if warmupRemaining > 0 {
                        warmupRemaining -= 1
                    } else {
                        sample = InferenceSample(
                            uptimeSeconds: startedAt.timeInterval, phase: phase,
                            latencyMilliseconds: (elapsed / windows).milliseconds, error: nil,
                            neuralEngineAvailable: neuralEngine)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                sample = InferenceSample(
                    uptimeSeconds: startedAt.timeInterval, phase: phase, latencyMilliseconds: nil,
                    error: BenchmarkRunner.describe(error), neuralEngineAvailable: neuralEngine)
                counter.reset()
            }
            if let sample {
                samples.append(sample)
                onSample(sample)
            }

            sinceUtterance += slice.count
            if sinceUtterance >= utteranceSamples {
                _ = try? await processor.finishUtterance()
                counter.reset()
                sinceUtterance = 0
            }
            step += 1
        }
        return (samples, context.clock.uptime)
    }
}

/// Everything a background probe run produced, as saved to JSON.
public struct BackgroundProbeReport: Codable, Hashable, Sendable {
    public let device: BenchmarkDevice
    public let startedAt: Date
    public let hopMilliseconds: Double
    public let samples: [InferenceSample]
    public let analysis: BackgroundInferenceAnalysis
    public let mitigation: BackgroundInferenceMitigation

    public init(
        device: BenchmarkDevice,
        startedAt: Date,
        hopMilliseconds: Double,
        samples: [InferenceSample],
        analysis: BackgroundInferenceAnalysis,
        mitigation: BackgroundInferenceMitigation
    ) {
        self.device = device
        self.startedAt = startedAt
        self.hopMilliseconds = hopMilliseconds
        self.samples = samples
        self.analysis = analysis
        self.mitigation = mitigation
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// What Blau does about background inference, given a probe's verdict.
/// The decision table is in docs/benchmarks.md; #26 implements it.
public enum BackgroundInferenceMitigation: String, Codable, Hashable, Sendable, CaseIterable {
    /// The Neural Engine keeps working off screen: nothing to do.
    case keepNeuralEngine
    /// Core ML moves the work to the CPU and the CPU still keeps up: accept
    /// it, and monitor latency.
    case acceptCPUFallback
    /// Core ML throws off screen, but the CPU keeps up: reload the models
    /// with `.cpuOnly` when the app leaves the screen and back on return.
    case reloadOnCPUWhenBackgrounded
    /// Neither the Neural Engine nor the CPU keeps up off screen: hand
    /// transcription to the system's `SpeechTranscriber` (#31) while
    /// backgrounded.
    case switchToSystemTranscriber
    /// The app was suspended: the audio session isn't keeping it alive.
    /// Fix background execution first, then probe again.
    case fixBackgroundExecution
    /// Not enough data: run the probe again for longer.
    case rerunProbe

    /// Off-screen work keeps up when its p95 fits in this share of the hop,
    /// leaving the rest for VAD and voice ID.
    public static let backgroundBudgetShare = 0.8

    public static func recommended(for analysis: BackgroundInferenceAnalysis, hop: Duration) -> Self {
        let budget = hop.milliseconds * backgroundBudgetShare
        switch analysis.verdict {
        case .works:
            return .keepNeuralEngine
        case .degraded, .cpuFallback:
            guard let background = analysis.background else { return .rerunProbe }
            return background.p95 <= budget ? .acceptCPUFallback : .switchToSystemTranscriber
        case .errors:
            guard let cpu = analysis.cpuBaseline else { return .switchToSystemTranscriber }
            return cpu.p95 <= budget ? .reloadOnCPUWhenBackgrounded : .switchToSystemTranscriber
        case .suspended:
            return .fixBackgroundExecution
        case .inconclusive:
            return .rerunProbe
        }
    }

    public var summary: String {
        switch self {
        case .keepNeuralEngine: "Keep the Neural Engine in the background"
        case .acceptCPUFallback: "Accept the CPU fallback and monitor latency"
        case .reloadOnCPUWhenBackgrounded: "Reload ASR on the CPU when backgrounded"
        case .switchToSystemTranscriber: "Switch to SpeechTranscriber when backgrounded"
        case .fixBackgroundExecution: "Fix background execution (app was suspended)"
        case .rerunProbe: "Run the probe again"
        }
    }
}

/// Whether Core ML currently lists a Neural Engine among its compute
/// devices.
public enum NeuralEngine {
    public static var isListed: Bool {
        MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { true } else { false }
        }
    }
}
