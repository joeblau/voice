import BlauCore
import Foundation
import Testing

@testable import Blau

/// The pinned realtime model and its run-time override (#35).
@Suite("AppConfig realtime model override")
struct AppConfigModelOverrideTests {
    private static let pinned = AppConfig(
        environment: .debug, xaiAPIHost: "api.x.ai", xaiRealtimeModel: "grok-voice-think-fast-2.0",
        developmentAPIKey: nil)

    private func overriding(_ model: String?) -> AppConfig {
        let values = model.map { [AppConfig.InfoKey.xaiRealtimeModel: $0] } ?? [:]
        return Self.pinned.applyingOverrides(StaticConfigurationOverrides(values))
    }

    @Test func usesThePinWithoutAnOverride() {
        let config = overriding(nil)
        #expect(config == Self.pinned)
        #expect(config.xaiRealtimeModelOverride == nil)
        #expect(config.effectiveRealtimeModel == "grok-voice-think-fast-2.0")
        #expect(config.xaiRealtimeURL.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")
    }

    @Test func anOverrideReplacesTheModelOnTheRealtimeURL() {
        let config = overriding("grok-voice-latest")
        #expect(config.xaiRealtimeModel == "grok-voice-think-fast-2.0")
        #expect(config.xaiRealtimeModelOverride == "grok-voice-latest")
        #expect(config.effectiveRealtimeModel == "grok-voice-latest")
        #expect(config.xaiRealtimeURL.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-latest")
        #expect(config.description.contains("xaiRealtimeModelOverride: grok-voice-latest"))
    }

    @Test func overridingWithThePinIsNoOverride() {
        #expect(overriding("grok-voice-think-fast-2.0") == Self.pinned)
    }

    @Test(arguments: ["grok voice", "models/grok", "grok?x=1", "grok&model=evil", "grök"])
    func invalidOverridesAreIgnored(model: String) {
        let config = overriding(model)
        #expect(config == Self.pinned)
        #expect(config.xaiRealtimeURL.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")
    }

    @Test func readsTheManagedAppConfigurationOverride() throws {
        let suite = "blau.tests.appconfig.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(
            [AppConfig.InfoKey.xaiRealtimeModel: "grok-voice-latest"],
            forKey: UserDefaultsConfigurationOverrides.managedConfigurationKey)

        let config = Self.pinned.applyingOverrides(UserDefaultsConfigurationOverrides(suiteName: suite))
        #expect(config.effectiveRealtimeModel == "grok-voice-latest")
    }
}
