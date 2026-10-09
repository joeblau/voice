import BlauCore
import Foundation
import Testing

@testable import Blau

/// Guards the wiring Config/*.xcconfig -> project.yml Info.plist keys ->
/// AppConfig in the built app. The unit-test bundle is hosted in the app, so
/// `Bundle.main` is the built Blau.app (Debug configuration).
@Suite("AppConfig in the built app")
struct AppConfigBundleTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func bundleConfigurationParsesStrictly() throws {
        let config = try AppConfig(infoDictionary: info)
        #expect(config.environment == .debug)
        #expect(config == AppConfig.load(from: .main))
        #expect(config == AppConfig.current)
    }

    @Test func baseXcconfigDefaultsMatchFallback() throws {
        // A Secrets.xcconfig may override these locally; CI and fresh clones don't.
        let config = try AppConfig(infoDictionary: info, honorsDevelopmentKey: false)
        #expect(config.xaiAPIHost == AppConfig.fallback.xaiAPIHost)
        #expect(config.xaiRealtimeModel == AppConfig.fallback.xaiRealtimeModel)
    }

    @Test func everyConfigKeyIsExpanded() {
        for key in [
            AppConfig.InfoKey.environment,
            AppConfig.InfoKey.xaiAPIHost,
            AppConfig.InfoKey.xaiRealtimeModel,
            AppConfig.InfoKey.xaiDevAPIKey,
        ] {
            let value = info[key] as? String
            #expect(value != nil, "Info.plist is missing \(key)")
            #expect(value?.contains("$(") == false, "\(key) was not expanded: \(value ?? "")")
        }
    }
}

/// The app-side half of `AppConfig` (`Blau/Configuration/AppConfig+App.swift`):
/// the app's own `#if DEBUG` decides whether the development key is honoured,
/// and the logging loaders fall back to the Base defaults. The parsing itself
/// is tested in BlauKit (`BlauCoreTests/AppConfigParsingTests`).
@Suite("AppConfig app integration")
struct AppConfigAppTests {
    /// Assembled at runtime so the repository never contains a key-shaped literal.
    private static let fakeKey = "xai-" + String(repeating: "Fake0Key", count: 6)

    private static func info(host: String = "api.x.ai") -> [String: Any] {
        [
            AppConfig.InfoKey.environment: "debug",
            AppConfig.InfoKey.xaiAPIHost: host,
            AppConfig.InfoKey.xaiRealtimeModel: "grok-voice-think-fast-2.0",
            AppConfig.InfoKey.xaiDevAPIKey: fakeKey,
        ]
    }

    @Test func honoursDevelopmentKeyOnlyInDebugBuildsByDefault() throws {
        let config = try AppConfig(infoDictionary: Self.info())
        #expect((config.developmentAPIKey != nil) == AppConfig.isDebugBuild)
        #expect((AppConfig.load(infoDictionary: Self.info()).developmentAPIKey != nil) == AppConfig.isDebugBuild)
    }

    @Test func loadFallsBackToDefaultsWhenInfoPlistIsUnusable() {
        #expect(AppConfig.load(infoDictionary: [:]) == AppConfig.fallback)
        #expect(AppConfig.load(infoDictionary: Self.info(host: "https://bad")) == AppConfig.fallback)
    }

    @Test func fallbackIsTheBaseDefaultsForThisBuild() {
        #expect(AppConfig.fallback.developmentAPIKey == nil)
        #expect(AppConfig.fallback.environment == (AppConfig.isDebugBuild ? .debug : .release))
        #expect(AppConfig.fallback == AppConfig.defaults(environment: AppConfig.fallback.environment))
    }
}
