import SwiftUI

/// App entry point. The composition root (environment, feature flags, model
/// container) is built on top of this in later foundation work.
@main
struct BlauApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var xai = XAIServices.make(config: .current)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(xai.account)
                .task { await xai.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up a key added or removed on another device (iCloud Keychain).
            if phase == .active {
                Task { await xai.refresh() }
            }
        }
    }
}
