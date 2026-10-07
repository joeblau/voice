import Foundation

/// Smooths a stream of `0...1` meter levels the way a VU meter moves: it
/// rises quickly when the level jumps (attack) and falls back slowly
/// (release), so the record button's ring follows speech without
/// flickering on every 20 ms frame.
///
/// Each step moves the reading towards the new level by
/// `1 - exp(-elapsed / timeConstant)`, so the result doesn't depend on how
/// often levels arrive.
///
/// ```swift
/// var meter = LevelMeter()
/// let shown = meter.update(to: level.normalized(), elapsed: .milliseconds(20))
/// ```
public struct LevelMeter: Sendable, Hashable {
    /// How fast the reading rises towards a louder level.
    public var attack: Duration
    /// How fast it falls towards a quieter one.
    public var release: Duration
    /// The current reading, `0...1`.
    public private(set) var value: Float = 0

    public init(attack: Duration = .milliseconds(40), release: Duration = .milliseconds(250)) {
        precondition(attack > .zero && release > .zero, "Time constants must be positive")
        self.attack = attack
        self.release = release
    }

    /// Moves the reading towards `level` (clamped to `0...1`) over
    /// `elapsed`, and returns it.
    @discardableResult
    public mutating func update(to level: Float, elapsed: Duration) -> Float {
        let target = min(max(level.isFinite ? level : 0, 0), 1)
        guard elapsed > .zero else { return value }
        let constant = target > value ? attack : release
        let ratio = Self.seconds(elapsed) / Self.seconds(constant)
        let step = Float(1 - exp(-ratio))
        value += (target - value) * step
        // Snap the tail so a silent meter reads exactly zero.
        if abs(value - target) < 0.001 {
            value = target
        }
        return value
    }

    /// Drops the reading to zero (the stream stopped).
    public mutating func reset() {
        value = 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}

extension PlaybackLevel {
    /// The RMS level mapped to `0...1` for a meter: `floor` dBFS and below
    /// is `0`, full scale is `1`, linear in decibels in between. The same
    /// scale as `AudioLevel.normalized(floor:)`.
    public func normalized(floor: Float = -60) -> Float {
        precondition(floor < 0, "The meter floor must be below full scale")
        return (decibels(floor: floor) - floor) / -floor
    }
}
