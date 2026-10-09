import Foundation

/// Typed view of the build-time configuration in `Config/*.xcconfig`.
///
/// The xcconfig values reach the app as Info.plist keys (`info.properties` in
/// `project.yml`) and are parsed here once, so the rest of the app never reads
/// raw Info.plist strings. See `docs/configuration.md`.
///
/// This is the pure part: parsing, validation, derived URLs, run-time
/// overrides and redaction. It never checks `#if DEBUG` (a package's
/// compilation conditions are not the app's) and never logs (BlauCore is
/// layer 0). The app decides whether the development key is honoured and
/// adds the logging loaders (`AppConfig.current`, `load(from:)`) in
/// `Blau/Configuration/AppConfig+App.swift`.
public struct AppConfig: Sendable, Equatable {
    /// Build flavour, from `BLAU_ENVIRONMENT`.
    public enum Environment: String, Sendable, CaseIterable {
        case debug
        case release
    }

    /// Info.plist keys written by `project.yml`.
    public enum InfoKey {
        public static let environment = "BlauEnvironment"
        public static let xaiAPIHost = "BlauXAIAPIHost"
        public static let xaiRealtimeModel = "BlauXAIRealtimeModel"
        public static let xaiDevAPIKey = "BlauXAIDevAPIKey"
    }

    /// Why an Info.plist could not be turned into an `AppConfig`.
    public enum LoadError: Error, Equatable, Sendable {
        /// The key is absent, empty, or still an unexpanded `$(SETTING)`.
        case missingValue(key: String)
        /// The key is present but its value is not acceptable.
        case invalidValue(key: String, value: String)
    }

    /// `XAI_API_HOST` in `Config/Base.xcconfig`; a test keeps the two in sync.
    public static let baseXAIAPIHost = "api.x.ai"

    /// `XAI_REALTIME_MODEL` in `Config/Base.xcconfig`; a test keeps the two
    /// in sync.
    public static let baseXAIRealtimeModel = "grok-voice-think-fast-2.0"

    /// The `Config/Base.xcconfig` defaults for `environment`, with no
    /// development key. The app falls back to these when its bundle's
    /// configuration is unusable.
    public static func defaults(environment: Environment) -> AppConfig {
        AppConfig(
            environment: environment,
            xaiAPIHost: baseXAIAPIHost,
            xaiRealtimeModel: baseXAIRealtimeModel,
            developmentAPIKey: nil
        )
    }

    public let environment: Environment

    /// Host of the xAI API, e.g. `api.x.ai`.
    public let xaiAPIHost: String

    /// Pinned Grok realtime voice model, e.g. `grok-voice-think-fast-2.0`.
    public let xaiRealtimeModel: String

    /// A run-time replacement for the pinned model (managed app
    /// configuration or a launch argument, see
    /// ``applyingOverrides(_:reportingInvalid:)``). `nil` uses the pin.
    public let xaiRealtimeModelOverride: String?

    /// Developer API key from `Config/Secrets.xcconfig`, used only to pre-fill
    /// the Keychain on first launch (issue #33). Always `nil` in non-DEBUG
    /// builds and when no key is configured; callers must then fall back to
    /// the key the user enters. Never log it.
    public let developmentAPIKey: String?

    public init(
        environment: Environment,
        xaiAPIHost: String,
        xaiRealtimeModel: String,
        xaiRealtimeModelOverride: String? = nil,
        developmentAPIKey: String?
    ) {
        self.environment = environment
        self.xaiAPIHost = xaiAPIHost
        self.xaiRealtimeModel = xaiRealtimeModel
        self.xaiRealtimeModelOverride = xaiRealtimeModelOverride
        self.developmentAPIKey = developmentAPIKey
    }

    /// Parses an Info.plist dictionary.
    ///
    /// - Parameters:
    ///   - infoDictionary: Typically `Bundle.main.infoDictionary`.
    ///   - honorsDevelopmentKey: Whether `BlauXAIDevAPIKey` may be used. There
    ///     is no default: the app passes its own `#if DEBUG`
    ///     (`AppConfig.isDebugBuild`), so a release app never honours the key
    ///     however this package was compiled.
    /// - Throws: ``LoadError`` when a required value is missing or invalid. A
    ///   missing development key is not an error.
    public init(
        infoDictionary: [String: Any],
        honorsDevelopmentKey: Bool
    ) throws(LoadError) {
        let environmentValue = try Self.requiredString(InfoKey.environment, in: infoDictionary)
        guard let environment = Environment(rawValue: environmentValue.lowercased()) else {
            throw .invalidValue(key: InfoKey.environment, value: environmentValue)
        }

        let host = try Self.requiredString(InfoKey.xaiAPIHost, in: infoDictionary)
        guard Self.isValidHost(host) else {
            throw .invalidValue(key: InfoKey.xaiAPIHost, value: host)
        }

        let model = try Self.requiredString(InfoKey.xaiRealtimeModel, in: infoDictionary)
        guard Self.isValidModel(model) else {
            throw .invalidValue(key: InfoKey.xaiRealtimeModel, value: model)
        }

        self.init(
            environment: environment,
            xaiAPIHost: host,
            xaiRealtimeModel: model,
            developmentAPIKey: honorsDevelopmentKey
                ? Self.optionalString(InfoKey.xaiDevAPIKey, in: infoDictionary)
                : nil
        )
    }

    /// Base URL for xAI REST calls: `https://<host>`.
    public var xaiAPIBaseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = xaiAPIHost
        // Host validity is checked on load, so this cannot fail.
        return components.url!
    }

    /// The realtime model sessions use: the override if there is one,
    /// otherwise the pin.
    public var effectiveRealtimeModel: String { xaiRealtimeModelOverride ?? xaiRealtimeModel }

    /// Realtime WebSocket endpoint with the effective model:
    /// `wss://<host>/v1/realtime?model=<model>`.
    public var xaiRealtimeURL: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = xaiAPIHost
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: effectiveRealtimeModel)]
        return components.url!
    }

    /// Whether a developer key is available to seed the Keychain.
    public var hasDevelopmentAPIKey: Bool { developmentAPIKey != nil }
}

// MARK: - Run-time overrides

extension AppConfig {
    /// Applies the overrides in `source`. Today that is the realtime model,
    /// under the same key as its Info.plist entry (`BlauXAIRealtimeModel`),
    /// so xAI can be switched to a newer model on managed devices (managed
    /// app configuration) or a development device (a launch argument)
    /// without a build.
    ///
    /// - Parameter reportInvalid: Called with an override that is not a
    ///   valid model id. The override is ignored; the app logs it.
    public func applyingOverrides(
        _ source: any ConfigurationOverrideSource,
        reportingInvalid reportInvalid: (_ override: String) -> Void
    ) -> AppConfig {
        var model: String?
        if let override = source.overrideValue(forKey: InfoKey.xaiRealtimeModel) {
            if Self.isValidModel(override) {
                model = override == xaiRealtimeModel ? nil : override
            } else {
                reportInvalid(override)
            }
        }
        guard model != xaiRealtimeModelOverride else { return self }
        return AppConfig(
            environment: environment,
            xaiAPIHost: xaiAPIHost,
            xaiRealtimeModel: xaiRealtimeModel,
            xaiRealtimeModelOverride: model,
            developmentAPIKey: developmentAPIKey
        )
    }
}

// MARK: - Parsing helpers

extension AppConfig {
    /// Trimmed string value, or `nil` when absent, empty, or an unexpanded
    /// build setting reference such as `$(XAI_DEV_API_KEY)`.
    static func optionalString(_ key: String, in info: [String: Any]) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func requiredString(_ key: String, in info: [String: Any]) throws(LoadError) -> String {
        guard let value = optionalString(key, in: info) else {
            throw .missingValue(key: key)
        }
        return value
    }

    /// A model id that is safe in the `model` query item: 1–128 ASCII
    /// letters, digits, `.`, `_` and `-` (e.g. `grok-voice-think-fast-2.0`).
    static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && model.count <= 128
            && model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// A bare host name: letters, digits, dots and hyphens, no scheme, path,
    /// port or empty labels.
    static func isValidHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, host.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty
                && label.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

// MARK: - Redacted descriptions

/// Descriptions never include the development key, so logging or dumping an
/// `AppConfig` cannot leak it.
extension AppConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AppConfig(environment: \(environment.rawValue), xaiAPIHost: \(xaiAPIHost), "
            + "xaiRealtimeModel: \(xaiRealtimeModel), "
            + "xaiRealtimeModelOverride: \(xaiRealtimeModelOverride ?? "nil"), "
            + "developmentAPIKey: \(hasDevelopmentAPIKey ? "<redacted>" : "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "environment": environment,
                "xaiAPIHost": xaiAPIHost,
                "xaiRealtimeModel": xaiRealtimeModel,
                "xaiRealtimeModelOverride": xaiRealtimeModelOverride ?? "nil",
                "developmentAPIKey": hasDevelopmentAPIKey ? "<redacted>" : "nil",
            ],
            displayStyle: .struct
        )
    }
}
