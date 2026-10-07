import BlauCore
import Foundation

/// Where the app was when an inference ran.
public enum ExecutionPhase: String, Codable, Hashable, Sendable, CaseIterable {
    /// Active and on screen.
    case foreground
    /// Not on screen, device unlocked (another app, or the Home Screen).
    case background
    /// Not on screen and the device is locked (protected data unavailable).
    case locked

    /// Whether the app was off screen.
    public var isBackground: Bool { self != .foreground }
}

/// Reports the app's current `ExecutionPhase`. The app implements it with
/// `UIApplication`; tests script it.
public protocol ExecutionPhaseProvider: Sendable {
    func currentPhase() async -> ExecutionPhase
}

/// One timed inference in a background probe.
public struct InferenceSample: Codable, Hashable, Sendable {
    /// Monotonic time the inference started, in seconds.
    public let uptimeSeconds: Double
    public let phase: ExecutionPhase
    /// How long it took, or `nil` if it threw.
    public let latencyMilliseconds: Double?
    /// The error it threw, if any.
    public let error: String?
    /// Whether `MLModel.availableComputeDevices` listed a Neural Engine at
    /// that moment, when checked.
    public let neuralEngineAvailable: Bool?

    public init(
        uptimeSeconds: Double,
        phase: ExecutionPhase,
        latencyMilliseconds: Double?,
        error: String?,
        neuralEngineAvailable: Bool?
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.phase = phase
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
        self.neuralEngineAvailable = neuralEngineAvailable
    }
}

/// What happened to Neural Engine inference once the app left the screen.
///
/// iOS 27 restricts background Neural Engine access (issue #1). The probe
/// answers the spike's question: does Core ML throw, silently fall back to
/// the CPU, or keep working?
public enum BackgroundInferenceVerdict: Codable, Hashable, Sendable {
    /// Background latency stayed within `worksMaximumSlowdown` of the
    /// foreground.
    case works(slowdown: Double)
    /// Slower than the foreground, but not CPU-like.
    case degraded(slowdown: Double)
    /// Background latency looks like the CPU-only baseline: Core ML is
    /// quietly running the model on the CPU.
    case cpuFallback(slowdown: Double)
    /// Predictions threw while backgrounded.
    case errors(count: Int, firstError: String)
    /// The app stopped getting time (too few inferences for the time spent
    /// in the background): the process was suspended or starved.
    case suspended(coverage: Double)
    /// Not enough data to decide.
    case inconclusive(reason: String)

    /// A short label for the benchmark screen and the docs.
    public var summary: String {
        switch self {
        case .works(let slowdown): "Works (\(Self.ratio(slowdown)) of foreground latency)"
        case .degraded(let slowdown): "Degraded (\(Self.ratio(slowdown)) of foreground latency)"
        case .cpuFallback(let slowdown): "Silent CPU fallback (\(Self.ratio(slowdown)) of foreground latency)"
        case .errors(let count, let firstError): "Core ML errors (\(count)): \(firstError)"
        case .suspended(let coverage): "Suspended (\(Int((coverage * 100).rounded()))% of expected inferences ran)"
        case .inconclusive(let reason): "Inconclusive: \(reason)"
        }
    }

    private static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}

/// Classifies a background probe run. Pure logic, unit tested on the Mac.
///
/// The probe runs the same model on a fixed cadence (one inference every
/// `expectedInterval`) while the tester moves the app to the background and
/// locks the device. The analysis compares background latency with the
/// run's own foreground latency and with a CPU-only baseline of the same
/// model, which tells a silent CPU fallback apart from ordinary slowdown.
public struct BackgroundInferenceAnalysis: Codable, Hashable, Sendable {
    public struct Thresholds: Codable, Hashable, Sendable {
        /// At or below this background ÷ foreground p50 ratio, the Neural
        /// Engine is considered to keep working.
        public var worksMaximumSlowdown: Double
        /// Without a CPU baseline, at or above this ratio the slowdown is
        /// attributed to a CPU fallback.
        public var fallbackMinimumSlowdown: Double
        /// Below this fraction of the expected inferences, the app was
        /// suspended rather than running.
        public var minimumCoverage: Double
        /// Fewer successful inferences than this in either phase is
        /// inconclusive.
        public var minimumSamples: Int

        public init(
            worksMaximumSlowdown: Double = 1.5,
            fallbackMinimumSlowdown: Double = 2.5,
            minimumCoverage: Double = 0.5,
            minimumSamples: Int = 20
        ) {
            self.worksMaximumSlowdown = worksMaximumSlowdown
            self.fallbackMinimumSlowdown = fallbackMinimumSlowdown
            self.minimumCoverage = minimumCoverage
            self.minimumSamples = minimumSamples
        }
    }

    public let foreground: LatencySummary?
    /// Every off-screen sample (`background` and `locked`).
    public let background: LatencySummary?
    /// Only the samples taken while the device was locked.
    public let locked: LatencySummary?
    public let cpuBaseline: LatencySummary?
    public let foregroundErrorCount: Int
    public let backgroundErrorCount: Int
    /// Fraction of the expected background inferences that actually ran.
    public let backgroundCoverage: Double?
    /// Whether every off-screen check found a Neural Engine (`nil` if never
    /// checked).
    public let neuralEngineListedInBackground: Bool?
    public let verdict: BackgroundInferenceVerdict

    public init(
        samples: [InferenceSample],
        cpuBaseline: LatencySummary?,
        expectedInterval: Duration,
        thresholds: Thresholds = Thresholds()
    ) {
        let ordered = samples.sorted { $0.uptimeSeconds < $1.uptimeSeconds }
        let foregroundSamples = ordered.filter { !$0.phase.isBackground }
        let backgroundSamples = ordered.filter(\.phase.isBackground)

        foreground = LatencySummary(milliseconds: foregroundSamples.compactMap(\.latencyMilliseconds))
        background = LatencySummary(milliseconds: backgroundSamples.compactMap(\.latencyMilliseconds))
        locked = LatencySummary(
            milliseconds: backgroundSamples.filter { $0.phase == .locked }.compactMap(\.latencyMilliseconds))
        self.cpuBaseline = cpuBaseline
        foregroundErrorCount = foregroundSamples.count { $0.error != nil }
        backgroundErrorCount = backgroundSamples.count { $0.error != nil }
        backgroundCoverage = Self.coverage(of: ordered, expectedInterval: expectedInterval.timeInterval)

        let checks = backgroundSamples.compactMap(\.neuralEngineAvailable)
        neuralEngineListedInBackground = checks.isEmpty ? nil : checks.allSatisfy { $0 }

        verdict = Self.classify(
            foreground: foreground,
            background: background,
            cpuBaseline: cpuBaseline,
            backgroundSampleCount: backgroundSamples.count,
            backgroundErrors: backgroundSamples.compactMap(\.error),
            coverage: backgroundCoverage,
            thresholds: thresholds
        )
    }

    /// Background inferences that ran ÷ the number the cadence called for.
    ///
    /// Each off-screen sample "owns" the time until the next sample, so a
    /// suspension shows up as one long gap after the last background sample.
    static func coverage(of ordered: [InferenceSample], expectedInterval: Double) -> Double? {
        guard expectedInterval > 0 else { return nil }
        var backgroundCount = 0
        var backgroundSpan = 0.0
        for (index, sample) in ordered.enumerated() where sample.phase.isBackground {
            backgroundCount += 1
            let next = index + 1 < ordered.count ? ordered[index + 1].uptimeSeconds : sample.uptimeSeconds
            backgroundSpan += max(next - sample.uptimeSeconds, expectedInterval)
        }
        guard backgroundCount > 0, backgroundSpan > 0 else { return nil }
        return min(1, Double(backgroundCount) * expectedInterval / backgroundSpan)
    }

    static func classify(
        foreground: LatencySummary?,
        background: LatencySummary?,
        cpuBaseline: LatencySummary?,
        backgroundSampleCount: Int,
        backgroundErrors: [String],
        coverage: Double?,
        thresholds: Thresholds
    ) -> BackgroundInferenceVerdict {
        guard backgroundSampleCount > 0 else {
            return .inconclusive(reason: "no inferences ran off screen; lock the device during the probe")
        }
        if let coverage, coverage < thresholds.minimumCoverage {
            return .suspended(coverage: coverage)
        }
        if let firstError = backgroundErrors.first {
            return .errors(count: backgroundErrors.count, firstError: firstError)
        }
        guard let foreground, foreground.count >= thresholds.minimumSamples else {
            return .inconclusive(reason: "fewer than \(thresholds.minimumSamples) foreground inferences")
        }
        guard let background, background.count >= thresholds.minimumSamples else {
            return .inconclusive(reason: "fewer than \(thresholds.minimumSamples) background inferences")
        }
        guard foreground.p50 > 0 else {
            return .inconclusive(reason: "foreground latency is zero")
        }

        let slowdown = background.p50 / foreground.p50
        if slowdown <= thresholds.worksMaximumSlowdown {
            return .works(slowdown: slowdown)
        }
        if let cpuBaseline, cpuBaseline.p50 > 0 {
            // Closer (on a log scale) to the CPU-only run than to the
            // foreground Neural Engine run: the work moved to the CPU.
            let distanceToCPU = abs(log(background.p50 / cpuBaseline.p50))
            let distanceToForeground = abs(log(slowdown))
            return distanceToCPU < distanceToForeground
                ? .cpuFallback(slowdown: slowdown) : .degraded(slowdown: slowdown)
        }
        return slowdown >= thresholds.fallbackMinimumSlowdown
            ? .cpuFallback(slowdown: slowdown) : .degraded(slowdown: slowdown)
    }
}
