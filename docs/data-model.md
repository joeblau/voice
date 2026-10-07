# Data model

Blau keeps all text (conversations, topics, utterances, and the long-term
memory: knowledge-base documents, entities, facts and the profile block) and
the user's voiceprint in SwiftData. The store is mirrored to the user's private CloudKit
database in `iCloud.com.joeblau.blau`, so it follows CloudKit's schema rules.
Derived data such as embeddings and search indexes stays local and is
rebuilt from these models (issue #7).

The models live in `Packages/BlauKit/Sources/BlauPersistence/Schema`.

The current schema is **v2** (`SchemaV2`, version `2.0.0`): the five v1
models below, unchanged, plus five memory models ([Schema v2](#schema-v2-memory)).
Code outside BlauPersistence uses the aliases in `CurrentSchema.swift`, which
always point at the newest version.

## Schema v1

`SchemaV1` (version `1.0.0`) defines five flat models. `SchemaV2` carries them
over unchanged (`SchemaV2.Conversation` and so on), and the aliases point
there:

| Model (CloudKit record type)  | Swift alias          |
| ----------------------------- | -------------------- |
| `Conversation`                | `Conversation`       |
| `Topic`                       | `Topic`              |
| `Utterance`                   | `StoredUtterance`    |
| `VoiceProfile`                | `VoiceProfile`       |
| `VoiceEnrollmentSet`          | `VoiceEnrollmentSet` |

The persisted utterance's Swift alias is `StoredUtterance` because
`BlauCore.Utterance` is the pipeline's value type, and an unqualified
`Utterance` would be ambiguous in any file that imports both modules.
`StoredUtterance(_:source:conversation:topic:asrConfidence:voiceScore:)`
converts one into the other and keeps its `id`. The entity and CloudKit
record type are still named `Utterance`.

```mermaid
erDiagram
    Conversation ||--o{ Topic : "topics (cascade)"
    Conversation ||--o{ Utterance : "utterances (cascade)"
    Topic |o--o{ Utterance : "utterances (nullify)"
    VoiceProfile ||--o{ VoiceEnrollmentSet : "enrollmentSets (cascade)"

    Conversation {
        UUID id
        Date startedAt
        Date endedAt "optional"
        String title "optional"
    }
    Topic {
        UUID id
        Date startedAt
        Date endedAt "optional"
        String title "default New topic"
        Bool titleIsProvisional "default true"
        String summary "optional"
        Int ordinal "default 0"
        Int colorSeed "derived from id"
    }
    Utterance {
        UUID id
        String roleRaw "user, agent, system"
        String text
        Date startedAt
        Date endedAt "optional"
        Double asrConfidence "optional"
        Double voiceScore "optional"
        Bool isFinal
        String sourceRaw "parakeet, speechanalyzer, grok"
    }
    VoiceProfile {
        UUID id
        String name
        String embeddingModelVersion
        Data centroid "Float32 x 256, encrypted"
        Date createdAt
        Date updatedAt
    }
    VoiceEnrollmentSet {
        String deviceModel
        Data embeddings "Float32 x 256 x clipCount, encrypted"
        Int clipCount
        Date createdAt
    }
```

Every to-one side of a relationship (`Topic.conversation`,
`Utterance.conversation`, `Utterance.topic`, `VoiceEnrollmentSet.profile`) is
optional and uses `.nullify`.

### Delete rules

| Deleting            | Does                                                                 |
| ------------------- | -------------------------------------------------------------------- |
| a `Conversation`    | deletes its topics and utterances                                    |
| a `Topic`           | keeps its utterances; they stay in the conversation with no topic    |
| a `StoredUtterance` | removes it from its conversation and topic                           |
| a `VoiceProfile`    | deletes its enrollment sets                                          |

### Field notes

- **Identity.** Every model has `id: UUID = UUID()` (except
  `VoiceEnrollmentSet`, which is only reached through its profile). It is not
  `.unique` because CloudKit can't enforce uniqueness. UUIDs are random, so a
  duplicate only appears if the same logical record is created twice (for
  example on two devices); code that needs uniqueness de-duplicates on read.
- **Enums as strings.** `roleRaw` and `sourceRaw` store `UtteranceRole` and
  `TranscriptSource` raw values. Read them through `role` and `source`, which
  return `nil` for a value written by a newer app version instead of failing.
- **Ordering.** CloudKit doesn't support ordered relationships, so
  relationship arrays come back in no particular order. Use
  `Conversation.orderedTopics` (by `ordinal`, then `startedAt`) and
  `orderedUtterances` (by `startedAt`), or a `FetchDescriptor` with a sort.
- **Topic color.** `colorSeed` defaults to the first two bytes of `id`, so a
  topic has the same accent color on every device.
- **Voiceprint.** The voiceprint syncs through CloudKit (product decision 2 in
  issue #1), so enrolling once works on every device. Vectors are packed as
  little-endian Float32 with `PackedFloat32` (256 values per WeSpeaker
  embedding) and marked `.allowsCloudEncryption`, which stores them in
  CloudKit's end-to-end encrypted fields. Encryption can't be turned on or off
  for a field once the schema is in production, which is why it is decided
  in v1. If the user's iCloud Keychain is reset, the encrypted vectors are
  unreadable and the user re-enrolls.
- **Timestamps.** Initializers take every date explicitly; callers get them
  from `BlauClock` (see docs/architecture.md, rule 5). The `Date.distantPast`
  declaration defaults exist only to satisfy CloudKit.

## Schema v2: memory

`SchemaV2` (version `2.0.0`, issue #61) adds the synced, text-only models for
long-term memory (epic #9). Embeddings and the FTS index built from them are
local and rebuildable ([memory-index.md](memory-index.md), #62), never synced.

| Model (CloudKit record type) | Swift alias      | Holds                                                                 |
| ---------------------------- | ---------------- | --------------------------------------------------------------------- |
| `Document`                   | `MemoryDocument` | A knowledge-base page: note, company, profile or collection (#65)     |
| `CollectionItem`             | `CollectionItem` | One prompt of a collection (e.g. a YC question) and its practice record (#69) |
| `MemoryEntity`               | `MemoryEntity`   | A person, organization, place, product, project... the user talks about |
| `Fact`                       | `Fact`           | An add-only, validity-dated statement about the user or an entity (#66) |
| `ProfileBlock`               | `ProfileBlock`   | The pinned summary of the user sent with every session (#67)          |

The Swift alias for `Document` is `MemoryDocument` (the entity and record type
are still `Document`) so an unqualified `Document` never competes with a
framework type of that name, the same reason `Utterance` is `StoredUtterance`.
The issue's `Entity` is named `MemoryEntity` everywhere, so it never reads as
a Core Data or SwiftData entity description.

```mermaid
erDiagram
    Document ||--o{ CollectionItem : "collectionItems (cascade)"
    MemoryEntity |o--o{ Fact : "facts (cascade)"

    Document {
        UUID id
        String kindRaw "note, company, profile, collection"
        String title
        String body
        Date createdAt
        Date updatedAt
        String contentHash "SHA-256 hex of title and body"
    }
    CollectionItem {
        UUID id
        Int ordinal
        String prompt
        String referenceAnswer "optional"
        Date createdAt
        Date lastPracticedAt "optional"
        Int practiceCount "default 0"
        Double score "optional, 0...1"
    }
    MemoryEntity {
        UUID id
        String name
        String typeRaw "person, organization, place, product, project, event, concept, other"
        String aliases "JSON array of strings"
        String summary "optional"
        Date createdAt
        Date updatedAt
    }
    Fact {
        UUID id
        String predicate
        String objectText
        UUID sourceUtteranceID "optional"
        Date validFrom
        Date invalidatedAt "optional"
        Double confidence "default 1, 0...1"
        String originRaw "extracted, user"
        Date createdAt
    }
    ProfileBlock {
        UUID id
        String key "default user"
        String text "about 1,500 tokens"
        Date updatedAt
    }
```

| Deleting            | Does                                                                   |
| ------------------- | ---------------------------------------------------------------------- |
| a `Document`        | deletes its collection items                                           |
| a `CollectionItem`  | removes it from its document                                           |
| a `MemoryEntity`    | deletes its facts (statements about it mean nothing without it); facts about the user (no subject) stay |
| a `Fact`            | removes it from its entity                                             |

`CollectionItem.document` and `Fact.subject` are optional and use `.nullify`,
like every to-one side in v1.

### Memory field notes

- **Content hash.** `Document.title`, `body`, `updatedAt` and `contentHash`
  are `private(set)`: change the text with `update(title:body:at:)`, which
  refreshes the hash and stamps `updatedAt` only when the text actually
  changed. The hash is SHA-256 over the title's UTF-8 length, the title and
  the body, as 64 lowercase hex digits; the indexer (#63) compares it with the
  hash it last indexed, so a document synced from another device is
  re-embedded only if its text changed. The hash format is pinned by a test:
  changing it re-indexes every document.
- **Facts are add-only and validity-dated** (Zep / Graphiti, issue #1). A fact
  is true over `[validFrom, invalidatedAt)`. When something stops being true,
  `invalidate(at:)` closes the old fact and the extractor adds a new one, so
  "where did I work in March" still has an answer. Invalidating twice keeps
  the earlier date, so the same correction replayed on two devices converges.
  `createdAt` is when the fact was recorded, which can be later than
  `validFrom`. Current facts are `invalidatedAt == nil`, which works in a
  `#Predicate`.
- **A fact with no subject is about the user.** `sourceUtteranceID` is a
  plain id rather than a relationship, so deleting a conversation keeps what
  was learned from it.
- **Origin.** `originRaw` is `extracted` (inferred by a model, #66) or `user`
  (entered, confirmed or explicitly asked to be remembered by the user, which
  outranks a contradicting extracted fact). `confidence` is clamped to `0...1`.
- **Aliases** are a JSON array in a string (`aliases`), because CloudKit has
  no list type for SwiftData to map `[String]` to. Use `aliasNames`, which
  trims, drops blanks, the entity's own name and case- or diacritic-insensitive
  repeats. `matches(_:)` compares a name with the entity's name and aliases the
  same way.
- **No uniqueness, so de-duplicate on read.** Two devices can each create the
  `Acme` entity or the `user` profile block while offline. `ProfileBlock.latest(key:)`
  fetches the most recently updated block for a key (ties broken by `id`, so
  every device picks the same one); consolidation (#67) and extraction (#66)
  merge the extras.
- **Profile budget.** `ProfileBlock.tokenBudget` is 1,500 tokens;
  `approximateTokenCount` (UTF-8 bytes / 4) is a cheap check against it.
- **Not encrypted.** The memory fields are not `.allowsCloudEncryption`. They
  hold text derived from the utterances, which are not encrypted either, and
  the choice can't change once deployed. Users with Advanced Data Protection
  get end-to-end encryption for all of it.
- **Unknown raw values** (`kindRaw`, `typeRaw`, `originRaw`) read as `nil`
  through `kind`, `type` and `origin`, like the v1 enums.

## CloudKit rules

CloudKit mirroring rejects a schema that breaks any of these rules, but
SwiftData only reports it when a CloudKit-backed container loads, which needs
an iCloud account and entitlements. `CloudKitCompatibility.violations(in:)`
runs the same checks on the Core Data model SwiftData generates, and
`CloudKitCompatibilityTests` fails if any schema in `BlauMigrationPlan` breaks
one:

| Rule                                                        | Violation kind               |
| ----------------------------------------------------------- | ---------------------------- |
| Every attribute is optional or has a default value          | `attributeWithoutDefault`    |
| No `@Attribute(.unique)` and no `#Unique`                   | `uniquenessConstraint`       |
| Every relationship is optional                              | `requiredRelationship`       |
| Every relationship has an inverse                           | `relationshipWithoutInverse` |
| No `.deny` delete rule                                      | `denyDeleteRule`             |
| No ordered relationships                                    | `orderedRelationship`        |
| No `@Model` inheritance (CloudKit cast crashes on iOS 26.x) | `inheritance`                |

Each inverse is declared once, on the to-many side, with
`@Relationship(inverse:)`. SwiftData links the other side, and the Core Data
check confirms both ends have an inverse.

Production is also **additive only** across versions.
`CloudKitCompatibility.breakingChanges(in: BlauMigrationPlan.self)` compares
each version with the next on the generated Core Data models, and the tests
fail on any of these:

| Change from one version to the next                                  | Violation kind      |
| -------------------------------------------------------------------- | ------------------- |
| An entity disappears                                                 | `removedEntity`     |
| A property disappears (including a rename)                           | `removedProperty`   |
| A property's type, optionality, destination, inverse, cardinality or ordering changes (its Core Data version hash) | `changedProperty` |
| An attribute's `.allowsCloudEncryption` changes                      | `changedEncryption` |

A delete rule may change: it is local behavior, not part of the CloudKit
schema.

## Writing from the pipeline: `ConversationStore`

The live pipeline writes through one actor, `ConversationStore`
(`Sources/BlauPersistence/ConversationStore.swift`). The UI reads with
`@Query` on the main context and never writes pipeline data itself.

| Call                                      | Does                                                                                         | Saves                 |
| ----------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------- |
| `startConversation(id:at:title:)`         | Inserts a conversation, or reopens an existing one with that id (relaunch); ends any other active one | at once               |
| `appendPartial(utteranceID:text:)`        | Keeps the latest streaming ASR hypothesis **in memory only**                                 | never                 |
| `discardPartial(utteranceID:)`            | Forgets a partial (for example speech the voice ID gate rejected)                            | never                 |
| `commitUtterance(_:source:asrConfidence:voiceScore:)` | Stores a final `BlauCore.Utterance` in its conversation and the topic covering its `startedAt` (the open topic, or for a late commit the topic current then, including the last topic of a conversation that has ended); re-committing the same id (second pass) updates it, even after the conversation ended or the app relaunched; blank text is skipped | batched |
| `openTopic(at:title:)`                    | Opens the next topic; closes the previous one at `at` and moves its utterances from `at` on, plus topicless ones (before the first topic or after `closeTopic`) from `at` on | batched |
| `closeTopic(_:title:summary:at:)`         | Closes a topic with the labeler's final title (non-provisional) and summary                  | batched               |
| `retitle(_:to:isProvisional:)`            | Renames a topic (provisional guess or manual edit)                                           | batched               |
| `endConversation(_:at:)`                  | Closes the open topic and the conversation, drops partials                                   | at once               |
| `flush()`                                 | Saves whatever is waiting. Call it when the app goes to the background                       | at once               |

**Partials are never persisted.** Only committed utterances are, always with
`isFinal == true`.

**No duplicate utterances.** CloudKit forbids `.unique`, so the store
de-duplicates by utterance id itself. For the active conversation it keeps
every utterance in memory (seeded once from the stored rows when a
conversation is resumed), so commits there need no fetch. A commit to any
other conversation, such as the second ASR pass for the last utterance
landing after the user taps stop, fetches the id (`fetchLimit` 1, including
unsaved inserts) and updates that row instead of inserting.

**Batched saves.** Every save is a SQLite transaction and, with CloudKit on,
an export, so `ConversationStoreSavePolicy.coalesced` (the default) saves a
change at most 2 s after it was made, or at once when 500 changes are
waiting. `.immediate` saves every change; it exists for comparison and is
several times slower per utterance (see docs/performance.md). Each save is a
`db.save` signpost interval and is counted in `statistics`.

**Never on the main thread.** The issue sketched `@ModelActor actor
ConversationStore`, but the macro's `DefaultSerialModelExecutor` runs a job
on whichever thread enqueues it. Measured with the iOS 27 / macOS 27 SDKs:
every call into such an actor from `@MainActor` code runs, and saves, on the
main thread. `ConversationStore` therefore conforms to `ModelActor` by hand
and uses `DispatchQueueModelExecutor`, which runs every job on a private
serial queue (at the calling task's priority, never below `.utility`) and
creates its `ModelContext` there with autosave off. Each save also checks
the thread: a main-thread save is counted in
`statistics.mainThreadSaveCount`, logged as a fault and stops a debug build
at an assertion. Use `DispatchQueueModelExecutor` for any other model actor
(the memory indexer, for example).

**Cost grows with conversation size.** Linking an utterance to its
conversation makes SwiftData update the inverse to-many
(`Conversation.utterances`), which costs more as the conversation grows.
A 2-hour session (1,000 to 2,000 utterances) is cheap; one 10,000-utterance
conversation is roughly twice as expensive per utterance as ten of 1,000.

## Versioning and migration

`BlauMigrationPlan` lists every shipped schema, oldest first, and has existed
since v1 so the first migration is just a new entry.
`BlauModelContainer.make(configurations:)`, `makeLocal(url:)` and
`makeInMemory()` always open stores with the current schema and the plan.
The app opens the CloudKit-backed store through `PersistenceController`; see
[sync.md](sync.md) for the sync modes and [release.md](release.md) for
deploying a schema to production.

Once a schema version is deployed to the CloudKit production environment, the
CloudKit schema is **additive only**: you can add record types and fields, but
never rename, retype or delete them. To change the model:

1. Copy the models into a new `SchemaV3` with `versionIdentifier` `3.0.0`
   (replace `SchemaV2` with `SchemaV3` in copies of the `SchemaV2+*.swift`
   files). Never edit a version that has shipped.
2. Make only additive changes (new models, new optional or defaulted
   properties, new optional relationships with inverses).
3. Append `SchemaV3.self` to `BlauMigrationPlan.schemas` and add a
   `.lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)` stage.
4. Point `CurrentSchema` at `SchemaV3`.
5. Check in a store written by the previous version (see
   `Tests/BlauPersistenceTests/Fixtures/README.md`) and add a migration test
   like `MigrationV1toV2Tests`.
6. Run `swift test` in `Packages/BlauKit`: the CloudKit compatibility tests
   check every version in the plan and that each step is additive.
7. Deploy the new schema to production in the CloudKit console before
   shipping the build (checklist in [release.md](release.md)).

### History

| Version | Issue | Change | Stage from the previous version |
| ------- | ----- | ------ | ------------------------------- |
| 1.0.0 | #19 | `Conversation`, `Topic`, `Utterance`, `VoiceProfile`, `VoiceEnrollmentSet` | (first version) |
| 2.0.0 | #61 | Adds `Document`, `CollectionItem`, `MemoryEntity`, `Fact`, `ProfileBlock`; v1 models unchanged | `BlauMigrationPlan.migrateV1toV2`, lightweight |

### Migration tests

`MigrationV1toV2Tests` start from `Fixtures/SchemaV1/Blau.store`, a store
written by `SchemaV1` through SwiftData exactly as a v1 build writes it
(configuration `Blau`, persistent history on), and checked in. They copy it to
a temporary directory and open it with the current schema and plan, through
`BlauModelContainer` and through `PersistenceBootstrap` (the app's launch
path), then check:

- every conversation, topic, utterance, voiceprint and enrollment set, every
  field and every relationship survived;
- the store's recorded entity hashes moved from v1's to v2's, and the memory
  tables start empty;
- memory models can be written to the migrated store, and it reopens without
  migrating again;
- the bootstrap stays on disk (no fallback to an in-memory store).

The same checks run on a v1 store written during the test.
`SchemaV1FixtureTests` fails if the checked-in store's hashes no longer match
`SchemaV1`, which means `SchemaV1` was edited in place.
