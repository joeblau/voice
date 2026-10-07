import BlauCore
import Foundation

/// Measures how long a ``SpeakerEmbedder`` takes per call.
///
/// Used by the opt-in benchmark tests on the Mac and on device (see
/// docs/benchmarks.md). Each scenario is one call the pipeline makes: the
/// 1.5 s first score, the 3 s re-score, an enrollment clip.
public struct SpeakerEmbeddingBenchmark: Sendable {
    /// One call to time: embedding one segment of `segmentDuration`.
    public struct Scenario: Hashable, Sendable {
        public let name: String
        public let segmentDuration: Duration

        public init(name: String, segmentDuration: Duration) {
            precondition(segmentDuration > .zero, "A scenario embeds some audio")
            self.name = name
            self.segmentDuration = segmentDuration
        }

        /// The 1.5 s window: the gate's first score.
        public static let shortWindow = Scenario(name: "1.5 s window", segmentDuration: .milliseconds(1_500))
        /// The 3 s window: the gate's re-score.
        public static let longWindow = Scenario(name: "3 s window", segmentDuration: .seconds(3))
        /// An enrollment clip (3 to 6 s).
        public static let enrollmentClip = Scenario(name: "6 s enrollment clip", segmentDuration: .seconds(6))

        /// The two windows the verification gate scores.
        public static let standard: [Scenario] = [.shortWindow, .longWindow]
    }

    /// Latency statistics over the timed iterations of one scenario.
    public struct Result: Hashable, Sendable {
        public let scenario: Scenario
        /// Every timed iteration, in the order they ran.
        public let samples: [Duration]

        public init(scenario: Scenario, samples: [Duration]) {
            precondition(!samples.isEmpty, "A result needs at least one sample")
            self.scenario = scenario
            self.samples = samples
        }

        private var sorted: [Duration] { samples.sorted() }

        public var minimum: Duration { sorted[0] }
        public var maximum: Duration { sorted[sorted.count - 1] }
        public var mean: Duration { samples.reduce(.zero, +) / samples.count }

        /// The nearest-rank percentile, `p` in `0...100`.
        public func percentile(_ p: Double) -> Duration {
            precondition((0...100).contains(p), "Percentile out of range")
            let sorted = sorted
            let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
            return sorted[min(max(rank, 1), sorted.count) - 1]
        }

        public var median: Duration { percentile(50) }
    }

    public let iterations: Int
    public let warmUpIterations: Int
    private let clock: any BlauClock

    /// - Parameters:
    ///   - iterations: Timed calls per scenario.
    ///   - warmUpIterations: Untimed calls first, so one-off costs (Neural
    ///     Engine program load, buffer allocation) don't count.
    ///   - clock: Measures each call (`uptime`).
    public init(iterations: Int = 50, warmUpIterations: Int = 5, clock: any BlauClock = SystemClock()) {
        precondition(iterations > 0 && warmUpIterations >= 0)
        self.iterations = iterations
        self.warmUpIterations = warmUpIterations
        self.clock = clock
    }

    /// Times each scenario on `embedder`, one after the other, with
    /// deterministic speech-like audio (latency doesn't depend on content).
    /// This is what a pipeline call costs: validation, padding, the model
    /// run and normalization.
    public func run(_ embedder: some SpeakerEmbedder, scenarios: [Scenario] = Scenario.standard) async throws
        -> [Result]
    {
        try await measure(scenarios) { segment in _ = try await embedder.embed(segment) }
    }

    /// Times the model run alone (padding and Core ML prediction), to
    /// separate it from the embedder's own work.
    public func run(_ network: some SpeakerEmbeddingNetwork, scenarios: [Scenario] = Scenario.standard) async throws
        -> [Result]
    {
        try await measure(scenarios) { segment in _ = try await network.embed(segment.samples) }
    }

    private func measure(_ scenarios: [Scenario], _ call: (AudioFrame) async throws -> Void) async throws -> [Result] {
        var results: [Result] = []
        for scenario in scenarios {
            let segment = Self.syntheticSpeech(duration: scenario.segmentDuration)
            for _ in 0..<warmUpIterations {
                try await call(segment)
            }
            var samples: [Duration] = []
            samples.reserveCapacity(iterations)
            for _ in 0..<iterations {
                try Task.checkCancellation()
                let start = clock.uptime
                try await call(segment)
                samples.append(clock.uptime - start)
            }
            results.append(Result(scenario: scenario, samples: samples))
        }
        return results
    }

    /// A Markdown table of `results`, in milliseconds, for docs/benchmarks.md.
    public static func markdownTable(_ results: [Result]) -> String {
        var lines = [
            "| Scenario | Runs | p50 (ms) | p90 (ms) | p99 (ms) | Mean (ms) | Min (ms) | Max (ms) |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for result in results {
            let cells = [
                result.median, result.percentile(90), result.percentile(99), result.mean, result.minimum,
                result.maximum,
            ]
            .map(milliseconds)
            lines.append("| \(result.scenario.name) | \(result.samples.count) | \(cells.joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// `duration` formatted in milliseconds with two decimals.
    public static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.2f", duration.timeInterval * 1_000)
    }

    /// Deterministic 16 kHz audio with speech-like level and spectrum
    /// (amplitude-modulated harmonics plus noise). For timing only.
    public static func syntheticSpeech(duration: Duration, seed: UInt64 = 1) -> AudioFrame {
        let count = Int(duration.sampleCount(sampleRate: AudioFrame.captureSampleRate))
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let rate = Float(AudioFrame.captureSampleRate)
        let pitch = 110 + Float(seed % 7) * 15
        let samples = (0..<count).map { index -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            let time = Float(index) / rate
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 4 * time)
            var voiced: Float = 0
            for harmonic in 1...5 {
                voiced += sin(2 * .pi * pitch * Float(harmonic) * time) / Float(harmonic)
            }
            return 0.1 * envelope * voiced + 0.01 * noise
        }
        return AudioFrame(samples: samples, sampleOffset: 0)
    }
}
