import BlauPersistence
import Foundation
import SwiftData

extension PersistenceController {
    /// A fresh, empty in-memory controller that never touches iCloud or the
    /// disk. The preview, unit-test and UI-test `AppEnvironment`s use one.
    /// It starts opening its store right away; `await start()` to wait for
    /// it.
    static func inMemory() -> PersistenceController {
        let controller = PersistenceController(
            options: PersistenceOptions(
                location: StoreLocation(directory: URL.temporaryDirectory.appending(path: "BlauPreview")),
                cloudKitEntitled: false,
                storeOverride: .memory
            ),
            accountProvider: nil
        )
        Task { await controller.start() }
        return controller
    }

    /// An in-memory controller for SwiftUI previews (see `inMemory()`).
    static func preview() -> PersistenceController {
        inMemory()
    }
}

#if DEBUG
    extension PersistenceController {
        /// A fresh, empty in-memory `ModelContainer` for previews of views
        /// that read the store directly (`@Query`, `modelContext`).
        static func previewContainer() -> ModelContainer {
            do {
                return try BlauModelContainer.makeInMemory()
            } catch {
                fatalError("Couldn't open an in-memory store for a preview: \(error)")
            }
        }
    }
#endif
