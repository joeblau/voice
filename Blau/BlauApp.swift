import SwiftUI

/// App entry point. Builds the composition root (`AppEnvironment`) once,
/// injects it into the view hierarchy, starts its services and forwards scene
/// phase changes to them.
///
/// `PersistenceGate` opens the stores (SwiftData mirrored to iCloud, see
/// docs/sync.md) and hands the current container to `RootView`, rebuilding it
/// when a sync-mode switch replaces the container.
@main
struct BlauApp: App {
    @State private var environment = AppEnvironment.make(kind: .current)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PersistenceGate(persistence: environment.persistence) {
                RootView()
            }
            // Outside the gate, so a sync-mode switch (which rebuilds the
            // gate's content) neither drops the environment nor reloads the
            // xAI key.
            .appEnvironment(environment)
            .task { await environment.start() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
