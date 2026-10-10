import SwiftData

/// Version 3 of Blau's persisted model: everything in `SchemaV2` plus one
/// optional field, `Utterance.endReasonRaw`, which records that an agent
/// reply was cut short (issue #160).
///
/// | Model       | Adds                                                              |
/// | ----------- | ----------------------------------------------------------------- |
/// | `Utterance` | `endReasonRaw: String?`, an `UtteranceEndReason` raw value: `interrupted`, `bargedin` or `stopped` |
///
/// Before v3 the interrupted mark lived only in the turn orchestrator's
/// memory, so after a relaunch, in exports and on other devices a cut reply
/// looked complete. Rows written before v3 keep `nil`.
///
/// Every other model is copied unchanged (`SchemaV3.Conversation` and so on),
/// so `SchemaV2` stays exactly what shipped and a v2 store migrates with a
/// lightweight stage (`BlauMigrationPlan`). The change is additive, which is
/// all CloudKit's production schema allows; `CloudKitCompatibility` checks
/// both the CloudKit rules and that v3 keeps every v2 entity and property
/// unchanged.
///
/// Deploy it to the CloudKit production environment before shipping a build
/// that writes it (docs/release.md). Once deployed this version is frozen
/// like v1 and v2: change it through a `SchemaV4`. See docs/data-model.md.
public enum SchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // v1 (`Utterance` gains `endReasonRaw` in v3).
            Conversation.self,
            Topic.self,
            Utterance.self,
            VoiceProfile.self,
            VoiceEnrollmentSet.self,
            // Memory (v2), unchanged.
            Document.self,
            CollectionItem.self,
            MemoryEntity.self,
            Fact.self,
            ProfileBlock.self,
        ]
    }
}
