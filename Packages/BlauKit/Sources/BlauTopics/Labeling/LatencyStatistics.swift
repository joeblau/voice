/// Percentiles over a bounded window of recent latencies.
///
/// `TopicLabelingService` keeps one per label source so the p50 label
/// latency can be read at runtime (performance HUD, diagnostics) as well as
/// in Instruments (`topics.label`).
public struct LatencyStatistics: Hashable, Sendable {
    /// The most recent samples, oldest first; at most `capacity`.
    public private(set) var samples: [Duration] = []

    /// Samples recorded since creation, including ones that rolled out of
    /// the window.
    public private(set) var totalCount = 0

    public let capacity: Int

    public init(capacity: Int = 256) {
        precondition(capacity > 0, "LatencyStatistics needs a positive capacity")
        self.capacity = capacity
    }

    public mutating func record(_ latency: Duration) {
        samples.append(latency)
        totalCount += 1
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// The `fraction` percentile (0...1) by nearest rank, or `nil` without
    /// samples.
    public func percentile(_ fraction: Double) -> Duration? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = min(max(fraction, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[max(rank, 1) - 1]
    }

    public var p50: Duration? { percentile(0.5) }
    public var p90: Duration? { percentile(0.9) }
    public var maximum: Duration? { samples.max() }
}
