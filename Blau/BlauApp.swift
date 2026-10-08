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
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    /// MetricKit collection starts here, as early as possible, so payloads
    /// MetricKit delivers right after launch are caught (#72).
    @State private var diagnostics: AppDiagnostics

    init() {
        let environment = AppEnvironment.make(kind: .current)
        _environment = State(initialValue: environment)
        // Background task handlers must be registered before launch ends
        // (#63). Only the real app runs background work.
        if environment.kind == .live {
            MemoryIndexBackgroundTask.register(environment.memoryIndexing)
            ProfileConsolidationBackgroundTask.register(environment.profileMemory)
        }
        let diagnostics = AppDiagnostics.live()
        diagnostics.start()
        _diagnostics = State(initialValue: diagnostics)
    }

    var body: some Scene {
        WindowGroup {
            PersistenceGate(persistence: environment.persistence) {
                RootView()
            }
            // Outside the gate, so a sync-mode switch (which rebuilds the
            // gate's content) neither drops the environment nor reloads the
            // xAI key, and doesn't touch the speech models.
            .appEnvironment(environment)
            .environment(diagnostics)
            .task { await environment.start() }
            .debugBenchmarksEntry()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
