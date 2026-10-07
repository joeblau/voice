import BlauCore
import BlauTelemetry
import Foundation
import SwiftData
import os

/// Where a `PersistenceService` keeps its data.
public enum PersistenceStoreKind: Hashable, Sendable {
    /// A SQLite store on disk.
    case persistent(url: URL)
    /// An in-memory store that is gone when the process exits. Previews,
    /// tests, and the fallback when the on-disk store can't be opened.
    case inMemory
}

/// The app's SwiftData store, as the composition root holds it.
///
/// Views get `modelContainer` through `.modelContainer(_:)`; pipeline writes
/// go through a `ModelActor` on the same container (#21). The service saves
/// the main context whenever the app leaves the foreground, so an edit made
/// in the UI survives the process being suspended or killed.
public protocol PersistenceService: AppLifecycleParticipant {
    var modelContainer: ModelContainer { get }

    /// Where the data lives.
    var storeKind: PersistenceStoreKind { get }

    /// Why the on-disk store couldn't be opened, when the service fell back
    /// to an in-memory store. `nil` normally. The UI should warn that nothing
    /// will be saved.
    var openFailure: String? { get }

    /// Saves the main context if it has unsaved changes.
    func saveMainContext() async throws
}

/// The `PersistenceService` for Blau's SwiftData schema.
public final class SwiftDataPersistence: PersistenceService {
    /// The store's configuration name; its SQLite file is `Blau.store` in
    /// Application Support.
    public static let storeName = "Blau"

    public let modelContainer: ModelContainer
    public let storeKind: PersistenceStoreKind
    public let openFailure: String?

    private let signposter: Signposter

    public init(
        modelContainer: ModelContainer,
        storeKind: PersistenceStoreKind,
        openFailure: String? = nil,
        signposter: Signposter = Signposts.data
    ) {
        self.modelContainer = modelContainer
        self.storeKind = storeKind
        self.openFailure = openFailure
        self.signposter = signposter
    }

    /// The app's on-disk store.
    ///
    /// CloudKit mirroring is off here; configuring the
    /// `iCloud.com.joeblau.blau` private database is #20. If the store can't
    /// be opened (for example a failed migration), this logs a fault and
    /// returns an in-memory store instead, with `openFailure` set, so the app
    /// still launches and can tell the user.
    ///
    /// - Parameter url: Where to put the store. Defaults to SwiftData's
    ///   location for `storeName`.
    public static func live(url: URL? = nil) -> SwiftDataPersistence {
        let schema = BlauModelContainer.schema
        let configuration =
            if let url {
                ModelConfiguration(storeName, schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
            }
        do {
            let container = try BlauModelContainer.make(configurations: [configuration])
            Log.data.notice("Opened the SwiftData store at \(configuration.url.path, privacy: .public)")
            return SwiftDataPersistence(modelContainer: container, storeKind: .persistent(url: configuration.url))
        } catch {
            let reason = String(describing: error)
            Log.data.fault("Couldn't open the SwiftData store; using memory only: \(reason, privacy: .public)")
            do {
                return SwiftDataPersistence(
                    modelContainer: try BlauModelContainer.makeInMemory(),
                    storeKind: .inMemory,
                    openFailure: reason
                )
            } catch {
                // An in-memory store of a schema that loads in every unit
                // test can only fail if SwiftData itself is broken.
                fatalError("Couldn't create an in-memory SwiftData store: \(error)")
            }
        }
    }

    /// A fresh, empty in-memory store. For previews and tests.
    public static func inMemory() throws -> SwiftDataPersistence {
        SwiftDataPersistence(modelContainer: try BlauModelContainer.makeInMemory(), storeKind: .inMemory)
    }

    public func saveMainContext() async throws {
        try await MainActor.run {
            let context = modelContainer.mainContext
            guard context.hasChanges else { return }
            try signposter.withInterval(.dbSave) { try context.save() }
        }
    }

    /// Saves pending UI edits whenever the app leaves the foreground.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        guard transition.to != .active else { return }
        do {
            try await saveMainContext()
        } catch {
            Log.data.error(
                "Saving on \(transition.description, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
