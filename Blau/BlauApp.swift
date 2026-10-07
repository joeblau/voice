import SwiftUI

/// App entry point. Builds the composition root (`AppEnvironment`) once,
/// injects it into the view hierarchy, starts its services and forwards scene
/// phase changes to them.
@main
struct BlauApp: App {
    @State private var environment = AppEnvironment.make(kind: .current)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .appEnvironment(environment)
                .task { await environment.start() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
