import BlauTelemetry
import Foundation
import Testing

@Suite("Background inference analysis")
struct BackgroundInferenceAnalysisTests {
    static let hop = Duration.milliseconds(320)

    /// `count` samples every 0.32 s starting at `start`, all in `phase`.
    static func run(
        _ phase: ExecutionPhase,
        count: Int,
        start: Double,
        latency: Double?,
        error: String? = nil,
        neuralEngine: Bool? = true
    ) -> [InferenceSample] {
        (0..<count).map { index in
            InferenceSample(
                uptimeSeconds: start + Double(index) * 0.32, phase: phase, latencyMilliseconds: latency, error: error,
                neuralEngineAvailable: neuralEngine)
        }
    }

    static func baseline(_ milliseconds: Double) -> LatencySummary {
        LatencySummary(milliseconds: Array(repeating: milliseconds, count: 30))!
    }

    @Test func steadyLatencyOffScreenMeansItWorks() {
        let samples =
            Self.run(.foreground, count: 40, start: 0, latency: 40)
            + Self.run(.background, count: 20, start: 12.8, latency: 44)
            + Self.run(.locked, count: 40, start: 19.2, latency: 46)
        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: Self.baseline(180), expectedInterval: Self.hop)

        guard case .works(let slowdown) = analysis.verdict else {
            Issue.record("Expected works, got \(analysis.verdict)")
            return
        }
        #expect(abs(slowdown - 45.0 / 40) < 0.05)
        #expect(analysis.locked?.p50 == 46)
        #expect(analysis.backgroundErrorCount == 0)
        #expect(analysis.neuralEngineListedInBackground == true)
        #expect((analysis.backgroundCoverage ?? 0) > 0.99)
    }

    @Test func latencyNearTheCPUBaselineIsASilentFallback() {
        let samples =
            Self.run(.foreground, count: 30, start: 0, latency: 40)
            + Self.run(.locked, count: 30, start: 9.6, latency: 170, neuralEngine: false)
        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: Self.baseline(180), expectedInterval: Self.hop)
        #expect(analysis.verdict == .cpuFallback(slowdown: 170.0 / 40))
        #expect(analysis.neuralEngineListedInBackground == false)
    }

    @Test func slowerButNotCPULikeIsDegraded() {
        let samples =
            Self.run(.foreground, count: 30, start: 0, latency: 40)
            + Self.run(.background, count: 30, start: 9.6, latency: 70)
        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: Self.baseline(400), expectedInterval: Self.hop)
        #expect(analysis.verdict == .degraded(slowdown: 70.0 / 40))
    }

    @Test func withoutABaselineALargeSlowdownCountsAsFallback() {
        let foreground = Self.run(.foreground, count: 30, start: 0, latency: 40)
        let slow = BackgroundInferenceAnalysis(
            samples: foreground + Self.run(.locked, count: 30, start: 9.6, latency: 120), cpuBaseline: nil,
            expectedInterval: Self.hop)
        #expect(slow.verdict == .cpuFallback(slowdown: 3))
        let moderate = BackgroundInferenceAnalysis(
            samples: foreground + Self.run(.locked, count: 30, start: 9.6, latency: 80), cpuBaseline: nil,
            expectedInterval: Self.hop)
        #expect(moderate.verdict == .degraded(slowdown: 2))
    }

    @Test func offScreenErrorsAreReportedWithTheFirstMessage() {
        let samples =
            Self.run(.foreground, count: 30, start: 0, latency: 40)
            + Self.run(.locked, count: 25, start: 9.6, latency: nil, error: "ANE unavailable [com.apple.CoreML 0]")
        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: Self.baseline(180), expectedInterval: Self.hop)
        #expect(analysis.verdict == .errors(count: 25, firstError: "ANE unavailable [com.apple.CoreML 0]"))
        #expect(analysis.backgroundErrorCount == 25)
        #expect(analysis.foregroundErrorCount == 0)
    }

    @Test func aLongGapAfterBackgroundingMeansSuspension() {
        // Three background samples, then nothing for a minute until the app
        // comes back to the foreground.
        let samples =
            Self.run(.foreground, count: 30, start: 0, latency: 40)
            + Self.run(.background, count: 3, start: 9.6, latency: 45)
            + Self.run(.foreground, count: 10, start: 70, latency: 40)
        let analysis = BackgroundInferenceAnalysis(
            samples: samples, cpuBaseline: Self.baseline(180), expectedInterval: Self.hop)
        guard case .suspended(let coverage) = analysis.verdict else {
            Issue.record("Expected suspended, got \(analysis.verdict)")
            return
        }
        #expect(coverage < 0.05)
    }

    @Test func noBackgroundSamplesIsInconclusive() {
        let analysis = BackgroundInferenceAnalysis(
            samples: Self.run(.foreground, count: 50, start: 0, latency: 40), cpuBaseline: nil,
            expectedInterval: Self.hop)
        guard case .inconclusive = analysis.verdict else {
            Issue.record("Expected inconclusive, got \(analysis.verdict)")
            return
        }
        #expect(analysis.backgroundCoverage == nil)
    }

    @Test func tooFewSamplesIsInconclusive() {
        let samples =
            Self.run(.foreground, count: 5, start: 0, latency: 40)
            + Self.run(.locked, count: 30, start: 1.6, latency: 40)
        guard
            case .inconclusive(let reason) = BackgroundInferenceAnalysis(
                samples: samples, cpuBaseline: nil, expectedInterval: Self.hop
            ).verdict
        else {
            Issue.record("Expected inconclusive")
            return
        }
        #expect(reason.contains("foreground"))
    }

    @Test func verdictSummariesAreReadable() {
        #expect(BackgroundInferenceVerdict.works(slowdown: 1.1).summary == "Works (1.10× of foreground latency)")
        #expect(BackgroundInferenceVerdict.suspended(coverage: 0.123).summary.contains("12%"))
    }

    @Test func roundTripsThroughJSON() throws {
        let samples =
            Self.run(.foreground, count: 30, start: 0, latency: 40)
            + Self.run(.locked, count: 30, start: 9.6, latency: 44)
        let analysis = BackgroundInferenceAnalysis(samples: samples, cpuBaseline: nil, expectedInterval: Self.hop)
        let decoded = try JSONDecoder().decode(
            BackgroundInferenceAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(decoded == analysis)
    }
}
