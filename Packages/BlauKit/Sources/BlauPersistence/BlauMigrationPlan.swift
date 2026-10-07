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
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
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
