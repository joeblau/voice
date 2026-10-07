import Foundation
import Security

/// Stores the xAI API key as a generic-password item in the Keychain.
///
/// The item is created with:
///
/// - `kSecAttrSynchronizable = true`: iCloud Keychain syncs it end-to-end
///   encrypted to the user's other devices signed in to the same Apple
///   Account, so a key entered once works everywhere (issue #33).
/// - `kSecAttrAccessibleAfterFirstUnlock`: readable while the screen is
///   locked, which long background voice sessions need to mint new realtime
///   tokens. (A `…ThisDeviceOnly` class would block syncing.)
/// - `kSecUseDataProtectionKeychain = true`: on macOS this selects the iOS
///   style keychain, the only one that supports iCloud sync. It's the only
///   keychain on iOS, where the flag is a no-op.
///
/// Deleting the item removes it from every synced device, which is what
/// "Remove key" in Settings means.
///
/// Keychain calls block, so the `async` methods run off the caller's actor
/// (they are `nonisolated` and the type holds no actor state).
public struct KeychainAPIKeyStore: APIKeyStore {
    /// `kSecAttrService` of Blau's key item.
    public static let defaultService = "com.joeblau.blau.xai"

    /// `kSecAttrAccount` of Blau's key item.
    public static let defaultAccount = "api-key"

    /// Shown in Keychain Access / Passwords for the item.
    static let label = "Blau xAI API key"

    private let service: String
    private let account: String
    private let accessGroup: String?
    private let keychain: any KeychainServices

    /// - Parameters:
    ///   - service: Item service. Tests pass a unique value so they never
    ///     touch the real item.
    ///   - account: Item account.
    ///   - accessGroup: Keychain access group; `nil` uses the app's default
    ///     group (`<team id>.com.joeblau.blau`).
    ///   - keychain: The Security framework, or a fake in tests.
    public init(
        service: String = KeychainAPIKeyStore.defaultService,
        account: String = KeychainAPIKeyStore.defaultAccount,
        accessGroup: String? = nil,
        keychain: any KeychainServices = SystemKeychain()
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.keychain = keychain
    }

    public func load() async throws(APIKeyStoreError) -> XAIAPIKey? {
        var query = itemQuery(synchronizable: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data, let string = String(data: data, encoding: .utf8),
                let key = try? XAIAPIKey(validating: string)
            else { throw .corruptItem }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: result.status)
        }
    }

    public func save(_ key: XAIAPIKey) async throws(APIKeyStoreError) {
        let data = Data(key.rawValue.utf8)
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: Self.label,
        ]

        // Update first so an existing item keeps its identity (and syncs as
        // a change rather than a delete + add).
        var status = keychain.update(itemQuery(synchronizable: true), attributesToUpdate: changes)
        if status == errSecItemNotFound {
            var attributes = itemQuery(synchronizable: true)
            attributes.merge(changes) { _, new in new }
            status = keychain.add(attributes)
            if status == errSecDuplicateItem {
                // Another writer (or an iCloud Keychain sync) created it in between.
                status = keychain.update(itemQuery(synchronizable: true), attributesToUpdate: changes)
            }
        }
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func delete() async throws(APIKeyStoreError) {
        // `Any` also removes a non-synchronizable copy left by an earlier build.
        let status = keychain.delete(itemQuery(synchronizable: nil))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    /// The attributes that identify Blau's item.
    ///
    /// - Parameter synchronizable: `true` matches the iCloud Keychain item;
    ///   `nil` matches synced and device-local items alike
    ///   (`kSecAttrSynchronizableAny`).
    func itemQuery(synchronizable: Bool?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable
        } else {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    static func error(for status: OSStatus) -> APIKeyStoreError {
        status == errSecInteractionNotAllowed ? .locked : .keychain(status: status)
    }
}

// MARK: - Security framework seam

/// The four `SecItem` calls ``KeychainAPIKeyStore`` makes, so its queries can
/// be checked against a fake on the macOS host, where `swift test` has no
/// Keychain entitlement.
///
/// Dictionaries are `[String: Any]` (bridged to `CFDictionary`) and never
/// cross an isolation boundary: every call is synchronous.
public protocol KeychainServices: Sendable {
    /// `SecItemCopyMatching` for a query that returns data.
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    /// `SecItemAdd`.
    func add(_ attributes: [String: Any]) -> OSStatus
    /// `SecItemUpdate`.
    func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus
    /// `SecItemDelete`.
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real Keychain.
public struct SystemKeychain: KeychainServices {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
