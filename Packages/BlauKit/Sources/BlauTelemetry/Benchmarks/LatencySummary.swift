import BlauCore
import Foundation

/// Order statistics for a set of latency samples. Every value is in
/// milliseconds.
///
/// Percentiles use linear interpolation between the closest ranks (the same
/// definition as NumPy's default and Excel's `PERCENTILE.INC`), so `p50` of
/// an even-sized sample is the mean of the two middle values.
public struct LatencySummary: Codable, Hashable, Sendable {
    public let count: Int
    public let minimum: Double
    public let mean: Double
    public let p50: Double
    public let p90: Double
    public let p95: Double
    public let p99: Double
    public let maximum: Double
    /// Population standard deviation.
    public let standardDeviation: Double

    /// Summarizes `milliseconds`. Returns `nil` for an empty sample, or if
    /// any value is not finite.
    public init?(milliseconds: [Double]) {
        guard !milliseconds.isEmpty, milliseconds.allSatisfy(\.isFinite) else { return nil }
        let sorted = milliseconds.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let variance = sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sorted.count)

        count = sorted.count
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        self.mean = mean
        standardDeviation = variance.squareRoot()
        p50 = Self.percentile(0.50, ofSorted: sorted)
        p90 = Self.percentile(0.90, ofSorted: sorted)
        p95 = Self.percentile(0.95, ofSorted: sorted)
        p99 = Self.percentile(0.99, ofSorted: sorted)
    }

    /// Summarizes `durations`. Returns `nil` for an empty sample.
    public init?(_ durations: [Duration]) {
        self.init(milliseconds: durations.map(\.milliseconds))
    }

    /// The `fraction` percentile (`0...1`) of an ascending, non-empty array,
    /// interpolating linearly between the two closest ranks.
    ///
    /// - Precondition: `sorted` is non-empty and `fraction` is in `0...1`.
    public static func percentile(_ fraction: Double, ofSorted sorted: [Double]) -> Double {
        precondition(!sorted.isEmpty, "Percentile of an empty sample")
        precondition((0...1).contains(fraction), "Percentile fraction must be in 0...1")
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }
}

extension Duration {
    /// The duration in milliseconds, as a `Double`.
    public var milliseconds: Double { timeInterval * 1_000 }
}
