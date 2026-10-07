import Foundation
import os

/// Typed view of the build-time configuration in `Config/*.xcconfig`.
///
/// The xcconfig values reach the app as Info.plist keys (`info.properties` in
/// `project.yml`) and are parsed here once, so the rest of the app never reads
/// raw Info.plist strings. See `docs/configuration.md`.
///
/// Pure Foundation with no app dependencies, so it can move into `BlauCore`
/// unchanged once the `BlauKit` package exists.
struct AppConfig: Sendable, Equatable {
    /// Build flavour, from `BLAU_ENVIRONMENT`.
    enum Environment: String, Sendable, CaseIterable {
        case debug
        case release
    }

    /// Info.plist keys written by `project.yml`.
    enum InfoKey {
        static let environment = "BlauEnvironment"
        static let xaiAPIHost = "BlauXAIAPIHost"
        static let xaiRealtimeModel = "BlauXAIRealtimeModel"
        static let xaiDevAPIKey = "BlauXAIDevAPIKey"
    }

    /// Why an Info.plist could not be turned into an `AppConfig`.
    enum LoadError: Error, Equatable, Sendable {
        /// The key is absent, empty, or still an unexpanded `$(SETTING)`.
        case missingValue(key: String)
        /// The key is present but its value is not acceptable.
        case invalidValue(key: String, value: String)
    }

    /// Whether this binary was compiled with `DEBUG`. Only DEBUG builds honour
    /// `XAI_DEV_API_KEY`.
    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// Values used when the bundle's configuration is unusable. They match
    /// `Config/Base.xcconfig`; a test keeps the two in sync.
    static let fallback = AppConfig(
        environment: isDebugBuild ? .debug : .release,
        xaiAPIHost: "api.x.ai",
        xaiRealtimeModel: "grok-voice-think-fast-2.0",
        developmentAPIKey: nil
    )

    let environment: Environment

    /// Host of the xAI API, e.g. `api.x.ai`.
    let xaiAPIHost: String

    /// Pinned Grok realtime voice model, e.g. `grok-voice-think-fast-2.0`.
    let xaiRealtimeModel: String

    /// Developer API key from `Config/Secrets.xcconfig`, used only to pre-fill
    /// the Keychain on first launch (issue #33). Always `nil` in non-DEBUG
    /// builds and when no key is configured; callers must then fall back to
    /// the key the user enters. Never log it.
    let developmentAPIKey: String?

    init(
        environment: Environment,
        xaiAPIHost: String,
        xaiRealtimeModel: String,
        developmentAPIKey: String?
    ) {
        self.environment = environment
        self.xaiAPIHost = xaiAPIHost
        self.xaiRealtimeModel = xaiRealtimeModel
        self.developmentAPIKey = developmentAPIKey
    }

    /// Parses an Info.plist dictionary.
    ///
    /// - Parameters:
    ///   - infoDictionary: Typically `Bundle.main.infoDictionary`.
    ///   - honorsDevelopmentKey: Whether `BlauXAIDevAPIKey` may be used. Pass
    ///     `false` to model a release build; defaults to ``isDebugBuild``.
    /// - Throws: ``LoadError`` when a required value is missing or invalid. A
    ///   missing development key is not an error.
    init(
        infoDictionary: [String: Any],
        honorsDevelopmentKey: Bool = AppConfig.isDebugBuild
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
        guard !model.contains(where: { $0.isWhitespace || $0 == "/" }) else {
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
    var xaiAPIBaseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = xaiAPIHost
        // Host validity is checked on load, so this cannot fail.
        return components.url!
    }

    /// Realtime WebSocket endpoint with the pinned model:
    /// `wss://<host>/v1/realtime?model=<model>`.
    var xaiRealtimeURL: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = xaiAPIHost
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: xaiRealtimeModel)]
        return components.url!
    }

    /// Whether a developer key is available to seed the Keychain.
    var hasDevelopmentAPIKey: Bool { developmentAPIKey != nil }
}

// MARK: - Loading from a bundle

extension AppConfig {
    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "config")

    /// Configuration of the running app, read once from `Bundle.main`.
    static let current = load(from: .main)

    /// Reads the configuration from `bundle`, falling back to ``fallback`` if
    /// its Info.plist is missing or malformed so the app still launches.
    static func load(from bundle: Bundle) -> AppConfig {
        load(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// Same as ``load(from:)`` for an already-read Info.plist dictionary.
    static func load(
        infoDictionary: [String: Any],
        honorsDevelopmentKey: Bool = AppConfig.isDebugBuild
    ) -> AppConfig {
        do {
            let config = try AppConfig(
                infoDictionary: infoDictionary,
                honorsDevelopmentKey: honorsDevelopmentKey
            )
            logger.info("Loaded app configuration: \(config.description, privacy: .public)")
            return config
        } catch {
            logger.fault("Invalid app configuration (\(String(describing: error), privacy: .public)); using defaults")
            return fallback
        }
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
    var description: String {
        "AppConfig(environment: \(environment.rawValue), xaiAPIHost: \(xaiAPIHost), "
            + "xaiRealtimeModel: \(xaiRealtimeModel), "
            + "developmentAPIKey: \(hasDevelopmentAPIKey ? "<redacted>" : "nil"))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "environment": environment,
                "xaiAPIHost": xaiAPIHost,
                "xaiRealtimeModel": xaiRealtimeModel,
                "developmentAPIKey": hasDevelopmentAPIKey ? "<redacted>" : "nil",
            ],
            displayStyle: .struct
        )
    }
}
