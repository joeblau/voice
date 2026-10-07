import Foundation
import SwiftData
import os

/// The open stores for one run of the app (until the sync mode changes).
public struct PersistenceStack: Sendable {
    /// How the synced store was opened.
    public let mode: SyncMode
    /// Text and voiceprint: `Conversation`, `Topic`, `StoredUtterance`,
    /// `VoiceProfile`... Mirrored to CloudKit when `mode` is `.cloudKit`.
    /// Hand this to SwiftUI with `.modelContainer(_:)`.
    public let container: ModelContainer
    /// Local-only derived data (`HistoryCursor`, caches). Never synced.
    public let derivedContainer: ModelContainer
    /// Where the on-disk stores live (unused when `mode` is `.inMemory`).
    public let location: StoreLocation

    public init(mode: SyncMode, container: ModelContainer, derivedContainer: ModelContainer, location: StoreLocation) {
        self.mode = mode
        self.container = container
        self.derivedContainer = derivedContainer
        self.location = location
    }

    /// The synced store's file, or `nil` for an in-memory store.
    public var syncedStoreURL: URL? {
        mode.isPersistent ? location.syncedStoreURL : nil
    }
}

extension BlauModelContainer {
    /// The `ModelConfiguration` of the synced store in `mode`.
    ///
    /// CloudKit and local-only use the **same file**, so turning sync off
    /// (signed out of iCloud) keeps every conversation, and turning it back
    /// on exports what was written meanwhile.
    public static func syncedConfiguration(for mode: SyncMode, location: StoreLocation) -> ModelConfiguration {
        switch mode {
        case .inMemory:
            ModelConfiguration(
                "\(BlauCloud.syncedConfigurationName)-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        case .cloudKit, .localOnly:
            ModelConfiguration(
                BlauCloud.syncedConfigurationName,
                schema: schema,
                url: location.syncedStoreURL,
                cloudKitDatabase: mode.cloudKitDatabase
            )
        }
    }
}

/// Opens a `PersistenceStack`, falling back rather than failing:
///
/// 1. CloudKit mode that fails to open retries the same file local-only.
/// 2. A local store that fails to open (corrupt, or a migration error) falls
///    back to an in-memory store and leaves the file untouched, so the app
///    still launches and no data is deleted.
/// 3. A derived store that fails to open is recreated (it is rebuildable).
public struct PersistenceBootstrap: Sendable {
    /// Opens the synced store. Tests inject failures here.
    public var openSyncedStore: @Sendable (ModelConfiguration) throws -> ModelContainer
    /// Opens the derived store at a URL.
    public var openDerivedStore: @Sendable (URL) throws -> ModelContainer
    /// Initializes the CloudKit development schema (DEBUG only).
    public var schemaInitializer: any CloudKitSchemaInitializing
    /// Remembers which schema was last initialized.
    public var schemaGate: @Sendable (String) -> CloudKitSchemaInitializationGate

    public init(
        openSyncedStore: @escaping @Sendable (ModelConfiguration) throws -> ModelContainer = {
            try BlauModelContainer.make(configurations: [$0])
        },
        openDerivedStore: @escaping @Sendable (URL) throws -> ModelContainer = { try DerivedStore.open(at: $0) },
        schemaInitializer: any CloudKitSchemaInitializing = CoreDataCloudKitSchemaInitializer(),
        schemaGate: @escaping @Sendable (String) -> CloudKitSchemaInitializationGate = {
            CloudKitSchemaInitializationGate(containerIdentifier: $0)
        }
    ) {
        self.openSyncedStore = openSyncedStore
        self.openDerivedStore = openDerivedStore
        self.schemaInitializer = schemaInitializer
        self.schemaGate = schemaGate
    }

    /// The production bootstrap.
    public static var live: PersistenceBootstrap { PersistenceBootstrap() }

    /// Opens the stores for `mode`. Never throws: see the type's fallbacks.
    public func makeStack(mode requested: SyncMode, options: PersistenceOptions) -> PersistenceStack {
        let location = options.location
        var mode = requested

        if mode.isPersistent {
            do {
                try location.prepare()
            } catch {
                PersistenceLog.logger.fault(
                    "Store directory unavailable: \(String(describing: error), privacy: .public)")
                mode = .inMemory(.storeFailed(String(describing: error)))
            }
        }

        if case .cloudKit(let containerIdentifier) = mode {
            initializeSchemaIfNeeded(containerIdentifier: containerIdentifier, options: options)
        }

        let container = openSynced(mode: &mode, location: location)
        let derived = openDerived(persistent: mode.isPersistent, location: location)
        PersistenceLog.logger.notice("Opened stores: \(String(describing: mode), privacy: .public)")
        return PersistenceStack(mode: mode, container: container, derivedContainer: derived, location: location)
    }

    private func initializeSchemaIfNeeded(containerIdentifier: String, options: PersistenceOptions) {
        let schema = BlauModelContainer.schema
        let gate = schemaGate(containerIdentifier)
        guard gate.shouldInitialize(schema, policy: options.schemaInitialization) else { return }
        do {
            try schemaInitializer.initializeSchema(
                schema, storeURL: options.location.syncedStoreURL, containerIdentifier: containerIdentifier)
            gate.markInitialized(schema)
            PersistenceLog.logger.notice("Initialized the CloudKit development schema")
        } catch {
            // Not fatal: sync still works for record types that exist. It is
            // retried next launch because the gate wasn't marked.
            PersistenceLog.logger.error(
                "initializeCloudKitSchema failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func openSynced(mode: inout SyncMode, location: StoreLocation) -> ModelContainer {
        do {
            return try openSyncedStore(BlauModelContainer.syncedConfiguration(for: mode, location: location))
        } catch {
            let failedMode = String(describing: mode)
            PersistenceLog.logger.error(
                "Opening the synced store (\(failedMode, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
            )
            if mode.isCloudKit {
                mode = .localOnly(.cloudKitFailed(String(describing: error)))
                return openSynced(mode: &mode, location: location)
            }
            if mode.isPersistent {
                mode = .inMemory(.storeFailed(String(describing: error)))
                return openSynced(mode: &mode, location: location)
            }
            // An in-memory store failing to open means the schema itself is
            // broken, which the unit tests rule out.
            fatalError("Can't open an in-memory store: \(error)")
        }
    }

    private func openDerived(persistent: Bool, location: StoreLocation) -> ModelContainer {
        if persistent {
            do {
                return try openDerivedStore(location.derivedStoreURL)
            } catch {
                PersistenceLog.logger.error(
                    "Derived store unavailable, using memory: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            return try DerivedStore.makeInMemory()
        } catch {
            fatalError("Can't open an in-memory derived store: \(error)")
        }
    }
}
