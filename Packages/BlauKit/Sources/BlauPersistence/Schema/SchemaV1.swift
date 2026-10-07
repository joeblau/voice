import SwiftData

/// Version 1 of Blau's persisted model: conversations, their topics and
/// utterances, and the user's voiceprint.
///
/// Every model is mirrored to the user's private CloudKit database, so the
/// schema follows CloudKit's rules (checked by `CloudKitCompatibility` and
/// its tests):
///
/// - every attribute is optional or has a default value;
/// - nothing is `@Attribute(.unique)` and there is no `#Unique`;
/// - every relationship is optional and has an inverse;
/// - no relationship uses the `.deny` delete rule;
/// - models are flat (no `@Model` inheritance).
///
/// Enums are stored as raw strings (`roleRaw`, `sourceRaw`) and exposed
/// through computed properties, so a value written by a newer app version
/// never fails to load.
///
/// Superseded by `SchemaV2`, which copies these models unchanged; v1 stays
/// so stores written by v1 builds migrate (`BlauMigrationPlan`).
///
/// Once this schema is deployed to the CloudKit production environment it
/// can only change additively, through a new `VersionedSchema` and a stage in
/// `BlauMigrationPlan`. Never edit a shipped version in place. See
/// docs/data-model.md.
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Conversation.self,
            Topic.self,
            Utterance.self,
            VoiceProfile.self,
            VoiceEnrollmentSet.self,
        ]
    }
}
