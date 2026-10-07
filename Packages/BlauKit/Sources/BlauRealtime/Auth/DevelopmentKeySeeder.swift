import Foundation

/// Remembers whether the developer key has been copied into the Keychain on
/// this device. Stores only a flag, never the key.
public protocol DevelopmentKeySeedMarker: Sendable {
    var hasSeeded: Bool { get }
    func markSeeded()
}

/// A ``DevelopmentKeySeedMarker`` backed by `UserDefaults`.
///
/// Holds a suite name rather than a `UserDefaults` instance, which isn't
/// `Sendable`; `UserDefaults` itself is thread-safe.
public struct UserDefaultsSeedMarker: DevelopmentKeySeedMarker {
    public static let defaultsKey = "blau.xai.developmentKeySeeded"

    private let suiteName: String?

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public var hasSeeded: Bool { defaults.bool(forKey: Self.defaultsKey) }

    public func markSeeded() { defaults.set(true, forKey: Self.defaultsKey) }
}

/// DEBUG convenience: copies `XAI_DEV_API_KEY` (from the gitignored
/// `Config/Secrets.xcconfig`, surfaced as `AppConfig.developmentAPIKey`) into
/// the Keychain on first launch, so developers don't type their key on every
/// simulator.
///
/// It seeds at most once per device: after that the Keychain is the only
/// source of truth, so a key the developer replaces or removes in Settings
/// stays replaced or removed. It never overwrites a stored key (for example
/// one that arrived through iCloud Keychain). Release builds never carry a
/// development key (`AppConfig` returns `nil`), and the app only calls this in
/// DEBUG builds.
public struct DevelopmentKeySeeder: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The key was copied into the store.
        case seeded
        /// The store already had a key, which was kept.
        case keptStoredKey
        /// Seeded on an earlier launch; nothing to do.
        case alreadySeeded
        /// No development key is configured.
        case noDevelopmentKey
        /// The configured value isn't a plausible key; nothing was stored.
        case invalidDevelopmentKey
    }

    private let store: any APIKeyStore
    private let marker: any DevelopmentKeySeedMarker

    public init(store: any APIKeyStore, marker: any DevelopmentKeySeedMarker) {
        self.store = store
        self.marker = marker
    }

    public func seedIfNeeded(developmentKey: String?) async throws(APIKeyStoreError) -> Outcome {
        guard let developmentKey else { return .noDevelopmentKey }
        guard !marker.hasSeeded else { return .alreadySeeded }
        guard let key = try? XAIAPIKey(validating: developmentKey) else { return .invalidDevelopmentKey }

        if try await store.load() != nil {
            marker.markSeeded()
            return .keptStoredKey
        }
        try await store.save(key)
        marker.markSeeded()
        return .seeded
    }
}
