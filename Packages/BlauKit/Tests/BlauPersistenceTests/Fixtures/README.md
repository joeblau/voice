# BlauPersistence fixtures

## `SchemaV1/Blau.store`

A synced store written by `SchemaV1` (version 1.0.0) exactly as a v1 build of
the app writes it: SwiftData, configuration `Blau`, CloudKit off. It is the
starting point of the v1 → v2 migration tests (`Migration/MigrationV1toV2Tests.swift`),
which open it with the current schema, so it goes through every later stage
too.

It holds two conversations (one ended with two topics and four utterances,
including a topicless system utterance; one still open with a non-final
utterance) and a voiceprint with one three-clip enrollment set. The exact
values are in `Migration/SchemaV1Fixture.swift`.

The file is checkpointed into a single SQLite file (no `-wal` or `-shm`).
Tests always copy it to a temporary directory before opening it, because
opening a store migrates it in place.

`SchemaV1FixtureTests` checks that the entity version hashes recorded in the
file still match `SchemaV1`. If that test fails, `SchemaV1` was edited in
place: revert the edit and make the change in a new schema version instead
(docs/data-model.md). Regenerate the file only when the fixture data itself
changes:

```sh
cd Packages/BlauKit
BLAU_REGENERATE_FIXTURES=1 swift test --filter SchemaV1FixtureGenerator
```

## `SchemaV2/Blau.store`

A synced store written by `SchemaV2` (version 2.0.0) the same way, the
starting point of the v2 → v3 migration tests
(`Migration/MigrationV2toV3Tests.swift`, issue #160).

It holds the v1 fixture's conversations, topics, utterances and voiceprint
(so `expectFixtureData` checks them after the migration too), plus one of
each memory model with every optional field set: a collection document with
one practiced item, a note, an entity with an alias, an invalidated fact
about it and the profile block. The exact values are in
`Migration/SchemaV2Fixture.swift`.

`SchemaV2FixtureTests` checks the recorded hashes against `SchemaV2`, like
the v1 fixture. Regenerate it only when the fixture data changes:

```sh
cd Packages/BlauKit
BLAU_REGENERATE_FIXTURES=1 swift test --filter SchemaV2FixtureGenerator
```

Add a fixture for each schema version that ships (`SchemaV3/Blau.store` when
v4 arrives), so every migration stage is tested from a real store.
