/// What `PerformancePolicy` reads from the device: temperature, Low Power
/// Mode and the battery.
public struct DeviceConditions: Codable, Hashable, Sendable {
    /// `ProcessInfo.thermalState`.
    public var thermalState: ThermalState
    /// `ProcessInfo.isLowPowerModeEnabled`.
    public var isLowPowerModeEnabled: Bool
    public var battery: BatteryStatus

    public init(
        thermalState: ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false,
        battery: BatteryStatus = .unknown
    ) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.battery = battery
    }

    /// A cool device on mains power: the `normal` level.
    public static let nominal = DeviceConditions()
}

/// The battery's charge and whether it is charging.
public struct BatteryStatus: Codable, Hashable, Sendable {
    /// `UIDevice.BatteryState`, without a UIKit dependency.
    public enum State: String, Codable, Hashable, Sendable {
        /// Not reported: the simulator, a Mac, or battery monitoring off.
        case unknown
        /// On battery, discharging.
        case unplugged
        /// Plugged in and charging.
        case charging
        /// Plugged in and full.
        case full
    }

    /// Charge from 0 to 1, or `nil` when it isn't known.
    public var level: Double?
    public var state: State

    public init(level: Double?, state: State) {
        self.level = level.map { min(max($0, 0), 1) }
        self.state = state
    }

    /// No battery information.
    public static let unknown = BatteryStatus(level: nil, state: .unknown)

    /// Running on the battery: only then does its charge limit the work.
    /// Charging or full means mains power, whatever the charge.
    public var isDischarging: Bool { state == .unplugged }

    /// The charge in whole percent, for logs and the UI.
    public var percent: Int? { level.map { Int(($0 * 100).rounded()) } }
}
