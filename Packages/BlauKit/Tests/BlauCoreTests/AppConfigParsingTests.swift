import Foundation
import Testing

@testable import BlauCore

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
        let config = try AppConfig(infoDictionary: Self.info(environment: raw), honorsDevelopmentKey: true)
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

    @Test func releaseBuildStillParsesTheOtherValues() throws {
        let config = try AppConfig(
            infoDictionary: Self.info(environment: "release", devKey: Self.fakeKey),
            honorsDevelopmentKey: false
        )
        #expect(config.environment == .release)
        #expect(config.xaiAPIHost == "api.x.ai")
        #expect(!config.hasDevelopmentAPIKey)
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
            try AppConfig(infoDictionary: info, honorsDevelopmentKey: true)
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
            try AppConfig(infoDictionary: info, honorsDevelopmentKey: true)
        }
    }

    @Test func unknownEnvironmentThrows() {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.environment, value: "staging")) {
            try AppConfig(infoDictionary: Self.info(environment: "staging"), honorsDevelopmentKey: true)
        }
    }

    @Test(arguments: [
        "https://api.x.ai", "api.x.ai/v1", "api.x.ai:443", "api..x.ai", ".api.x.ai",
        "-api.x.ai", "api x.ai", "äpi.x.ai",
    ])
    func invalidHostThrows(host: String) {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.xaiAPIHost, value: host)) {
            try AppConfig(infoDictionary: Self.info(host: host), honorsDevelopmentKey: true)
        }
    }

    @Test(arguments: ["api.x.ai", "localhost", "staging-api.x.ai", "127.0.0.1"])
    func validHostsAreAccepted(host: String) throws {
        let config = try AppConfig(infoDictionary: Self.info(host: host), honorsDevelopmentKey: true)
        #expect(config.xaiAPIHost == host)
    }

    @Test(arguments: ["grok voice", "models/grok"])
    func invalidModelThrows(model: String) {
        #expect(throws: AppConfig.LoadError.invalidValue(key: AppConfig.InfoKey.xaiRealtimeModel, value: model)) {
            try AppConfig(infoDictionary: Self.info(model: model), honorsDevelopmentKey: true)
        }
    }

    // MARK: Base defaults

    @Test(arguments: AppConfig.Environment.allCases)
    func defaultsAreTheBaseXcconfigValuesWithNoKey(environment: AppConfig.Environment) throws {
        let defaults = AppConfig.defaults(environment: environment)
        #expect(defaults.environment == environment)
        #expect(defaults.xaiAPIHost == "api.x.ai")
        #expect(defaults.xaiRealtimeModel == "grok-voice-think-fast-2.0")
        #expect(defaults.xaiRealtimeModelOverride == nil)
        #expect(defaults.developmentAPIKey == nil)
        // The defaults parse back to themselves, so they are valid values.
        let parsed = try AppConfig(
            infoDictionary: Self.info(environment: environment.rawValue, devKey: nil),
            honorsDevelopmentKey: true
        )
        #expect(parsed == defaults)
    }

    // MARK: Derived URLs

    @Test func derivesAPIAndRealtimeURLs() throws {
        let config = try AppConfig(infoDictionary: Self.info(), honorsDevelopmentKey: false)
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

    // MARK: Run-time overrides

    @Test func applyingOverridesReportsAndIgnoresAnInvalidOverride() throws {
        let config = try AppConfig(infoDictionary: Self.info(), honorsDevelopmentKey: false)
        var reported: [String] = []
        let overridden = config.applyingOverrides(
            StaticConfigurationOverrides([AppConfig.InfoKey.xaiRealtimeModel: "grok&model=evil"])
        ) { reported.append($0) }
        #expect(overridden == config)
        #expect(reported == ["grok&model=evil"])
    }

    @Test func applyingOverridesReplacesTheModelWithoutReporting() throws {
        let config = try AppConfig(infoDictionary: Self.info(), honorsDevelopmentKey: false)
        var reported: [String] = []
        let overridden = config.applyingOverrides(
            StaticConfigurationOverrides([AppConfig.InfoKey.xaiRealtimeModel: "grok-voice-latest"])
        ) { reported.append($0) }
        #expect(overridden.effectiveRealtimeModel == "grok-voice-latest")
        #expect(overridden.xaiRealtimeURL.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-latest")
        #expect(reported.isEmpty)
    }
}
