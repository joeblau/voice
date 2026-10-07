import BlauPersistence
import SwiftUI

/// App entry point. The composition root (environment, feature flags) is
/// built on top of this in later foundation work; it owns the persistence
/// stack (SwiftData mirrored to iCloud, see docs/sync.md) and the xAI
/// account services.
@main
struct BlauApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var persistence = PersistenceController.live(isDebugBuild: AppConfig.isDebugBuild)
    @State private var xai = XAIServices.make(config: .current)

    var body: some Scene {
        WindowGroup {
            PersistenceGate(persistence: persistence) {
                RootView()
            }
            // Outside the gate, so a sync-mode switch (which rebuilds the
            // gate's content) neither drops the account nor reloads the key.
            .environment(xai.account)
            .task { await xai.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up a key added or removed on another device (iCloud Keychain).
            // PersistenceGate refreshes the iCloud account status on its own.
            if phase == .active {
                Task { await xai.refresh() }
            }
        }
    }
}
