import Foundation
import Testing

@testable import Blau

@Suite("AppConfig parsing")
struct AppConfigParsingTests {
    /// Assembled at runtime so the repository never contains a key-shaped literal.
    private static let fakeKey = "xai-" + String(repeating: "Fake0Key", count: 6)

    private static func info(
        environment: Any? = "debug",
        host: Any? = "api.x.ai",
        model: Any? = "grok-voice-think-fast-2.0",
        devKey: Any? = ""
    ) -> [String: Any] {
        var info: [String: Any] = ["CFBundleIdentifier": "com.joeblau.blau"]
        info[AppConfig.InfoKey.environment] = environment
        info[AppConfig.InfoKey.xaiAPIHost] = host
        info[AppConfig.InfoKey.xaiRealtimeModel] = model
        info[AppConfig.InfoKey.xaiDevAPIKey] = devKey
        return info
    }

    @Test func parsesCompleteDictionary() throws {
        let config = try AppConfig(
            infoDictionary: Self.info(devKey: Self.fakeKey),
            honorsDevelopmentKey: true
        )
        #expect(config.environment == .debug)
        #expect(config.xaiAPIHost == "api.x.ai")
        #expect(config.xaiRealtimeModel == "grok-voice-think-fast-2.0")
        #expect(config.developmentAPIKey == Self.fakeKey)
        #expect(config.hasDevelopmentAPIKey)
    }

    @Test(arguments: [("release", AppConfig.Environment.release), ("Debug", .debug), (" release\n", .release)])
    func parsesEnvironmentCaseAndWhitespaceInsensitively(raw: String, expected: AppConfig.Environment) throws {
        let config = try AppConfig(infoDictionary: Self.info(environment: raw))
        #expect(config.environment == expected)
    }

    @Test func trimsWhitespaceAroundValues() throws {
        let config = try AppConfig(
            infoDictionary: Self.info(
                host: "  api.x.ai ", model: "\tgrok-voice-think-fast-2.0\n", devKey: " \(Self.fakeKey) "),
            honorsDevelopmentKey: true
        )
        #expect(config.xaiAPIHost == "api.x.ai")
        #expect(config.xaiRealtimeModel == "grok-voice-think-fast-2.0")
        #expect(config.developmentAPIKey == Self.fakeKey)
    }

    // MARK: Fresh clone / no secrets

    @Test(arguments: [nil, "", "   ", "$(BLAU_INFO_XAI_DEV_API_KEY)"] as [String?])
    func missingDevelopmentKeyDegradesToNil(devKey: String?) throws {
        let config = try AppConfig(infoDictionary: Self.info(devKey: devKey), honorsDevelopmentKey: true)
        #expect(config.developmentAPIKey == nil)
        #expect(!config.hasDevelopmentAPIKey)
    }

    @Test func nonStringDevelopmentKeyDegradesToNil() throws {
        let config = try AppConfig(infoDictionary: Self.info(devKey: 42), honorsDevelopmentKey: true)
        #expect(config.developmentAPIKey == nil)
    }

    // MARK: Release builds never honour the developer key

    @Test func releaseBuildIgnoresDevelopmentKey() throws {
        let config = try AppConfig(
            infoDictionary: Self.info(environment: "release", devKey: Self.fakeKey),
            honorsDevelopmentKey: false
        )
        #expect(config.developmentAPIKey == nil)
    }

    @Test func honoursDevelopmentKeyOnlyInDebugBuildsByDefault() throws {
        let config = try AppConfig(infoDictionary: Self.info(devKey: Self.fakeKey))
        #expect((config.developmentAPIKey != nil) == AppConfig.isDebugBuild)
    }

    // MARK: Required values

    @Test(arguments: [
        AppConfig.InfoKey.environment,
        AppConfig.InfoKey.xaiAPIHost,
        AppConfig.InfoKey.xaiRealtimeModel,
    ])
    func missingRequiredValueThrows(key: String) {
        var mutableInfo = Self.info()
        mutableInfo[key] = nil
        let info = mutableInfo
        #expect(throws: AppConfig.LoadError.missingValue(key: key)) {
            try AppConfig(infoDictionary: info)
        }
    }

    @Test(arguments: [
        AppConfig.InfoKey.environment,
        AppConfig.InfoKey.xaiAPIHost,
        AppConfig.InfoKey.xaiRealtimeModel,
    ])
    func unexpandedBuildSettingThrows(key: String) {
        var mutableInfo = Self.info()
        mutableInfo[key] = "$(UNDEFINED_SETTING)"
        let info = mutableInfo
        #expect(throws: AppConfig.LoadError.missingValue(key: key)) {
            try AppConfig(infoDictionary: info)
        }
    }

    @Test func unknownEnvironmentThrows() {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.environment, value: "staging")) {
            try AppConfig(infoDictionary: Self.info(environment: "staging"))
        }
    }

    @Test(arguments: [
        "https://api.x.ai", "api.x.ai/v1", "api.x.ai:443", "api..x.ai", ".api.x.ai",
        "-api.x.ai", "api x.ai", "äpi.x.ai",
    ])
    func invalidHostThrows(host: String) {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.xaiAPIHost, value: host)) {
            try AppConfig(infoDictionary: Self.info(host: host))
        }
    }

    @Test(arguments: ["api.x.ai", "localhost", "staging-api.x.ai", "127.0.0.1"])
    func validHostsAreAccepted(host: String) throws {
        let config = try AppConfig(infoDictionary: Self.info(host: host))
        #expect(config.xaiAPIHost == host)
    }

    @Test(arguments: ["grok voice", "models/grok"])
    func invalidModelThrows(model: String) {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.xaiRealtimeModel, value: model)) {
            try AppConfig(infoDictionary: Self.info(model: model))
        }
    }

    // MARK: Graceful fallback

    @Test func loadFallsBackToDefaultsWhenInfoPlistIsUnusable() {
        #expect(AppConfig.load(infoDictionary: [:]) == AppConfig.fallback)
        #expect(AppConfig.load(infoDictionary: Self.info(host: "https://bad")) == AppConfig.fallback)
    }

    @Test func fallbackHasNoDevelopmentKey() {
        #expect(AppConfig.fallback.developmentAPIKey == nil)
        #expect(AppConfig.fallback.environment == (AppConfig.isDebugBuild ? .debug : .release))
    }

    // MARK: Derived URLs

    @Test func derivesAPIAndRealtimeURLs() throws {
        let config = try AppConfig(infoDictionary: Self.info())
        #expect(config.xaiAPIBaseURL.absoluteString == "https://api.x.ai")
        #expect(config.xaiRealtimeURL.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")
    }

    // MARK: Redaction

    @Test func descriptionsNeverContainTheDevelopmentKey() throws {
        let config = try AppConfig(
            infoDictionary: Self.info(devKey: Self.fakeKey),
            honorsDevelopmentKey: true
        )
        var dumped = ""
        dump(config, to: &dumped)
        for text in [
            config.description, config.debugDescription, String(describing: config), String(reflecting: config), dumped,
        ] {
            #expect(!text.contains(Self.fakeKey))
            #expect(text.contains("<redacted>"))
        }
    }
}

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
