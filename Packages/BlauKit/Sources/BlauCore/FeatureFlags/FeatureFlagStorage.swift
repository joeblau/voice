import Foundation
import Synchronization

/// Where `FeatureFlags` keeps overrides.
///
/// Production uses `UserDefaultsFeatureFlagStorage`; tests, previews and UI
/// tests use `InMemoryFeatureFlagStorage` so nothing leaks between runs.
/// Implementations must be safe to call from any thread.
public protocol FeatureFlagStorage: Sendable {
    /// The override for `flag`, or `nil` when there is none.
    func overrideValue(for flag: FeatureFlag) -> Bool?

    /// Stores `value` as the override for `flag`; `nil` removes it.
    func setOverrideValue(_ value: Bool?, for flag: FeatureFlag)
}

// MARK: - UserDefaults

/// Keeps overrides in `UserDefaults` under each flag's `defaultsKey`.
///
/// Reads go through `object(forKey:)`, so they see every domain
/// `UserDefaults` searches, including the launch arguments:
/// `-blau.featureFlag.perfHUD YES` overrides the flag for that run. Values
/// written by `setOverrideValue(_:for:)` persist in the app domain. A
/// launch-argument override wins over a stored one and can't be removed at
/// runtime, because the argument domain is read-only.
public struct UserDefaultsFeatureFlagStorage: FeatureFlagStorage {
    // `UserDefaults` is documented as thread-safe ("you can use it from
    // multiple threads without synchronization") but isn't annotated
    // `Sendable` in the SDK. This value is only ever used through its
    // thread-safe get / set / remove methods.
    nonisolated(unsafe) private let defaults: UserDefaults

    /// - Parameter defaults: Defaults to `.standard`. Tests pass a throwaway
    ///   suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func overrideValue(for flag: FeatureFlag) -> Bool? {
        guard let value = defaults.object(forKey: flag.defaultsKey) else { return nil }
        return Self.bool(from: value)
    }

    public func setOverrideValue(_ value: Bool?, for flag: FeatureFlag) {
        if let value {
            defaults.set(value, forKey: flag.defaultsKey)
        } else {
            defaults.removeObject(forKey: flag.defaultsKey)
        }
    }

    /// The overrides in `dictionary`, keyed like `UserDefaults`. Pass
    /// `UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)`
    /// to read the `-blau.featureFlag.<name> YES` launch arguments, for
    /// example to seed an `InMemoryFeatureFlagStorage` in a UI-test launch.
    public static func overrides(in dictionary: [String: Any]) -> [FeatureFlag: Bool] {
        var overrides: [FeatureFlag: Bool] = [:]
        for flag in FeatureFlag.allCases {
            if let raw = dictionary[flag.defaultsKey], let value = bool(from: raw) {
                overrides[flag] = value
            }
        }
        return overrides
    }

    /// Interprets a stored value the way `UserDefaults.bool(forKey:)` does
    /// (`YES`, `true`, `1`...), but returns `nil` for anything that isn't
    /// clearly a boolean, so a malformed value falls back to the default
    /// rather than silently turning a flag off.
    static func bool(from value: Any) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1", "on": return true
            case "no", "false", "0", "off": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - In memory

/// Keeps overrides in memory. For tests, previews and UI-test launches.
public final class InMemoryFeatureFlagStorage: FeatureFlagStorage {
    private let overrides: Mutex<[FeatureFlag: Bool]>

    public init(overrides: [FeatureFlag: Bool] = [:]) {
        self.overrides = Mutex(overrides)
    }

    public func overrideValue(for flag: FeatureFlag) -> Bool? {
        overrides.withLock { $0[flag] }
    }

    public func setOverrideValue(_ value: Bool?, for flag: FeatureFlag) {
        overrides.withLock { $0[flag] = value }
    }
}
