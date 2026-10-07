import BlauRealtime
import Foundation
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

    /// Runs once at launch: seeds the developer key (DEBUG only), then loads
    /// the stored key.
    func start() async {
        #if DEBUG
            await seedDevelopmentKey()
        #endif
        await account.load()
    }

    /// Re-reads the Keychain, e.g. when the app becomes active, so a key
    /// added or removed on another device shows up.
    func refresh() async {
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
