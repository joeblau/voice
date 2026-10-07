import BlauPersistence
import Foundation

extension PersistenceController {
    /// An in-memory controller for SwiftUI previews. Never touches iCloud or
    /// the disk.
    static func preview() -> PersistenceController {
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
}
