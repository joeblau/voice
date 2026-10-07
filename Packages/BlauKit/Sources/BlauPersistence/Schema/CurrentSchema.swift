// The model types the rest of the app uses. They always point at the latest
// schema version; when a new version ships, move these aliases to it and keep
// the older versions untouched for migration.

/// The schema version the app reads and writes.
public typealias CurrentSchema = SchemaV2

public typealias Conversation = CurrentSchema.Conversation

public typealias Topic = CurrentSchema.Topic

/// The persisted utterance. Named `StoredUtterance` rather than `Utterance`
/// so it never collides with the pipeline's `BlauCore.Utterance` value type.
public typealias StoredUtterance = CurrentSchema.Utterance

public typealias VoiceProfile = CurrentSchema.VoiceProfile

public typealias VoiceEnrollmentSet = CurrentSchema.VoiceEnrollmentSet

// MARK: - Memory (v2)

/// A knowledge-base page. The entity and CloudKit record type are named
/// `Document`; the Swift alias is `MemoryDocument` so an unqualified
/// `Document` never competes with a framework type of that name.
public typealias MemoryDocument = CurrentSchema.Document

public typealias CollectionItem = CurrentSchema.CollectionItem

public typealias MemoryEntity = CurrentSchema.MemoryEntity

public typealias Fact = CurrentSchema.Fact

public typealias ProfileBlock = CurrentSchema.ProfileBlock
