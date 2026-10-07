import Foundation

extension Duration {
    /// The duration of `count` samples at `sampleRate` Hz.
    ///
    /// Computed in integers, so there is no floating-point drift over long
    /// sessions. When the result isn't a whole number of attoseconds it is
    /// rounded up, which keeps `sampleCount(sampleRate:)` an exact inverse.
    /// Derive a position from its absolute sample index rather than by summing
    /// per-chunk durations.
    ///
    /// - Precondition: `count >= 0` and `sampleRate > 0`.
    public static func samples(_ count: Int64, sampleRate: Int) -> Duration {
        precondition(count >= 0, "Sample count must not be negative")
        precondition(sampleRate > 0, "Sample rate must be positive")
        let rate = Int64(sampleRate)
        let (wholeSeconds, remainder) = count.quotientAndRemainder(dividingBy: rate)
        // remainder < rate, so this is below one second and fits in Int64.
        let attoseconds = (Int128(remainder) * attosecondsPerSecond + Int128(rate) - 1) / Int128(rate)
        return Duration(secondsComponent: wholeSeconds, attosecondsComponent: Int64(attoseconds))
    }

    /// The number of whole samples at `sampleRate` Hz that fit in this
    /// duration (rounded toward zero).
    ///
    /// - Precondition: `sampleRate > 0`.
    public func sampleCount(sampleRate: Int) -> Int64 {
        precondition(sampleRate > 0, "Sample rate must be positive")
        let (seconds, attoseconds) = components
        let totalAttoseconds = Int128(seconds) * Self.attosecondsPerSecond + Int128(attoseconds)
        return Int64(totalAttoseconds * Int128(sampleRate) / Self.attosecondsPerSecond)
    }

    private static var attosecondsPerSecond: Int128 { 1_000_000_000_000_000_000 }

    /// The duration in seconds as a `TimeInterval`, for APIs that take one.
    /// Precision is limited to what a `Double` can hold.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
