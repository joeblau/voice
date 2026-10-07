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
///
/// The app refreshes the account status when it becomes active from
/// `AppEnvironment.handleScenePhase`, which also saves pending edits when it
/// leaves the foreground.
struct PersistenceGate<Content: View>: View {
    let persistence: PersistenceController
    @ViewBuilder let content: () -> Content

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
    }
}
