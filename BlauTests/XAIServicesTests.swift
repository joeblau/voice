import BlauRealtime
import Foundation
import Security
import Testing

@testable import Blau

/// Assembled at runtime so the repository never contains a key-shaped literal.
private let fakeKeyRaw = "xai-" + String(repeating: "AppTest0Key", count: 5) + "c3d4"

/// Whether this test host may use the Keychain. A simulator build made with
/// `CODE_SIGNING_ALLOWED=NO` has no signature and therefore no
/// keychain-access-groups entitlement, so every `SecItem` call fails with
/// `errSecMissingEntitlement` (-34018). Signed builds (Xcode's default "Sign
/// to Run Locally", or `CODE_SIGN_IDENTITY=-`) and devices have access.
private let keychainIsAvailable: Bool = {
    let probe: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.joeblau.blau.tests.probe",
        kSecAttrAccount as String: "probe",
        kSecUseDataProtectionKeychain as String: true,
    ]
    return SecItemCopyMatching(probe as CFDictionary, nil) != errSecMissingEntitlement
}()

/// The real Keychain on the simulator, through the same code path the app
/// uses, but under a throwaway service so the app's own item is never
/// touched.
@Suite(
    "Keychain API key store (simulator Keychain)", .serialized,
    .enabled(
        if: keychainIsAvailable, "Unsigned test host: the Keychain needs a signed build (errSecMissingEntitlement)")
)
struct KeychainIntegrationTests {
    private let store = KeychainAPIKeyStore(service: "com.joeblau.blau.tests.\(UUID().uuidString)")

    @Test func roundTripsASynchronizableKey() async throws {
        let key = try XAIAPIKey(validating: fakeKeyRaw)
        defer { Task { try? await store.delete() } }

        #expect(try await store.load() == nil)
        try await store.save(key)
        #expect(try await store.load() == key)

        let replacement = try XAIAPIKey(validating: fakeKeyRaw + "x")
        try await store.save(replacement)
        #expect(try await store.load() == replacement)

        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test func storedItemIsSynchronizableAndAvailableAfterFirstUnlock() async throws {
        let service = "com.joeblau.blau.tests.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service)
        try await store.save(try XAIAPIKey(validating: fakeKeyRaw))
        defer { Task { try? await store.delete() } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainAPIKeyStore.defaultAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue == true)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }
}

@Suite("XAIServices")
@MainActor
struct XAIServicesTests {
    private func config(developmentKey: String?) -> AppConfig {
        AppConfig(
            environment: .debug, xaiAPIHost: "api.x.ai", xaiRealtimeModel: "grok-voice-think-fast-2.0",
            developmentAPIKey: developmentKey)
    }

    private func services(
        developmentKey: String? = nil, stub: XAIUITestStub = .accept, store: InMemoryAPIKeyStore = InMemoryAPIKeyStore()
    ) -> XAIServices {
        XAIServices(
            config: config(developmentKey: developmentKey), store: store, transport: stub.transport,
            seedMarker: UserDefaultsSeedMarker(suiteName: "blau.tests.\(UUID().uuidString)"))
    }

    @Test func startsWithoutAKeyOnAFreshInstall() async {
        let services = services()
        await services.start()
        #expect(services.account.status == .noKey)
    }

    @Test func debugBuildsSeedTheDevelopmentKeyOnFirstLaunch() async throws {
        let store = InMemoryAPIKeyStore()
        let services = services(developmentKey: fakeKeyRaw, store: store)
        await services.start()
        #expect(try await store.load()?.rawValue == fakeKeyRaw)
        #expect(services.account.hasKey)
    }

    @Test func usesTheConfiguredAPIHost() {
        #expect(services().client.baseURL.absoluteString == "https://api.x.ai")
    }

    @Test func mintsRealtimeTokensWithTheStoredKeyAndDropsThemWhenTheKeyChanges() async throws {
        let services = services()
        await services.start()
        #expect(await services.account.connect(apiKey: fakeKeyRaw))

        let secret = try await services.tokenProvider.clientSecret()
        #expect(secret.webSocketSubprotocol == "xai-client-secret.ui-test-secret")

        await services.account.removeKey()
        await #expect(throws: XAIError.missingAPIKey) { try await services.tokenProvider.clientSecret() }
    }

    @Test func anInvalidKeyIsReportedAndNotStored() async throws {
        let store = InMemoryAPIKeyStore()
        let services = services(stub: .reject, store: store)
        await services.start()
        #expect(await !services.account.connect(apiKey: fakeKeyRaw))
        #expect(services.account.problem?.kind == .invalidKey)
        #expect(try await store.load() == nil)
    }
}
