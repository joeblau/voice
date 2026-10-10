import Foundation
import SwiftData

/// Every schema version Blau has shipped, oldest first, and how to migrate
/// between them.
///
/// Present from v1 so that the first real migration is just a new entry.
/// CloudKit only allows additive changes once a schema is in production, so
/// later stages are expected to be `.lightweight`. See docs/data-model.md.
public enum BlauMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    /// v1 → v2 adds the memory models (`Document`, `CollectionItem`,
    /// `MemoryEntity`, `Fact`, `ProfileBlock`) and changes nothing else, so
    /// Core Data infers the mapping: existing rows are kept as they are and
    /// the new tables start empty.
    public static var migrateV1toV2: MigrationStage {
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    }

    /// v2 → v3 adds one optional attribute, `Utterance.endReasonRaw` (#160),
    /// and changes nothing else, so Core Data infers the mapping: existing
    /// rows are kept as they are and the new column starts `nil`.
    public static var migrateV2toV3: MigrationStage {
        .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)
    }
}

/// Builds `ModelContainer`s for Blau's schema.
///
/// Always opens stores with the current schema and `BlauMigrationPlan`, so no
/// call site can forget the migration plan. The app's CloudKit-backed store
/// is opened by `PersistenceController` (see `syncedConfiguration(for:location:)`
/// and docs/sync.md).
public enum BlauModelContainer {
    /// The current schema, built from `CurrentSchema`.
    public static var schema: Schema {
        Schema(versionedSchema: CurrentSchema.self)
    }

    /// Opens a container with `configurations` (each should use `schema`).
    public static func make(configurations: [ModelConfiguration]) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: BlauMigrationPlan.self, configurations: configurations)
    }

    /// A store at `url` with CloudKit sync off. For tests and tools.
    public static func makeLocal(url: URL) throws -> ModelContainer {
        try make(configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    }

    /// A fresh, empty in-memory store with CloudKit sync off. For tests and
    /// SwiftUI previews.
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            UUID().uuidString,
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try make(configurations: [configuration])
    }
}
