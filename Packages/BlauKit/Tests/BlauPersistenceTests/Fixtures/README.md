# BlauPersistence fixtures

## `SchemaV1/Blau.store`

A synced store written by `SchemaV1` (version 1.0.0) exactly as a v1 build of
the app writes it: SwiftData, configuration `Blau`, CloudKit off. It is the
starting point of the v1 → v2 migration tests (`Migration/MigrationV1toV2Tests.swift`).

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

Add a fixture for each schema version that ships (`SchemaV2/Blau.store` when
v3 arrives), so every migration stage is tested from a real store.
