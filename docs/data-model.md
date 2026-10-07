# Data model

Blau keeps all text (conversations, topics, utterances) and the user's
voiceprint in SwiftData. The store is mirrored to the user's private CloudKit
database in `iCloud.com.joeblau.blau`, so it follows CloudKit's schema rules.
Derived data such as embeddings and search indexes stays local and is
rebuilt from these models (issue #7).

The models live in `Packages/BlauKit/Sources/BlauPersistence/Schema`.

## Schema v1

`SchemaV1` (version `1.0.0`) defines five flat models. Code outside
BlauPersistence uses the aliases in `CurrentSchema.swift`, which always point
at the newest version:

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

## Versioning and migration

`BlauMigrationPlan` lists every shipped schema, oldest first, and has existed
since v1 so the first migration is just a new entry.
`BlauModelContainer.make(configurations:)`, `makeLocal(url:)` and
`makeInMemory()` always open stores with the current schema and the plan.
The CloudKit-backed configuration the app uses is set up in #20.

Once a schema version is deployed to the CloudKit production environment, the
CloudKit schema is **additive only**: you can add record types and fields, but
never rename, retype or delete them. To change the model:

1. Copy the models into a new `SchemaV2` with `versionIdentifier` `2.0.0`.
   Never edit a version that has shipped.
2. Make only additive changes (new models, new optional or defaulted
   properties, new optional relationships with inverses).
3. Append `SchemaV2.self` to `BlauMigrationPlan.schemas` and add a
   `.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)` stage.
4. Point `CurrentSchema` at `SchemaV2`.
5. Run `swift test` in `Packages/BlauKit`: the CloudKit compatibility tests
   check every version in the plan.
6. Deploy the new schema to production in the CloudKit console before
   shipping the build.

The memory models (Document, CollectionItem, Entity, Fact, ProfileBlock) arrive
in v2 (#61).
