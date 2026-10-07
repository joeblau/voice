import BlauCore

/// The policy's state at one moment, as `PerformancePolicy.updates()`
/// delivers it.
public struct PerformanceSnapshot: Codable, Hashable, Sendable {
    public var level: PerformanceLevel
    /// Why `level` is degraded, strictest first; empty at `normal`.
    public var reasons: [PerformanceReason]
    /// The latest readings.
    public var conditions: DeviceConditions
    /// The level set by hand, if any.
    public var override: PerformanceLevel?
    /// Conditions already allow a better level; it applies once the
    /// recovery delay has passed.
    public var isRecovering: Bool

    public init(
        level: PerformanceLevel = .normal,
        reasons: [PerformanceReason] = [],
        conditions: DeviceConditions = .nominal,
        override: PerformanceLevel? = nil,
        isRecovering: Bool = false
    ) {
        self.level = level
        self.reasons = reasons
        self.conditions = conditions
        self.override = override
        self.isRecovering = isRecovering
    }
}

/// How a session went thermally and on power: time at each level and
/// thermal state, the worst of each, level changes and battery drain.
/// Long-session soak reports carry it to check that an hour stays at or
/// below `fair`, or degrades gracefully (#75, docs/performance.md).
public struct PerformanceStatistics: Codable, Hashable, Sendable {
    /// One level change.
    public struct Transition: Codable, Hashable, Sendable {
        /// Seconds since recording started.
        public var atSeconds: Double
        public var from: PerformanceLevel
        public var to: PerformanceLevel
        public var reasons: [PerformanceReason]
        public var thermalState: ThermalState
    }

    /// The transitions kept, newest last.
    public static let transitionLimit = 100

    /// Seconds recorded.
    public var seconds: Double = 0
    /// Seconds at each `PerformanceLevel`, keyed by its raw value.
    public var secondsAtLevel: [String: Double] = [:]
    /// Seconds at each `ThermalState`, keyed by its raw value.
    public var secondsAtThermalState: [String: Double] = [:]
    public var worstLevel: PerformanceLevel = .normal
    public var worstThermalState: ThermalState = .nominal
    /// Seconds the device was at the policy's `reduced` thermal state or
    /// hotter while the pipeline still ran at `normal`: what "degrades
    /// gracefully" rules out. Zero unless an override held the level.
    public var secondsHotAtNormal: Double = 0
    public var levelChanges: Int = 0
    /// The most recent level changes, oldest first.
    public var transitions: [Transition] = []
    /// Seconds in Low Power Mode.
    public var lowPowerModeSeconds: Double = 0
    /// Seconds on battery (discharging).
    public var dischargingSeconds: Double = 0
    /// Charge (0–1) when recording started and at the latest reading, if
    /// the device reports it.
    public var batteryAtStart: Double?
    public var batteryAtEnd: Double?
    /// Charge (0–1) lost while discharging.
    public var batteryDrained: Double = 0

    public init() {}

    public func seconds(at level: PerformanceLevel) -> Double { secondsAtLevel[level.rawValue] ?? 0 }

    public func seconds(at state: ThermalState) -> Double { secondsAtThermalState[state.rawValue] ?? 0 }

    /// Seconds at `fair` or cooler.
    public var secondsAtOrBelowFair: Double { seconds(at: .nominal) + seconds(at: .fair) }

    /// Battery lost per hour on battery, in percent, once at least a minute
    /// on battery has been seen.
    public var batteryDrainPercentPerHour: Double? {
        guard dischargingSeconds >= 60 else { return nil }
        return batteryDrained * 100 / (dischargingSeconds / 3_600)
    }
}

/// Accumulates `PerformanceStatistics` from snapshots. Each snapshot holds
/// until the next one (or until `statistics(at:)`).
public struct PerformanceStatisticsRecorder: Sendable {
    /// The thermal state the policy degrades at, for `secondsHotAtNormal`.
    public let hotThermalState: ThermalState
    private let start: Duration
    private var last: (snapshot: PerformanceSnapshot, at: Duration)?
    private var accumulated = PerformanceStatistics()

    public init(start: Duration, hotThermalState: ThermalState = .serious) {
        self.start = start
        self.hotThermalState = hotThermalState
    }

    /// Records `snapshot`, taken at `now` (the clock's uptime).
    public mutating func record(_ snapshot: PerformanceSnapshot, at now: Duration) {
        accumulate(until: now)
        if let previous = last?.snapshot {
            if previous.level != snapshot.level {
                accumulated.levelChanges += 1
                accumulated.transitions.append(
                    PerformanceStatistics.Transition(
                        atSeconds: (now - start).timeInterval, from: previous.level, to: snapshot.level,
                        reasons: snapshot.reasons, thermalState: snapshot.conditions.thermalState))
                if accumulated.transitions.count > PerformanceStatistics.transitionLimit {
                    accumulated.transitions.removeFirst(
                        accumulated.transitions.count - PerformanceStatistics.transitionLimit)
                }
            }
            if previous.conditions.battery.isDischarging, snapshot.conditions.battery.isDischarging,
                let before = previous.conditions.battery.level, let after = snapshot.conditions.battery.level
            {
                accumulated.batteryDrained += max(0, before - after)
            }
        } else {
            accumulated.batteryAtStart = snapshot.conditions.battery.level
        }
        if let level = snapshot.conditions.battery.level {
            accumulated.batteryAtEnd = level
        }
        accumulated.worstLevel = max(accumulated.worstLevel, snapshot.level)
        accumulated.worstThermalState = max(accumulated.worstThermalState, snapshot.conditions.thermalState)
        last = (snapshot, now)
    }

    /// The statistics up to `now`.
    public func statistics(at now: Duration) -> PerformanceStatistics {
        var copy = self
        copy.accumulate(until: now)
        return copy.accumulated
    }

    private mutating func accumulate(until now: Duration) {
        guard let (snapshot, since) = last, now > since else { return }
        let elapsed = (now - since).timeInterval
        accumulated.seconds += elapsed
        accumulated.secondsAtLevel[snapshot.level.rawValue, default: 0] += elapsed
        accumulated.secondsAtThermalState[snapshot.conditions.thermalState.rawValue, default: 0] += elapsed
        if snapshot.level == .normal, snapshot.conditions.thermalState >= hotThermalState {
            accumulated.secondsHotAtNormal += elapsed
        }
        if snapshot.conditions.isLowPowerModeEnabled { accumulated.lowPowerModeSeconds += elapsed }
        if snapshot.conditions.battery.isDischarging { accumulated.dischargingSeconds += elapsed }
        last = (snapshot, now)
    }
}
