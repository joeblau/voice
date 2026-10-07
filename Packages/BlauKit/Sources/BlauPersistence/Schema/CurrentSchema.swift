// The model types the rest of the app uses. They always point at the latest
// schema version; when a `SchemaV2` ships, move these aliases to it and keep
// `SchemaV1` untouched for migration.

/// The schema version the app reads and writes.
public typealias CurrentSchema = SchemaV1

public typealias Conversation = CurrentSchema.Conversation

public typealias Topic = CurrentSchema.Topic

/// The persisted utterance. Named `StoredUtterance` rather than `Utterance`
/// so it never collides with the pipeline's `BlauCore.Utterance` value type.
public typealias StoredUtterance = CurrentSchema.Utterance

public typealias VoiceProfile = CurrentSchema.VoiceProfile

public typealias VoiceEnrollmentSet = CurrentSchema.VoiceEnrollmentSet
