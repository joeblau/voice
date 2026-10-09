import BlauCore
import Foundation
import os

/// The app's side of `AppConfig` (BlauCore): whether this build honours the
/// development key, the fallback, and the loaders that log. BlauCore can't
/// decide the first (a package's `#if DEBUG` is not the app's) or log (it is
/// layer 0), so they live here. See `docs/configuration.md`.
extension AppConfig {
    /// Whether this app binary was compiled with `DEBUG`. Only DEBUG builds
    /// honour `XAI_DEV_API_KEY`.
    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// Values used when the bundle's configuration is unusable: the
    /// `Config/Base.xcconfig` defaults for this build's environment.
    static let fallback = AppConfig.defaults(environment: isDebugBuild ? .debug : .release)

    /// Parses an Info.plist dictionary, honouring the development key only in
    /// DEBUG builds of the app (``isDebugBuild``).
    init(infoDictionary: [String: Any]) throws(LoadError) {
        try self.init(infoDictionary: infoDictionary, honorsDevelopmentKey: Self.isDebugBuild)
    }
}

// MARK: - Loading from a bundle

extension AppConfig {
    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "config")

    /// Configuration of the running app, read once from `Bundle.main`, with
    /// the run-time overrides in `UserDefaults` applied. An override changed
    /// while the app runs takes effect at the next launch.
    static let current = load(from: .main).applyingOverrides(UserDefaultsConfigurationOverrides())

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

    /// ``applyingOverrides(_:reportingInvalid:)`` with logging: a fault for an
    /// ignored invalid override, a notice when the model is overridden.
    func applyingOverrides(_ source: any ConfigurationOverrideSource) -> AppConfig {
        let config = applyingOverrides(source) { override in
            Self.logger.fault("Ignoring invalid realtime model override \(override, privacy: .public)")
        }
        if let model = config.xaiRealtimeModelOverride, model != xaiRealtimeModelOverride {
            Self.logger.notice(
                "Realtime model overridden: \(model, privacy: .public) instead of \(xaiRealtimeModel, privacy: .public)"
            )
        }
        return config
    }
}
