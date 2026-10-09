import Foundation
import Synchronization

#if canImport(UIKit)
    import UIKit
#endif

/// Where `PerformancePolicy` gets its readings.
public protocol DeviceConditionsSource: Sendable {
    /// The current conditions, then the conditions after every change.
    /// Observation stops when the consumer stops iterating.
    func conditions() -> AsyncStream<DeviceConditions>
}

// MARK: - System

/// The device's own readings:
///
/// - `ProcessInfo.thermalState`, updated on
///   `ProcessInfo.thermalStateDidChangeNotification`;
/// - `ProcessInfo.isLowPowerModeEnabled`, updated on
///   `.NSProcessInfoPowerStateDidChange`;
/// - on iOS, `UIDevice.batteryLevel` and `batteryState`, updated on
///   `UIDevice.batteryLevelDidChangeNotification` and
///   `batteryStateDidChangeNotification`. Opening a stream turns battery
///   monitoring on (and leaves it on: the app follows the battery for its
///   whole life). The simulator and the Mac report no battery, so only
///   temperature and Low Power Mode count there.
///
/// Thermal and power notifications arrive on arbitrary threads; every
/// notification re-reads all the conditions, so they are never stale.
public struct SystemDeviceConditionsSource: DeviceConditionsSource {
    public init() {}

    public func conditions() -> AsyncStream<DeviceConditions> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DeviceConditions.self, bufferingPolicy: .bufferingNewest(1))
        var names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
        ]
        #if os(iOS)
            names += [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification]
        #endif
        // Observe before the first reading, so no change falls between.
        let observers = NotificationObservers()
        let signals = observers.signals(named: names)
        let task = Task {
            #if os(iOS)
                await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true }
            #endif
            continuation.yield(await Self.read())
            for await _ in signals {
                continuation.yield(await Self.read())
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            observers.removeAll()
        }
        return stream
    }

    /// Reads every condition now.
    public static func read() async -> DeviceConditions {
        let info = ProcessInfo.processInfo
        return DeviceConditions(
            thermalState: ThermalState(info.thermalState),
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            battery: await readBattery()
        )
    }

    private static func readBattery() async -> BatteryStatus {
        #if os(iOS)
            await MainActor.run {
                let device = UIDevice.current
                guard device.isBatteryMonitoringEnabled else { return .unknown }
                let state: BatteryStatus.State =
                    switch device.batteryState {
                    case .unplugged: .unplugged
                    case .charging: .charging
                    case .full: .full
                    case .unknown: .unknown
                    @unknown default: .unknown
                    }
                // -1 when the level is unknown (the simulator).
                let level = device.batteryLevel
                return BatteryStatus(level: level < 0 ? nil : Double(level), state: state)
            }
        #else
            .unknown
        #endif
    }
}

/// Block observers for a set of notifications, merged into one stream of
/// signals, removed together.
private final class NotificationObservers: Sendable {
    private let tokens = Mutex<[ObserverToken]>([])

    /// One `Void` per notification. Bursts coalesce: a consumer that falls
    /// behind sees at most one pending signal.
    func signals(named names: [Notification.Name]) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let added = names.map { name in
            ObserverToken(center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() })
        }
        tokens.withLock { $0 += added }
        return stream
    }

    func removeAll() {
        let removed = tokens.withLock { tokens in
            defer { tokens.removeAll() }
            return tokens
        }
        for token in removed {
            NotificationCenter.default.removeObserver(token.observer)
        }
    }
}

/// Carries a block observer's token across concurrency domains.
///
/// `@unchecked Sendable` because the token (`any NSObjectProtocol`) isn't
/// marked Sendable. That is safe here: the token is immutable and only ever
/// passed back to `NotificationCenter.removeObserver(_:)`, and
/// `NotificationCenter` is thread-safe.
private final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) {
        self.observer = observer
    }
}

// MARK: - Manual

/// Conditions set by hand: for tests, previews, UI tests and the debug
/// menu's simulation.
public final class ManualDeviceConditionsSource: DeviceConditionsSource {
    private struct State {
        var conditions: DeviceConditions
        var nextID: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<DeviceConditions>.Continuation] = [:]
    }

    private let state: Mutex<State>

    public init(_ conditions: DeviceConditions = .nominal) {
        state = Mutex(State(conditions: conditions))
    }

    /// The conditions now.
    public var current: DeviceConditions { state.withLock { $0.conditions } }

    /// Replaces the conditions and tells every open stream.
    ///
    /// Streams are told under the lock, so concurrent sends reach every
    /// stream in the order they were applied and the last reading a stream
    /// delivers is `current`. `yield` neither blocks nor runs
    /// `onTermination`, so the lock is never re-entered.
    public func send(_ conditions: DeviceConditions) {
        state.withLock { state in
            state.conditions = conditions
            for subscriber in state.subscribers.values {
                subscriber.yield(conditions)
            }
        }
    }

    /// Changes some of the conditions.
    public func update(_ change: (inout DeviceConditions) -> Void) {
        var conditions = current
        change(&conditions)
        send(conditions)
    }

    public func conditions() -> AsyncStream<DeviceConditions> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceConditions.self)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = continuation
            continuation.yield(state.conditions)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}
