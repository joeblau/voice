/// Measures the main thread's frame rate from display-link callbacks.
///
/// Feed it every `CADisplayLink` callback's `timestamp` and
/// `targetTimestamp` (seconds). A callback that arrives late, because the
/// main thread was busy, shows up as a long gap between timestamps; the
/// meter counts the refresh intervals that gap skipped as dropped frames.
/// The display link lives in the app (UIKit); the arithmetic lives here so
/// it is tested on the Mac.
public struct FrameRateMeter: Sendable {
    /// How much recent time the frame rate covers, in seconds.
    public let window: Double
    /// Timestamps of the frames in the window, oldest first.
    private var timestamps: [Double] = []
    private var dropped: [(at: Double, count: Int)] = []
    /// The display link's refresh interval at the latest frame.
    private var refreshInterval: Double?
    private var longestGap: [(at: Double, gap: Double)] = []

    public init(window: Double = 1) {
        precondition(window > 0, "The frame rate window must be positive")
        self.window = window
    }

    /// Records one display-link callback.
    ///
    /// - Parameters:
    ///   - timestamp: `CADisplayLink.timestamp`, when the frame was
    ///     displayed.
    ///   - targetTimestamp: `CADisplayLink.targetTimestamp`, when the next
    ///     one is due. Their difference is the refresh interval.
    public mutating func record(timestamp: Double, targetTimestamp: Double) {
        let interval = targetTimestamp - timestamp
        if interval > 0 { refreshInterval = interval }
        if let previous = timestamps.last {
            guard timestamp > previous else { return }
            let gap = timestamp - previous
            if let refreshInterval {
                // Rounded, so jitter of a fraction of a refresh isn't a drop.
                let skipped = Int((gap / refreshInterval).rounded()) - 1
                if skipped > 0 { dropped.append((timestamp, skipped)) }
            }
            longestGap.append((timestamp, gap))
        }
        timestamps.append(timestamp)
        prune(now: timestamp)
    }

    /// Forgets every frame, e.g. when the display link pauses.
    public mutating func reset() {
        timestamps.removeAll()
        dropped.removeAll()
        longestGap.removeAll()
    }

    /// The reading over the window, or `nil` before two frames.
    public var reading: FrameRateReading? {
        guard let first = timestamps.first, let last = timestamps.last, last > first else { return nil }
        let span = last - first
        return FrameRateReading(
            framesPerSecond: Double(timestamps.count - 1) / span,
            targetFramesPerSecond: refreshInterval.map { 1 / $0 },
            droppedFrames: dropped.reduce(0) { $0 + $1.count },
            longestFrame: longestGap.map(\.gap).max() ?? 0
        )
    }

    private mutating func prune(now: Double) {
        let cutoff = now - window
        if let index = timestamps.firstIndex(where: { $0 >= cutoff }), index > 0 {
            timestamps.removeFirst(index)
        }
        dropped.removeAll { $0.at < cutoff }
        longestGap.removeAll { $0.at < cutoff }
    }
}

/// The frame rate over the last second.
public struct FrameRateReading: Sendable, Hashable {
    /// Display-link callbacks per second the main thread handled.
    public var framesPerSecond: Double
    /// The display link's refresh rate (what an idle main thread reaches).
    public var targetFramesPerSecond: Double?
    /// Refreshes the main thread missed.
    public var droppedFrames: Int
    /// The longest gap between two callbacks, in seconds.
    public var longestFrame: Double

    public init(framesPerSecond: Double, targetFramesPerSecond: Double?, droppedFrames: Int, longestFrame: Double) {
        self.framesPerSecond = framesPerSecond
        self.targetFramesPerSecond = targetFramesPerSecond
        self.droppedFrames = droppedFrames
        self.longestFrame = longestFrame
    }
}
