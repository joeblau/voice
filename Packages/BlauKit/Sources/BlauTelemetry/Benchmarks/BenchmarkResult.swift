import Foundation

/// One number a benchmark produced, such as a load time or a real-time
/// factor.
///
/// Keys are stable, dotted identifiers (`load.cold`, `rtfx`,
/// `memory.footprintGrowth`) so results from different devices line up in
/// one table.
public struct BenchmarkMetric: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, Hashable, Sendable {
        case milliseconds = "ms"
        case seconds = "s"
        case megabytes = "MB"
        /// Real-time factor: seconds of audio processed per second of compute.
        case realTimeFactor = "×"
        case percent = "%"
        case count = ""
    }

    public let key: String
    public let value: Double
    public let unit: Unit

    public init(key: String, value: Double, unit: Unit) {
        self.key = key
        self.value = value
        self.unit = unit
    }

    /// The value rounded for display, with its unit: `142 ms`, `18.4×`.
    public var formatted: String {
        let magnitude = abs(value)
        let digits = magnitude >= 100 || unit == .count ? 0 : (magnitude >= 10 ? 1 : 2)
        let number = value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
        switch unit {
        case .count: return number
        case .realTimeFactor, .percent: return "\(number)\(unit.rawValue)"
        default: return "\(number) \(unit.rawValue)"
        }
    }
}

/// The outcome of one benchmark case on one device.
public struct BenchmarkResult: Codable, Hashable, Sendable, Identifiable {
    public enum Outcome: Codable, Hashable, Sendable {
        case completed
        /// The case could not run here (model missing, feature unavailable).
        case skipped(reason: String)
        case failed(message: String)

        public var isCompleted: Bool { self == .completed }
    }

    /// Stable case identifier, for example `asr.eou.320ms`.
    public let id: String
    public let title: String
    public let outcome: Outcome
    /// Scalar metrics in the order they were recorded.
    public let metrics: [BenchmarkMetric]
    /// Latency distributions by key, for example `chunk` or `embed.1.5s`.
    public let latencies: [String: LatencySummary]
    /// Free-form observations: audio source, model variant, caveats.
    public let notes: [String]
    public let startedAt: Date
    public let wallTimeSeconds: Double
    public let thermalStateAtStart: ThermalState
    public let thermalStateAtEnd: ThermalState

    public init(
        id: String,
        title: String,
        outcome: Outcome,
        metrics: [BenchmarkMetric],
        latencies: [String: LatencySummary],
        notes: [String],
        startedAt: Date,
        wallTimeSeconds: Double,
        thermalStateAtStart: ThermalState,
        thermalStateAtEnd: ThermalState
    ) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.metrics = metrics
        self.latencies = latencies
        self.notes = notes
        self.startedAt = startedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.thermalStateAtStart = thermalStateAtStart
        self.thermalStateAtEnd = thermalStateAtEnd
    }

    /// The metric recorded under `key`, if any.
    public func metric(_ key: String) -> BenchmarkMetric? {
        metrics.last { $0.key == key }
    }

    /// Whether the device got hot enough to throttle during the run.
    public var wasThrottled: Bool { max(thermalStateAtStart, thermalStateAtEnd) >= .serious }
}
