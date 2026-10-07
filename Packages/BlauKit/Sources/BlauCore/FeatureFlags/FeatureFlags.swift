import Observation

/// The current value of every `FeatureFlag`.
///
/// A flag's value is its override when overrides are allowed and one is set,
/// otherwise its compiled-in `defaultValue`. Overrides live in a
/// `FeatureFlagStorage` (`UserDefaults` in the app) and are only honoured
/// when `allowsOverrides` is `true`, which the composition root sets for
/// DEBUG builds. A release build therefore always runs with the shipping
/// defaults, whatever is stored on the device.
///
/// `FeatureFlags` is `Observable`, so SwiftUI views that read a flag update
/// when it is toggled, and `Sendable`, so pipeline code on any actor can read
/// it synchronously:
///
/// ```swift
/// if flags.isEnabled(.secondPassASR) { ... }
/// ```
public final class FeatureFlags: Observable, Sendable {
    /// Whether overrides are honoured and can be changed.
    public let allowsOverrides: Bool

    private let storage: any FeatureFlagStorage
    private let registrar = ObservationRegistrar()

    /// - Parameters:
    ///   - storage: Where overrides are kept.
    ///   - allowsOverrides: Pass `true` for DEBUG builds. When `false`, every
    ///     flag reads its `defaultValue` and `setOverride(_:for:)` does
    ///     nothing.
    public init(storage: any FeatureFlagStorage, allowsOverrides: Bool) {
        self.storage = storage
        self.allowsOverrides = allowsOverrides
    }

    /// Flags backed by an `InMemoryFeatureFlagStorage`, with overrides
    /// allowed. For tests and previews.
    public static func inMemory(_ overrides: [FeatureFlag: Bool] = [:]) -> FeatureFlags {
        FeatureFlags(storage: InMemoryFeatureFlagStorage(overrides: overrides), allowsOverrides: true)
    }

    // MARK: Reading

    /// The value of `flag` right now.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        registrar.access(self, keyPath: \.[flag])
        return resolvedValue(flag)
    }

    /// The value of `flag`; the same as `isEnabled(_:)`.
    public subscript(flag: FeatureFlag) -> Bool {
        isEnabled(flag)
    }

    /// The honoured override for `flag`, or `nil` when the flag is at its
    /// default (or overrides aren't allowed).
    public func override(for flag: FeatureFlag) -> Bool? {
        registrar.access(self, keyPath: \.[flag])
        return allowsOverrides ? storage.overrideValue(for: flag) : nil
    }

    /// Whether `flag` has an honoured override (which may equal its default).
    public func isOverridden(_ flag: FeatureFlag) -> Bool {
        override(for: flag) != nil
    }

    /// The flags with an honoured override, in declaration order.
    public var overriddenFlags: [FeatureFlag] {
        FeatureFlag.allCases.filter(isOverridden)
    }

    /// Every flag's current value.
    public var snapshot: [FeatureFlag: Bool] {
        Dictionary(uniqueKeysWithValues: FeatureFlag.allCases.map { ($0, isEnabled($0)) })
    }

    // MARK: Overriding

    /// Overrides `flag` with `value`; `nil` removes the override so the flag
    /// reads its default again.
    ///
    /// - Returns: `false`, without storing anything, when overrides aren't
    ///   allowed.
    @discardableResult
    public func setOverride(_ value: Bool?, for flag: FeatureFlag) -> Bool {
        guard allowsOverrides else { return false }
        registrar.withMutation(of: self, keyPath: \.[flag]) {
            storage.setOverrideValue(value, for: flag)
        }
        return true
    }

    /// Removes every stored override. Launch-argument overrides stay in
    /// effect for the rest of the run (see `UserDefaultsFeatureFlagStorage`).
    public func resetOverrides() {
        for flag in FeatureFlag.allCases {
            setOverride(nil, for: flag)
        }
    }

    private func resolvedValue(_ flag: FeatureFlag) -> Bool {
        guard allowsOverrides, let value = storage.overrideValue(for: flag) else {
            return flag.defaultValue
        }
        return value
    }
}

extension FeatureFlags: CustomStringConvertible {
    public var description: String {
        let values = FeatureFlag.allCases.map { flag in
            "\(flag.rawValue): \(isEnabled(flag))\(isOverridden(flag) ? " (override)" : "")"
        }
        return "FeatureFlags(\(values.joined(separator: ", ")))"
    }
}
