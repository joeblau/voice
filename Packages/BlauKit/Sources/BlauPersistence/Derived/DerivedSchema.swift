import Foundation
import SwiftData
import os

/// Version 1 of the derived, local-only store.
///
/// Derived data never syncs (`cloudKitDatabase: .none`) and can always be
/// rebuilt from the synced store, so it is not bound by CloudKit's rules or
/// its additive-only schema policy. When this schema changes incompatibly,
/// `DerivedStore` deletes the store and starts over. Search indexes and
/// embeddings (#62) are rebuildable caches too, but live in their own SQLite
/// files.
public enum DerivedSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [HistoryCursor.self]
    }

    /// How far one consumer has read the synced store's persistent history.
    ///
    /// A history token is specific to one store on one device, so it must
    /// never sync. Each consumer (sync status, the memory indexer, ...) keeps
    /// its own cursor and resumes from it after a relaunch.
    @Model
    public final class HistoryCursor {
        /// The consumer's stable name, e.g. `sync-status`.
        @Attribute(.unique) public var consumer: String

        /// The JSON-encoded `DefaultHistoryToken` of the last transaction
        /// the consumer processed.
        public var token: Data?

        /// When the cursor last moved.
        public var updatedAt: Date

        public init(consumer: String, token: Data?, updatedAt: Date) {
            self.consumer = consumer
            self.token = token
            self.updatedAt = updatedAt
        }
    }
}

/// Every version of the derived schema. Derived data is rebuildable, so an
/// incompatible change may simply bump the version without a stage:
/// `DerivedStore` then recreates the store.
public enum DerivedMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DerivedSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

public typealias HistoryCursor = DerivedSchemaV1.HistoryCursor

/// Opens the derived, local-only store.
public enum DerivedStore {
    /// The current derived schema.
    public static var schema: Schema {
        Schema(versionedSchema: DerivedSchemaV1.self)
    }

    /// Opens the store at `url` with CloudKit off. If it can't be opened
    /// (corrupt, or written by an incompatible schema) it is deleted and
    /// recreated: everything in it is rebuildable.
    public static func open(at url: URL, fileManager: FileManager = .default) throws -> ModelContainer {
        do {
            return try make(url: url)
        } catch {
            PersistenceLog.logger.error(
                "Derived store failed to open, recreating it: \(String(describing: error), privacy: .public)")
            for file in StoreLocation.sqliteFiles(for: url) where fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
            return try make(url: url)
        }
    }

    /// A fresh in-memory derived store.
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "\(BlauCloud.derivedConfigurationName)-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema, migrationPlan: DerivedMigrationPlan.self, configurations: [configuration])
    }

    private static func make(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            BlauCloud.derivedConfigurationName,
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema, migrationPlan: DerivedMigrationPlan.self, configurations: [configuration])
    }
}
