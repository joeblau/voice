import BlauCore

/// Exponential backoff with optional jitter.
///
/// Retry `n` (0-based) waits `initialDelay * multiplier^n`, capped at
/// `maximumDelay`, then spread by ±`jitter` (a fraction of the delay) so
/// devices that lost the network together don't retry in lockstep. A
/// server's `Retry-After` hint is honoured when it asks for longer.
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts, including the first. `1` disables retries.
    public var maximumAttempts: Int
    public var initialDelay: Duration
    public var multiplier: Double
    public var maximumDelay: Duration
    /// 0…1. `0.2` spreads each delay over ±20 %.
    public var jitter: Double

    public init(
        maximumAttempts: Int,
        initialDelay: Duration,
        multiplier: Double = 2,
        maximumDelay: Duration,
        jitter: Double = 0
    ) {
        precondition(maximumAttempts >= 1, "At least one attempt")
        precondition(initialDelay >= .zero && maximumDelay >= .zero, "Delays can't be negative")
        precondition(multiplier >= 1, "Backoff must not shrink")
        precondition((0...1).contains(jitter), "Jitter is a fraction of the delay")
        self.maximumAttempts = maximumAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.jitter = jitter
    }

    /// Token minting: 4 attempts over roughly 1 + 2 + 4 = 7 s.
    public static let tokenMinting = RetryPolicy(
        maximumAttempts: 4, initialDelay: .seconds(1), multiplier: 2, maximumDelay: .seconds(8), jitter: 0.2)

    /// No retries.
    public static let noRetries = RetryPolicy(maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero)

    /// The wait before retry `retry` (0 for the first retry).
    ///
    /// - Parameters:
    ///   - retryAfter: The server's `Retry-After`, if any. Used when longer
    ///     than the backoff, but never beyond `maximumDelay`.
    ///   - unitRandom: A value in `0..<1` that picks the jitter. Tests pass a
    ///     constant.
    public func delay(beforeRetry retry: Int, retryAfter: Duration? = nil, unitRandom: Double) -> Duration {
        // Computed in seconds so a large `retry` saturates at the cap
        // instead of overflowing `Duration`.
        let cap = maximumDelay.timeInterval
        var seconds = initialDelay.timeInterval
        for _ in 0..<max(retry, 0) where seconds < cap {
            seconds *= multiplier
        }
        seconds = min(seconds, cap)
        if jitter > 0 {
            seconds *= 1 + jitter * (2 * min(max(unitRandom, 0), 1) - 1)
        }
        if let retryAfter, retryAfter.timeInterval > seconds {
            seconds = retryAfter.timeInterval
        }
        return .seconds(min(max(seconds, 0), cap))
    }
}
