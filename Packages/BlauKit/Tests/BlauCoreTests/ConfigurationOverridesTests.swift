import Foundation
import Testing

@testable import BlauCore

@Suite("Configuration overrides")
struct ConfigurationOverridesTests {
    private let key = "BlauXAIRealtimeModel"

    private func withSuite(_ body: (UserDefaults, UserDefaultsConfigurationOverrides) throws -> Void) throws {
        let suite = "blau.tests.overrides.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        try body(defaults, UserDefaultsConfigurationOverrides(suiteName: suite))
    }

    @Test func noOverrideByDefault() throws {
        try withSuite { _, overrides in
            #expect(overrides.overrideValue(forKey: key) == nil)
        }
    }

    @Test func readsAPlainDefaultsValue() throws {
        try withSuite { defaults, overrides in
            defaults.set("  grok-voice-latest\n", forKey: key)
            #expect(overrides.overrideValue(forKey: key) == "grok-voice-latest")
        }
    }

    @Test func managedAppConfigurationWins() throws {
        try withSuite { defaults, overrides in
            defaults.set("grok-voice-latest", forKey: key)
            defaults.set(
                [key: "grok-voice-think-fast-3.0", "Other": "x"],
                forKey: UserDefaultsConfigurationOverrides.managedConfigurationKey)
            #expect(overrides.overrideValue(forKey: key) == "grok-voice-think-fast-3.0")
        }
    }

    @Test func blankOrUnexpandedValuesAreNoOverride() throws {
        try withSuite { defaults, overrides in
            defaults.set(
                [key: "   "], forKey: UserDefaultsConfigurationOverrides.managedConfigurationKey)
            defaults.set("$(XAI_REALTIME_MODEL)", forKey: key)
            #expect(overrides.overrideValue(forKey: key) == nil)
        }
    }

    @Test func nonStringManagedValueFallsThrough() throws {
        try withSuite { defaults, overrides in
            defaults.set([key: 42], forKey: UserDefaultsConfigurationOverrides.managedConfigurationKey)
            defaults.set("grok-voice-latest", forKey: key)
            #expect(overrides.overrideValue(forKey: key) == "grok-voice-latest")
        }
    }

    @Test func staticOverrides() {
        let overrides = StaticConfigurationOverrides([key: " grok-voice-latest ", "Empty": ""])
        #expect(overrides.overrideValue(forKey: key) == "grok-voice-latest")
        #expect(overrides.overrideValue(forKey: "Empty") == nil)
        #expect(overrides.overrideValue(forKey: "Missing") == nil)
    }
}
