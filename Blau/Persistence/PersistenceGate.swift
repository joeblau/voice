import BlauPersistence
import SwiftData
import SwiftUI

/// Opens the stores, then shows `content` with the synced store's
/// `ModelContainer` and the `PersistenceController` in the environment.
///
/// When the iCloud account changes, the controller reopens the store in the
/// new mode. `content` is rebuilt for the new container (`.id(generation)`),
/// because SwiftData models fetched from the old container are invalid once
/// it is released.
struct PersistenceGate<Content: View>: View {
    let persistence: PersistenceController
    @ViewBuilder let content: () -> Content

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let stack = persistence.stack {
                content()
                    .modelContainer(stack.container)
                    .id(persistence.generation)
            } else {
                // Opening takes well under a second: the iCloud account check
                // is capped by PersistenceOptions.accountStatusTimeout.
                Color.clear
            }
        }
        .environment(persistence)
        .task {
            await persistence.run()
        }
        .onChange(of: scenePhase) { _, phase in
            // Account changes made in the Settings app while Blau was in the
            // background don't always post CKAccountChanged.
            if phase == .active {
                Task { await persistence.refresh() }
            }
        }
    }
}
