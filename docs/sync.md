# iCloud sync

Blau keeps all text (conversations, topics, utterances, memory) and the voiceprint in
SwiftData and mirrors it to the **private database** of the CloudKit container
`iCloud.com.joeblau.blau` (issue #20). There is no Blau server: the data
lives on the user's devices and in their own iCloud account. The model and
CloudKit's schema rules are in [data-model.md](data-model.md); shipping a
schema to production is in [release.md](release.md).

## Stores

| Store | File | `cloudKitDatabase` | Contents |
| ----- | ---- | ------------------ | -------- |
| Synced | `Application Support/Blau/Blau.store` | `.private("iCloud.com.joeblau.blau")`, or `.none` when iCloud is unavailable | `BlauModelContainer.schema` (`CurrentSchema`, migrated by `BlauMigrationPlan`) |
| Derived | `Application Support/Blau/Derived/BlauDerived.store` | always `.none` | `DerivedSchemaV1`: `HistoryCursor` and future rebuildable caches |

- The derived store is a **separate `ModelContainer`**, not a second
  configuration in the synced container. That keeps the synced schema exactly
  the CloudKit schema (so `initializeCloudKitSchema()` and the CloudKit
  compatibility tests only see synced models), and lets derived data change
  freely: if it can't be opened it is deleted and recreated
  (`DerivedStore.open(at:)`). Its directory is excluded from device backups.
- Search indexes and embeddings (#62) are rebuildable too but live in their
  own SQLite files next to the derived store.
- The entitlements (`com.apple.developer.icloud-container-identifiers`,
  `icloud-services: CloudKit`, `aps-environment`) and the `remote-notification`
  background mode are declared in `project.yml`.

## Sync modes

`PersistenceController` (BlauPersistence) owns the stores. At launch it asks
`CKContainer.accountStatus()` (capped at 3 s by
`PersistenceOptions.accountStatusTimeout`; a slow answer is dropped, not
awaited) and opens the synced store in one of these modes:

| Mode | When | Settings shows |
| ---- | ---- | -------------- |
| `.cloudKit` | Signed in, iCloud on for Blau (`.available`) | On / Syncing… / Paused (with the CloudKit error) |
| `.localOnly(.account(status))` | No account, restricted, needs attention, or unknown | Off, with the reason and "Open Settings" when the user can fix it |
| `.localOnly(.notEntitled)` | Unsigned build (`CODE_SIGNING_ALLOWED=NO`: CI, `make test`) | Off: not signed for iCloud |
| `.localOnly(.forced)` | `-BlauStore local` / `BLAU_STORE=local` | Off: turned off for development |
| `.localOnly(.cloudKitFailed)` | CloudKit failed to open the store | Off: retries next launch |
| `.inMemory(.requested)` | `-BlauStore memory`, `BLAU_STORE=memory`, hosted unit tests, previews | Not saving |
| `.inMemory(.storeFailed)` | The store file can't be opened at all | Not saving (the file is left untouched) |

**Signed out never loses data.** CloudKit and local-only modes open the
**same file**, so everything written signed out is still there, and
SwiftData's persistent history (always on) lets mirroring export it the next
time the store opens with CloudKit. When the account changes while Blau is
running (`CKAccountChanged`, or a different status when the app becomes
active), the controller saves the main context and reopens the store in the
new mode. Only a definite answer turns sync off: when the store is already
mirroring, a status query that times out or fails (`.couldNotDetermine`, for
example a slow `cloudd` or an XPC error) is recorded for Settings but keeps
the CloudKit store open. At launch, "unknown" still starts local-only and
`run()` asks again without the launch deadline. `PersistenceGate` rebuilds the view tree for the new container
(`.id(generation)`) because models fetched from the old container are invalid
once it is released. Services that hold the container (the `ModelActor`
writer from #21, the indexer from #63) must also be recreated when
`PersistenceController.generation` changes.

Unsigned builds have no iCloud entitlement, and `CKContainer(identifier:)`
raises an exception in an app without it. `project.yml` sets the Info.plist key
`BlauCloudKitEnabled` to `$(CODE_SIGNING_ALLOWED)`, and Blau only touches
CloudKit when it is `YES`.

> Core Data purges mirrored data from the device when the iCloud account
> changes (privacy: one account's data never mixes with another's). Data that
> was exported is safe in iCloud and comes back on sign-in; Blau switches to
> local-only as soon as it sees the change to keep the window small.

## Watching incoming changes

- `CloudSyncEvent.events()` follows
  `NSPersistentCloudKitContainer.eventChangedNotification` (setup, import,
  export; start, end, error). `CloudSyncActivity` folds them into the
  Settings status: syncing, last sync, and the last error (quota full,
  network, account).
- `RemoteChangeMonitor` follows `NSPersistentStoreRemoteChange` for the synced
  store's URL.
- `PersistentHistoryTracker` reads SwiftData history
  (`ModelContext.fetchHistory`) after a per-consumer cursor stored in the
  derived store, and reports a `StoreChangeSet`: inserted, updated and deleted
  `PersistentIdentifier`s per entity, and how many transactions CloudKit
  imported (author `NSCloudKitMirroringDelegate.import`). Write from the app
  with `ModelContext.author = HistoryAuthor.app`.
- The controller reads history on every remote change, after each successful
  import and when the app becomes active, and publishes non-empty change sets
  through `storeChanges()`. Other consumers (the memory indexer, #63) create
  their own tracker with their own consumer name and
  `startPosition: .beginning`.
- History is never deleted: CloudKit mirroring needs it to export. If a
  cursor's token has expired (SwiftData throws
  `SwiftDataError.historyTokenExpired`), the tracker moves the cursor to the
  latest transaction, returns `historyWasReset` and consumers rebuild.

## CloudKit development schema

SwiftData creates CloudKit record types lazily, when a record is first
exported, so fields that were never written are missing from the schema you
deploy. DEBUG builds therefore run `initializeCloudKitSchema()` through an
`NSPersistentCloudKitContainer` opened on the same store file, built from the
Core Data model SwiftData generates (`CoreDataCloudKitSchemaInitializer`, the
approach in Apple's "Syncing model data across a person's devices"). It runs:

- only in DEBUG builds, only in `.cloudKit` mode (it needs an account);
- once per schema shape: `CloudKitSchemaInitializationGate` stores a SHA-256
  of the model's entity version hashes in `UserDefaults` and runs again only
  when the model changes;
- on every launch with `-BlauInitializeCloudKitSchema`.

A failure is logged (category `data`) and retried next launch; it never blocks
opening the store. Release builds never run it.

## Logs

Everything logs to subsystem `com.joeblau.blau`, category `data` (the
`BlauTelemetry` logger `Log.data`):

```sh
log stream --predicate 'subsystem == "com.joeblau.blau" && category == "data"'
```

Core Data's own CloudKit logging is louder still: add
`-com.apple.CoreData.CloudKitDebug 1` to the scheme's launch arguments.

## Testing

Hermetic tests (no iCloud account, no network) cover everything except the
transfer itself:

- `Packages/BlauKit/Tests/BlauPersistenceTests`: `SyncModeTests`,
  `PersistenceBootstrapTests`, `HistoryTrackingTests`, `SyncStatusTests` and
  `PersistenceControllerTests` (mode selection, signed-in ↔ signed-out
  switches keeping data, fallbacks, history cursors, schema-initialization
  gating). They open the "CloudKit" configuration's file with mirroring off,
  since the macOS test runner has no iCloud entitlement.
- `BlauTests/PersistenceWiringTests`: the built app's Info.plist and options.
- `BlauUITests/ICloudSyncUITests`: the app launches without iCloud and
  Settings explains it. Run it against a signed simulator build to exercise
  the real `CKContainer.accountStatus()` path:

  ```sh
  xcodebuild test -scheme Blau -testPlan Blau -only-testing:BlauUITests \
    -destination 'id=<simulator udid>' -derivedDataPath .build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
  ```

Real sync between devices needs two devices signed in to the same iCloud
account; follow the manual test plan below.

## Manual test plan: device A → device B

Prerequisites: two iPhones (or an iPhone and a simulator signed in to an Apple
Account) on iOS 26 or later, **signed in to the same iCloud account** with
iCloud Drive on; a Debug build signed with the team that owns
`iCloud.com.joeblau.blau` installed on both (or the same TestFlight build on
both, which uses the Production environment). Debug builds use the CloudKit
Development environment; never mix a Debug device with a TestFlight device.

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | Fresh install on A and B. Open Settings → iCloud on both. | "iCloud Sync: On", "iCloud Account: Signed in". | pending |
| 2 | In the CloudKit Console (Development), check `iCloud.com.joeblau.blau` → Schema. | Record types `CD_Conversation`, `CD_Topic`, `CD_Utterance`, `CD_VoiceProfile`, `CD_VoiceEnrollmentSet`, `CD_Document`, `CD_CollectionItem`, `CD_MemoryEntity`, `CD_Fact`, `CD_ProfileBlock` exist (DEBUG schema initialization). | pending |
| 3 | On A, record a short conversation (until the conversation UI exists, use a DEBUG build that inserts a `Conversation` with a topic and two utterances). | A's Settings shows "Syncing…", then "On" with "Last Synced: now". | pending |
| 4 | Keep B in the foreground and wait up to 1 minute. | The conversation, its topic and utterances appear on B with the same text, order and topic title. | pending |
| 5 | Background B, edit the topic title on A, then bring B to the foreground. | B shows the new title (silent push or the foreground refresh). | pending |
| 6 | Delete the conversation on A. | It disappears on B, with its topics and utterances. | pending |
| 7 | On B, enroll the voiceprint; check A. | A has the `VoiceProfile` (voice ID works without re-enrolling). In the CloudKit Console the voiceprint vector fields are encrypted. | pending |
| 8 | Airplane mode on A; create a conversation; turn airplane mode off. | A's Settings shows "Paused" (no connection) while offline, then the conversation reaches B. | pending |
| 9 | On B, sign out of iCloud (Settings → Apple Account → Sign Out, keep a copy of data if asked), reopen Blau. | Blau keeps working; Settings: "Off: You're not signed in to iCloud…" with "Open Settings". New conversations save locally. | pending |
| 10 | Create a conversation on B while signed out, then sign back in to the same account and reopen Blau. | Settings returns to "On"; the conversation from step 10 reaches A. | pending |
| 11 | Fill iCloud storage (or use an account that is full) and create a conversation. | Settings shows "Paused: Your iCloud storage is full…"; the data stays on the device. | pending |

Record the device models, iOS versions, build number and results in the PR or
release notes that ran the plan.
