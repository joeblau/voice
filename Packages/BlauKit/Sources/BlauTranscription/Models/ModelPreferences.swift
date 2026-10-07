import Foundation
import Synchronization

/// The user's choices about model downloads, shown in Settings.
public struct ModelPreferences: Codable, Hashable, Sendable {
    /// Which networks downloads may use.
    public enum DownloadPolicy: String, Codable, CaseIterable, Sendable {
        /// Wi-Fi or Ethernet only; never cellular, a hotspot or Low Data
        /// Mode. The default: the models are hundreds of megabytes.
        case wifiOnly
        /// Any connection, cellular included.
        case anyNetwork
    }

    public var downloadPolicy: DownloadPolicy
    /// Whether the extra speech models (the Parakeet TDT v3 second pass and
    /// the 1280 ms streaming export) download automatically after the
    /// required ones.
    public var downloadsOptionalModels: Bool

    public init(downloadPolicy: DownloadPolicy = .wifiOnly, downloadsOptionalModels: Bool = true) {
        self.downloadPolicy = downloadPolicy
        self.downloadsOptionalModels = downloadsOptionalModels
    }

    /// Wi-Fi only, optional models on.
    public static let `default` = ModelPreferences()
}

/// Persists ``ModelPreferences``.
public protocol ModelPreferencesStore: Sendable {
    func load() -> ModelPreferences
    func save(_ preferences: ModelPreferences)
}

/// Keeps preferences in `UserDefaults` as JSON under one key. They are
/// per device on purpose: whether to use cellular depends on the device's
/// data plan.
public struct UserDefaultsModelPreferencesStore: ModelPreferencesStore {
    public static let defaultKey = "blau.models.preferences"

    private let suiteName: String?
    private let key: String

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> ModelPreferences {
        guard let data = defaults.data(forKey: key),
            let preferences = try? JSONDecoder().decode(ModelPreferences.self, from: data)
        else { return .default }
        return preferences
    }

    public func save(_ preferences: ModelPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps preferences in memory. For tests, previews and UI-test fixtures.
public final class InMemoryModelPreferencesStore: ModelPreferencesStore {
    private let value: Mutex<ModelPreferences>

    public init(_ preferences: ModelPreferences = .default) {
        value = Mutex(preferences)
    }

    public func load() -> ModelPreferences { value.withLock { $0 } }

    public func save(_ preferences: ModelPreferences) { value.withLock { $0 = preferences } }
}
