import Darwin

/// Host time: the `mach_absolute_time` ticks Core Audio stamps buffers with
/// (`AVAudioTime.hostTime`, `AudioFrame.hostTime`).
///
/// Host time stops while the device sleeps, `BlauClock.uptime` doesn't, so
/// the two can't be compared directly. What can be compared is a *recent*
/// host time's age: `elapsed(since:)` says how long ago a buffer was
/// captured, and `uptime - age` places it on the uptime timeline. Over the
/// few seconds a pipeline stage looks back that is exact to the tick.
public enum HostClock {
    /// The current host time.
    public static var now: UInt64 { mach_absolute_time() }

    /// `ticks` of host time as a duration.
    public static func duration(ofTicks ticks: UInt64) -> Duration {
        // 24 MHz on Apple silicon (125/3 ns per tick), 1 GHz on Intel (1/1).
        let denominator = UInt64(timebase.denom)
        let nanoseconds = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        // The quotient wouldn't fit in 64 bits: centuries, not a real span.
        guard nanoseconds.high < denominator else { return .nanoseconds(Int64.max) }
        let (quotient, _) = denominator.dividingFullWidth(nanoseconds)
        return .nanoseconds(Int64(clamping: quotient))
    }

    /// `duration` in host time ticks (rounded down); zero for a negative
    /// duration.
    public static func ticks(for duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let (seconds, attoseconds) = duration.components
        let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        let ticks = nanoseconds * Double(timebase.denom) / Double(timebase.numer)
        return ticks >= Double(UInt64.max) ? .max : UInt64(ticks)
    }

    /// How long ago `hostTime` was, measured at `now`. Zero for a host time
    /// that isn't in the past.
    public static func elapsed(since hostTime: UInt64, now: UInt64 = HostClock.now) -> Duration {
        guard now > hostTime else { return .zero }
        return duration(ofTicks: now - hostTime)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 { info = mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }()
}
