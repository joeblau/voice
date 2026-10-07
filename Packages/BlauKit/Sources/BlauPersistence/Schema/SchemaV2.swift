import SwiftData

/// Version 2 of Blau's persisted model: everything in `SchemaV1` plus the
/// long-term memory models (issue #61).
///
/// | Model             | Holds                                                         |
/// | ----------------- | ------------------------------------------------------------- |
/// | `Document`        | A knowledge-base page: a note, the company, the profile, or a collection |
/// | `CollectionItem`  | One prompt in a collection document (e.g. a YC interview question) and its practice record |
/// | `MemoryEntity`    | A person, organization, place... the user talks about          |
/// | `Fact`            | An add-only, validity-dated statement about the user or an entity |
/// | `ProfileBlock`    | A pinned block of text about the user, sent with every session |
///
/// The v1 models are copied unchanged (`SchemaV2.Conversation` and so on), so
/// `SchemaV1` stays exactly what shipped and a v1 store migrates with a
/// lightweight stage (`BlauMigrationPlan`). Every change is additive, which is
/// all CloudKit's production schema allows; `CloudKitCompatibility` checks
/// both the CloudKit rules and that v2 keeps every v1 entity and property
/// unchanged.
///
/// The memory models hold text only. Embeddings and search indexes built from
/// them are local and rebuildable (#62), never synced.
///
/// Once deployed to the CloudKit production environment this version is frozen
/// like v1: change it through a `SchemaV3`. See docs/data-model.md.
public enum SchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // v1, unchanged.
            Conversation.self,
            Topic.self,
            Utterance.self,
            VoiceProfile.self,
            VoiceEnrollmentSet.self,
            // Memory (v2).
            Document.self,
            CollectionItem.self,
            MemoryEntity.self,
            Fact.self,
            ProfileBlock.self,
        ]
    }
}
