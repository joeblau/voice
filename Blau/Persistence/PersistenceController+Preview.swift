import BlauPersistence
import Foundation

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
