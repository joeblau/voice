/// The thresholds `PerformancePolicy` applies (#75).
///
/// The defaults:
///
/// | Condition | Level |
/// | --- | --- |
/// | Thermal state `serious` | `reduced` |
/// | Thermal state `critical` | `minimal` |
/// | Low Power Mode on | `reduced` |
/// | On battery at 20% or less | `reduced` (until 25%, or plugged in) |
/// | On battery at 10% or less | `minimal` (until 15%, or plugged in) |
///
/// The strictest condition wins. A worse level applies at once; a better
/// one only after `recoveryDelay` without anything calling for the worse
/// one, one level at a time, so a device hovering at a boundary doesn't
/// flip the pipeline back and forth.
public struct PerformancePolicyConfiguration: Codable, Hashable, Sendable {
    /// `reduced` from this thermal state up.
    public var reducedThermalState: ThermalState
    /// `minimal` from this thermal state up.
    public var minimalThermalState: ThermalState
    /// The level Low Power Mode calls for.
    public var lowPowerModeLevel: PerformanceLevel
    /// `reduced` at this charge (0–1) or less, on battery.
    public var reducedBatteryLevel: Double
    /// `minimal` at this charge (0–1) or less, on battery.
    public var minimalBatteryLevel: Double
    /// A battery level holds until the charge is this much (0–1) above its
    /// threshold, so a reading bouncing between 20% and 21% doesn't flap.
    public var batteryHysteresis: Double
    /// How long conditions must allow a better level before it applies.
    public var recoveryDelay: Duration

    /// - Precondition: `minimalThermalState >= reducedThermalState`,
    ///   `0 <= minimalBatteryLevel <= reducedBatteryLevel <= 1`,
    ///   `batteryHysteresis >= 0`, `recoveryDelay >= 0`.
    public init(
        reducedThermalState: ThermalState = .serious,
        minimalThermalState: ThermalState = .critical,
        lowPowerModeLevel: PerformanceLevel = .reduced,
        reducedBatteryLevel: Double = 0.20,
        minimalBatteryLevel: Double = 0.10,
        batteryHysteresis: Double = 0.05,
        recoveryDelay: Duration = .seconds(60)
    ) {
        precondition(minimalThermalState >= reducedThermalState, "minimal must not trigger before reduced")
        precondition(
            0 <= minimalBatteryLevel && minimalBatteryLevel <= reducedBatteryLevel && reducedBatteryLevel <= 1,
            "Battery thresholds must satisfy 0 <= minimal <= reduced <= 1")
        precondition(batteryHysteresis >= 0, "The battery hysteresis can't be negative")
        precondition(recoveryDelay >= .zero, "The recovery delay can't be negative")
        self.reducedThermalState = reducedThermalState
        self.minimalThermalState = minimalThermalState
        self.lowPowerModeLevel = lowPowerModeLevel
        self.reducedBatteryLevel = reducedBatteryLevel
        self.minimalBatteryLevel = minimalBatteryLevel
        self.batteryHysteresis = batteryHysteresis
        self.recoveryDelay = recoveryDelay
    }

    public static let standard = PerformancePolicyConfiguration()

    /// The level `conditions` call for on their own, and why, with no
    /// recovery delay. `currentBattery` is the level the battery itself
    /// last called for (`batteryLevel(for:current:)`), for the battery
    /// hysteresis; the level in force doesn't matter, so a device degraded
    /// for heat or Low Power Mode at 21–24% recovers fully once it cools.
    public func assess(_ conditions: DeviceConditions, currentBattery: PerformanceLevel) -> PerformanceAssessment {
        var causes: [(PerformanceLevel, PerformanceReason)] = []

        if conditions.thermalState >= minimalThermalState {
            causes.append((.minimal, .thermal(conditions.thermalState)))
        } else if conditions.thermalState >= reducedThermalState {
            causes.append((.reduced, .thermal(conditions.thermalState)))
        }

        if conditions.isLowPowerModeEnabled, lowPowerModeLevel.isDegraded {
            causes.append((lowPowerModeLevel, .lowPowerMode))
        }

        let battery = conditions.battery
        let batteryLevel = batteryLevel(for: battery, current: currentBattery)
        if batteryLevel.isDegraded {
            causes.append((batteryLevel, .lowBattery(percent: battery.percent ?? 0)))
        }

        let level = causes.map(\.0).max() ?? .normal
        // Worst cause first.
        let reasons = causes.sorted { $0.0 > $1.0 }.map(\.1)
        return PerformanceAssessment(level: level, reasons: reasons)
    }

    /// The level the battery alone calls for: `reduced` or `minimal` at its
    /// threshold, held until the charge is `batteryHysteresis` above it
    /// while `current` (the level the battery last called for) is at least
    /// that level; `normal` while charging, full or unknown.
    public func batteryLevel(for battery: BatteryStatus, current: PerformanceLevel) -> PerformanceLevel {
        guard battery.isDischarging, let charge = battery.level else { return .normal }
        if charge <= minimalBatteryLevel
            || (current >= .minimal && charge < minimalBatteryLevel + batteryHysteresis)
        {
            return .minimal
        }
        if charge <= reducedBatteryLevel
            || (current >= .reduced && charge < reducedBatteryLevel + batteryHysteresis)
        {
            return .reduced
        }
        return .normal
    }
}

/// Why the pipeline runs below `normal`.
public enum PerformanceReason: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The device is hot.
    case thermal(ThermalState)
    /// Low Power Mode is on.
    case lowPowerMode
    /// The battery is low and discharging.
    case lowBattery(percent: Int)
    /// Set by hand (the debug menu, or a UI test).
    case override

    public var description: String {
        switch self {
        case .thermal(let state): "thermal state \(state.rawValue)"
        case .lowPowerMode: "Low Power Mode"
        case .lowBattery(let percent): "battery at \(percent)%"
        case .override: "override"
        }
    }
}

/// The level some conditions call for, and why.
public struct PerformanceAssessment: Codable, Hashable, Sendable {
    public var level: PerformanceLevel
    /// Empty at `normal`; the strictest cause first.
    public var reasons: [PerformanceReason]

    public init(level: PerformanceLevel, reasons: [PerformanceReason]) {
        self.level = level
        self.reasons = reasons
    }
}

/// The policy's decision logic as a value: feed it conditions and the time,
/// read the level. `PerformancePolicy` wraps it with the device's
/// notifications and a timer; tests drive it directly.
///
/// - A **worse** level applies on the update that calls for it.
/// - A **better** level waits until conditions have allowed it for
///   `recoveryDelay`, then relaxes **one level**; the next level waits
///   another `recoveryDelay`. `recoveryDeadline` says when to re-evaluate.
/// - An **override** replaces the assessment until it is cleared, in either
///   direction and without a delay.
public struct PerformanceLevelTracker: Sendable {
    public let configuration: PerformancePolicyConfiguration
    public private(set) var level: PerformanceLevel = .normal
    /// Why `level` is degraded; empty at `normal`. While a recovery is
    /// pending these stay the causes of the level still in force.
    public private(set) var reasons: [PerformanceReason] = []
    public private(set) var conditions: DeviceConditions = .nominal
    public private(set) var override: PerformanceLevel?
    /// The level the battery alone last called for: the battery hysteresis
    /// holds this, not `level`, so heat or Low Power Mode never borrow it.
    /// Follows every reading, even while a recovery is pending.
    private var batteryLevel: PerformanceLevel = .normal
    /// When conditions started to allow a better level than `level`.
    private var calmSince: Duration?

    public init(configuration: PerformancePolicyConfiguration = .standard) {
        self.configuration = configuration
    }

    /// When a pending recovery is due, if one is pending.
    public var recoveryDeadline: Duration? {
        calmSince.map { $0 + configuration.recoveryDelay }
    }

    /// Whether conditions already allow a better level and the tracker is
    /// waiting out `recoveryDelay`.
    public var isRecovering: Bool { calmSince != nil }

    /// New readings. Returns whether `level` or `reasons` changed.
    @discardableResult
    public mutating func update(_ conditions: DeviceConditions, at now: Duration) -> Bool {
        self.conditions = conditions
        return evaluate(at: now)
    }

    /// Sets or clears the override. Returns whether `level` or `reasons`
    /// changed.
    @discardableResult
    public mutating func setOverride(_ level: PerformanceLevel?, at now: Duration) -> Bool {
        let wasOverridden = override != nil
        override = level
        if level == nil, wasOverridden {
            // Leaving a simulation applies the real conditions at once.
            let before = (self.level, reasons)
            batteryLevel = configuration.batteryLevel(for: conditions.battery, current: .normal)
            let assessment = configuration.assess(conditions, currentBattery: .normal)
            self.level = assessment.level
            reasons = assessment.reasons
            calmSince = nil
            return before != (self.level, reasons)
        }
        return evaluate(at: now)
    }

    /// Re-evaluates with the same conditions: applies a recovery whose
    /// delay has passed. Returns whether `level` or `reasons` changed.
    @discardableResult
    public mutating func evaluate(at now: Duration) -> Bool {
        let before = (level, reasons)

        if let override {
            level = override
            reasons = override.isDegraded ? [.override] : []
            calmSince = nil
            return before != (level, reasons)
        }

        let assessment = configuration.assess(conditions, currentBattery: batteryLevel)
        batteryLevel = configuration.batteryLevel(for: conditions.battery, current: batteryLevel)
        if assessment.level >= level {
            level = assessment.level
            reasons = assessment.reasons
            calmSince = nil
        } else {
            let since = calmSince ?? now
            calmSince = since
            if now - since >= configuration.recoveryDelay {
                let relaxed = max(level.relaxed ?? .normal, assessment.level)
                level = relaxed
                if relaxed == assessment.level {
                    reasons = assessment.reasons
                    calmSince = nil
                } else {
                    // One step at a time: the next one waits a full delay.
                    calmSince = now
                }
            }
        }
        return before != (level, reasons)
    }
}
