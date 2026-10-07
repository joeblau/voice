import Foundation

/// Values that override build-time configuration at run time, without an
/// app update and without a Blau backend.
///
/// Used for the pinned realtime model (`AppConfig.xaiRealtimeModel`): if xAI
/// retires or replaces the pinned version, it can be switched remotely
/// instead of waiting for a release.
public protocol ConfigurationOverrideSource: Sendable {
    /// The override for `key`, trimmed, or `nil` when there is none.
    func overrideValue(forKey key: String) -> String?
}

/// Overrides from `UserDefaults`, checked in this order:
///
/// 1. **Managed app configuration** (`com.apple.configuration.managed`), the
///    dictionary an MDM server pushes to a managed app. This is the remote
///    override: it changes the value on enrolled devices without a build.
/// 2. **The key itself** in the app's defaults, which also covers launch
///    arguments (`-BlauXAIRealtimeModel grok-voice-latest` in a scheme or
///    `xcrun devicectl … --arguments`), since those land in the argument
///    domain. Handy for trying a new model on a development device.
///
/// Blank values and unexpanded build settings (`$(…)`) count as no override.
public struct UserDefaultsConfigurationOverrides: ConfigurationOverrideSource {
    /// Where MDM-managed app configuration lives in `UserDefaults`.
    public static let managedConfigurationKey = "com.apple.configuration.managed"

    /// `nil` for `UserDefaults.standard`.
    public let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public func overrideValue(forKey key: String) -> String? {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let managed = defaults.dictionary(forKey: Self.managedConfigurationKey)?[key] as? String
        return Self.cleaned(managed) ?? Self.cleaned(defaults.string(forKey: key))
    }

    static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            !value.contains("$(")
        else { return nil }
        return value
    }
}

/// Fixed overrides, for tests and previews.
public struct StaticConfigurationOverrides: ConfigurationOverrideSource {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func overrideValue(forKey key: String) -> String? {
        UserDefaultsConfigurationOverrides.cleaned(values[key])
    }
}
