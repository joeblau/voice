import BlauRealtime
import Foundation
import Synchronization
import os

/// Wires up xAI access for the app: the Keychain key store, the REST client,
/// on-device realtime token minting and the account model the UI binds to.
///
/// No backend is involved. The user's key lives in the iCloud Keychain and
/// the app mints short-lived realtime client secrets itself (issue #33).
@MainActor
final class XAIServices {
    /// Settings → xAI account and onboarding bind to this.
    let account: XAIAccount
    /// REST calls with the user's key (validation, minting, and later the
    /// topic-label fallback and fact extraction).
    let client: XAIHTTPClient
    /// Realtime client secrets for the WebSocket (#34).
    let tokenProvider: TokenProvider

    private let store: any APIKeyStore
    private let developmentAPIKey: String?
    private let seedMarker: any DevelopmentKeySeedMarker

    private static let logger = Logger(subsystem: "com.joeblau.blau", category: "xai")

    init(
        config: AppConfig,
        store: any APIKeyStore,
        transport: any HTTPTransport,
        seedMarker: any DevelopmentKeySeedMarker = UserDefaultsSeedMarker()
    ) {
        let client = XAIHTTPClient(baseURL: config.xaiAPIBaseURL, keyStore: store, transport: transport)
        let tokenProvider = TokenProvider(minter: XAIClientSecretMinter(client: client))
        self.client = client
        self.tokenProvider = tokenProvider
        self.store = store
        self.developmentAPIKey = config.developmentAPIKey
        self.seedMarker = seedMarker
        self.account = XAIAccount(
            store: store,
            validator: XAIKeyValidator(client: client),
            onKeyChange: { await tokenProvider.invalidate() }
        )
    }

    /// The app's services: the real Keychain and network, or the hermetic
    /// stubs a DEBUG UI-test run asks for.
    static func make(config: AppConfig) -> XAIServices {
        #if DEBUG
            if let stub = XAIUITestStub.current {
                return XAIServices(
                    config: config, store: InMemoryAPIKeyStore(), transport: stub.transport,
                    seedMarker: UserDefaultsSeedMarker(suiteName: "blau.uitests"))
            }
        #endif
        return XAIServices(config: config, store: KeychainAPIKeyStore(), transport: URLSessionHTTPTransport.shared)
    }

    /// Services that never touch the Keychain, the network or the app's
    /// `UserDefaults`: an in-memory key store holding `key`, an in-memory
    /// development-key seed marker, and a stub transport. The preview, unit
    /// test and UI test environments use these.
    ///
    /// DEBUG builds answer with the `BLAU_UI_TEST_XAI` stub when one is set
    /// and otherwise accept every key, so previews can walk through key
    /// entry. Release builds (where the stubs aren't compiled) behave as if
    /// offline.
    static func hermetic(config: AppConfig, key: XAIAPIKey? = nil) -> XAIServices {
        XAIServices(
            config: config, store: InMemoryAPIKeyStore(key: key), transport: hermeticTransport,
            seedMarker: InMemorySeedMarker())
    }

    private static var hermeticTransport: any HTTPTransport {
        #if DEBUG
            (XAIUITestStub.current ?? .accept).transport
        #else
            OfflineHTTPTransport()
        #endif
    }

    /// Whether `start()` has finished: the DEBUG developer key is seeded and
    /// the stored key loaded. `refresh()` does nothing until then.
    private(set) var hasStarted = false

    /// Runs once at launch: seeds the developer key (DEBUG only), then loads
    /// the stored key.
    func start() async {
        #if DEBUG
            await seedDevelopmentKey()
        #endif
        await account.load()
        hasStarted = true
    }

    /// Re-reads the Keychain, e.g. when the app becomes active, so a key
    /// added or removed on another device shows up.
    ///
    /// Does nothing until `start()` has finished. The app's first activation
    /// (`inactive → active`) arrives while `start()` may still be seeding the
    /// DEBUG developer key; a read then could miss the key that is about to
    /// be written and set `noKey`, and `start()`'s own load would be skipped
    /// because the account is already busy loading. `start()` reads the
    /// Keychain once it is done, so nothing is lost by skipping.
    func refresh() async {
        guard hasStarted else {
            Self.logger.debug("Skipping the xAI key refresh: launch hasn't finished loading the key")
            return
        }
        let before = account.status
        await account.load()
        if account.status != before {
            await tokenProvider.invalidate()
        }
    }

    #if DEBUG
        private func seedDevelopmentKey() async {
            do {
                let outcome = try await DevelopmentKeySeeder(store: store, marker: seedMarker)
                    .seedIfNeeded(developmentKey: developmentAPIKey)
                Self.logger.info("Development key seeding: \(String(describing: outcome), privacy: .public)")
            } catch {
                Self.logger.error("Development key seeding failed: \(String(describing: error), privacy: .public)")
            }
        }
    #endif
}

/// Fails every request as if the device were offline.
private struct OfflineHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A development-key seed marker that lives only as long as the services.
final class InMemorySeedMarker: DevelopmentKeySeedMarker {
    private let seeded = Mutex(false)

    var hasSeeded: Bool { seeded.withLock { $0 } }

    func markSeeded() {
        seeded.withLock { $0 = true }
    }
}
