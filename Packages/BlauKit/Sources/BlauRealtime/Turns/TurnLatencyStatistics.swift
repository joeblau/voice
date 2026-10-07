import BlauTelemetry

/// The latest `capacity` samples of one latency, with their summary.
///
/// The summary (`LatencySummary`: p50, p95, …) is recomputed only when a
/// sample is added, so reading it from every UI snapshot is free.
public struct RollingLatency: Sendable, Hashable {
    /// How many recent samples the summary covers.
    public let capacity: Int
    /// The kept samples, oldest first.
    public private(set) var samples: [Duration] = []
    /// The most recent sample.
    public private(set) var last: Duration?
    /// Every sample ever added, including those that fell out of the window.
    public private(set) var totalCount = 0
    /// Order statistics over `samples`, or `nil` before the first one.
    public private(set) var summary: LatencySummary?

    /// - Precondition: `capacity >= 1`.
    public init(capacity: Int = 200) {
        precondition(capacity >= 1, "RollingLatency needs room for at least one sample")
        self.capacity = capacity
    }

    public mutating func add(_ sample: Duration) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        last = sample
        totalCount += 1
        summary = LatencySummary(samples)
    }

    /// The median of the window.
    public var p50: Duration? { summary.map { .milliseconds($0.p50) } }

    /// The 95th percentile of the window.
    public var p95: Duration? { summary.map { .milliseconds($0.p95) } }
}

/// The voice loop's latencies, as the HUD shows them.
///
/// - `firstAudio`: end of utterance (the final reaching the orchestrator) to
///   the reply's first `response.output_audio.delta`: what the user hears as
///   Grok's reaction time. Same span as the `realtime.firstAudio` signpost.
/// - `turn`: end of utterance to `response.done`. Same span as
///   `realtime.turn`.
///
/// Only turns sent straight away count. A turn that waited for the
/// connection to come back measures the outage, and one cut short by a
/// newer utterance has no end, so neither is sampled.
public struct TurnLatencyStatistics: Sendable, Hashable {
    public private(set) var firstAudio: RollingLatency
    public private(set) var turn: RollingLatency

    public init(capacity: Int = 200) {
        firstAudio = RollingLatency(capacity: capacity)
        turn = RollingLatency(capacity: capacity)
    }

    public mutating func recordFirstAudio(_ latency: Duration) {
        firstAudio.add(latency)
    }

    public mutating func recordTurn(_ duration: Duration) {
        turn.add(duration)
    }
}
