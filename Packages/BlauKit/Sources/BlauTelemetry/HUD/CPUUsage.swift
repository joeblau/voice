import Darwin

/// Reads CPU time. The HUD takes one so tests can script the readings.
public protocol CPUTimeSource: Sendable {
    /// CPU time the whole process has used so far, on every thread, in
    /// nanoseconds.
    func processCPUTime() -> UInt64
    /// CPU time the calling thread has used so far, in nanoseconds.
    func threadCPUTime() -> UInt64
    /// A monotonic wall clock, in nanoseconds.
    func wallTime() -> UInt64
}

/// The kernel's clocks: `CLOCK_PROCESS_CPUTIME_ID` (user + system time of
/// every thread, the number Xcode's CPU gauge and Instruments' CPU usage
/// are built from), `CLOCK_THREAD_CPUTIME_ID` and `CLOCK_UPTIME_RAW`.
public struct SystemCPUTimeSource: CPUTimeSource {
    public init() {}

    public func processCPUTime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    }

    public func threadCPUTime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    public func wallTime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

/// Turns successive process CPU time readings into a CPU percentage.
///
/// 100% is one core fully busy, so a process using two cores reads 200%,
/// the same scale as Xcode's CPU gauge and `top`.
public struct CPUUsageMeter: Sendable {
    private var previous: (cpu: UInt64, wall: UInt64)?

    public init() {}

    /// Takes a reading and returns the CPU percentage since the previous
    /// one, or `nil` for the first reading (or if no wall time passed).
    public mutating func sample(cpu: UInt64, wall: UInt64) -> Double? {
        defer { previous = (cpu, wall) }
        guard let previous, wall > previous.wall, cpu >= previous.cpu else { return nil }
        return Double(cpu - previous.cpu) / Double(wall - previous.wall) * 100
    }

    /// Forgets the previous reading, e.g. after the HUD was hidden.
    public mutating func reset() {
        previous = nil
    }
}

/// Adds up the CPU time the HUD spends on itself and reports it as a share
/// of one core over a sliding window of wall time.
///
/// Everything the HUD does on its own behalf (sampling, the frame rate
/// callback) is charged here with `charge(nanoseconds:)`, measured with the
/// thread's CPU clock around the work.
public struct OverheadMeter: Sendable {
    /// The window the share is computed over.
    public let window: UInt64
    private var spans: [(wall: UInt64, cpu: UInt64)] = []
    private var total: UInt64 = 0
    private var startedAt: UInt64?

    /// - Parameter windowSeconds: How much recent wall time the share
    ///   covers.
    public init(windowSeconds: Double = 10) {
        window = UInt64(windowSeconds * 1_000_000_000)
    }

    /// Starts the clock: the share is measured from `wall` on.
    public mutating func start(at wall: UInt64) {
        startedAt = wall
        spans.removeAll()
        total = 0
    }

    /// Charges `nanoseconds` of CPU time spent at `wall`.
    public mutating func charge(nanoseconds: UInt64, at wall: UInt64) {
        if startedAt == nil { startedAt = wall }
        spans.append((wall, nanoseconds))
        total += nanoseconds
        prune(now: wall)
    }

    /// The HUD's CPU time as a share of one core (`0.01` is 1%) over the
    /// last `window` of wall time, or `nil` before any time has passed.
    public mutating func fraction(now: UInt64) -> Double? {
        prune(now: now)
        guard let startedAt, now > startedAt else { return nil }
        let elapsed = min(now - startedAt, window)
        return Double(total) / Double(elapsed)
    }

    private mutating func prune(now: UInt64) {
        guard now > window else { return }
        let cutoff = now - window
        var dropped = 0
        while dropped < spans.count, spans[dropped].wall < cutoff {
            total -= spans[dropped].cpu
            dropped += 1
        }
        if dropped > 0 { spans.removeFirst(dropped) }
    }
}
