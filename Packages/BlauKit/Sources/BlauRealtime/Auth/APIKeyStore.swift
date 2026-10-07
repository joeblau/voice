import Synchronization

/// Where the user's xAI API key lives.
///
/// Production uses ``KeychainAPIKeyStore`` (iCloud Keychain, so the key
/// follows the user to their other devices). Tests and UI-test runs use
/// ``InMemoryAPIKeyStore``. Methods are `async` so callers on the main actor
/// never block on a Keychain round trip.
public protocol APIKeyStore: Sendable {
    /// The stored key, or `nil` when the user hasn't entered one.
    func load() async throws(APIKeyStoreError) -> XAIAPIKey?

    /// Stores `key`, replacing any existing key.
    func save(_ key: XAIAPIKey) async throws(APIKeyStoreError)

    /// Removes the key. Succeeds when there is nothing to remove.
    func delete() async throws(APIKeyStoreError)
}

/// Why the key store could not be read or written.
public enum APIKeyStoreError: Error, Sendable, Equatable {
    /// The device hasn't been unlocked since it booted
    /// (`errSecInteractionNotAllowed`). The key is readable after the first
    /// unlock (`kSecAttrAccessibleAfterFirstUnlock`), so this is transient.
    case locked
    /// The stored item exists but isn't a UTF-8 API key.
    case corruptItem
    /// Any other Keychain failure, with its `OSStatus`. `-34018`
    /// (`errSecMissingEntitlement`) means the app was built without a
    /// signing identity that grants Keychain access.
    case keychain(status: Int32)
}

/// A process-local key store for tests, previews and UI-test runs. Nothing
/// is persisted.
public final class InMemoryAPIKeyStore: APIKeyStore {
    private let key: Mutex<XAIAPIKey?>

    public init(key: XAIAPIKey? = nil) {
        self.key = Mutex(key)
    }

    public func load() async throws(APIKeyStoreError) -> XAIAPIKey? {
        key.withLock { $0 }
    }

    public func save(_ newKey: XAIAPIKey) async throws(APIKeyStoreError) {
        key.withLock { $0 = newKey }
    }

    public func delete() async throws(APIKeyStoreError) {
        key.withLock { $0 = nil }
    }
}
