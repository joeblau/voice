/// The most recent samples of one latency, kept in a fixed-size ring.
///
/// Adding a sample is O(1) and never allocates once the ring is full, so it
/// is cheap enough for per-chunk intervals on pipeline threads. The order
/// statistics (`LatencyStats`) are computed only when someone reads them,
/// which the performance HUD does a couple of times a second.
public struct LatencyWindow: Sendable, Hashable {
    /// How many recent samples the statistics cover.
    public let capacity: Int
    /// The ring, in milliseconds. Holds `min(totalCount, capacity)` samples.
    private var ring: [Double] = []
    /// Where the next sample goes once the ring is full.
    private var nextIndex = 0
    /// The most recent sample, in milliseconds.
    public private(set) var lastMilliseconds: Double?
    /// Every sample ever added, including those that fell out of the window.
    public private(set) var totalCount = 0

    /// - Precondition: `capacity >= 1`.
    public init(capacity: Int = 200) {
        precondition(capacity >= 1, "LatencyWindow needs room for at least one sample")
        self.capacity = capacity
        ring.reserveCapacity(capacity)
    }

    /// Adds one sample. Non-finite or negative values are ignored.
    public mutating func add(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if ring.count < capacity {
            ring.append(milliseconds)
        } else {
            ring[nextIndex] = milliseconds
        }
        nextIndex = (nextIndex + 1) % capacity
        lastMilliseconds = milliseconds
        totalCount += 1
    }

    /// Adds one sample.
    public mutating func add(_ duration: Duration) {
        add(milliseconds: duration.milliseconds)
    }

    /// The samples in the window, oldest first.
    public var samples: [Double] {
        guard ring.count == capacity else { return ring }
        return Array(ring[nextIndex...] + ring[..<nextIndex])
    }

    /// Order statistics over the window, or `nil` before the first sample.
    public var stats: LatencyStats? {
        guard let lastMilliseconds, !ring.isEmpty else { return nil }
        // Only what the HUD shows: one sort, no variance or extra percentiles.
        let sorted = ring.sorted()
        return LatencyStats(
            last: lastMilliseconds,
            p50: LatencySummary.percentile(0.5, ofSorted: sorted),
            p95: LatencySummary.percentile(0.95, ofSorted: sorted),
            mean: sorted.reduce(0, +) / Double(sorted.count),
            maximum: sorted[sorted.count - 1],
            windowCount: sorted.count,
            totalCount: totalCount)
    }
}

/// What the HUD shows for one latency: last, p50, p95, mean and max over a
/// window of recent samples. Every value is in milliseconds.
///
/// Percentiles use `LatencySummary`'s definition (linear interpolation
/// between the closest ranks).
public struct LatencyStats: Sendable, Hashable, Codable {
    public var last: Double
    public var p50: Double
    public var p95: Double
    public var mean: Double
    public var maximum: Double
    /// Samples the window covers.
    public var windowCount: Int
    /// Samples recorded in total.
    public var totalCount: Int

    public init(
        last: Double, p50: Double, p95: Double, mean: Double, maximum: Double, windowCount: Int, totalCount: Int
    ) {
        self.last = last
        self.p50 = p50
        self.p95 = p95
        self.mean = mean
        self.maximum = maximum
        self.windowCount = windowCount
        self.totalCount = totalCount
    }

    /// Statistics for a latency kept elsewhere as `Duration`s (for example
    /// the turn orchestrator's rolling window). `nil` for an empty sample.
    public init?(last: Duration?, samples: [Duration], totalCount: Int? = nil) {
        guard let last, let summary = LatencySummary(samples) else { return nil }
        self.init(
            last: last.milliseconds, p50: summary.p50, p95: summary.p95, mean: summary.mean,
            maximum: summary.maximum, windowCount: summary.count, totalCount: totalCount ?? summary.count)
    }
}
