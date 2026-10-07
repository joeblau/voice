# Release

The TestFlight pipeline itself is #83. This page holds the checks that must
pass before **every** TestFlight or App Store build, starting with the
CloudKit schema.

## Why the schema needs a deploy

Blau syncs through the private database of `iCloud.com.joeblau.blau`
([sync.md](sync.md)). CloudKit has two environments:

| Build | CloudKit environment |
| ----- | -------------------- |
| Debug, run from Xcode | Development |
| TestFlight, App Store | **Production** |

The Development schema grows on its own: DEBUG builds run
`initializeCloudKitSchema()` whenever the model changes (and SwiftData adds
record types as it exports records). The Production schema **never** changes
by itself. A TestFlight build whose model has record types or fields that
aren't deployed to Production fails to export them: data stays on the device
and the Settings status shows "Paused". So deploy the schema before you upload
a build, not after.

Production is additive only. Once deployed, record types and fields can't be
deleted, renamed or retyped, and a field's encryption can't be turned on or
off. That is why every model change goes through a new `VersionedSchema`
([data-model.md](data-model.md#versioning-and-migration)).

## Production schema deploy checklist

Run this before every TestFlight upload. Copy it into the release PR or issue
and tick it there.

**1. Is there anything to deploy?**

- [ ] Compare `BlauMigrationPlan.schemas` (and `CurrentSchema`) with the last
      release tag: `git diff <last-release-tag> -- Packages/BlauKit/Sources/BlauPersistence/Schema`.
      No change → skip to step 5 (still do the reset check in step 4 once per
      release).
- [ ] The change is additive only: a new `SchemaV<n>` with new models, new
      optional or defaulted properties, or new optional relationships with
      inverses. No edits to a shipped version.
- [ ] `swift test` passes in `Packages/BlauKit` (the CloudKit compatibility
      tests check every schema in the plan).

**2. Bring the Development schema up to date**

- [ ] On a device or simulator signed in to a **developer** iCloud account,
      run a Debug build of the release commit with the launch argument
      `-BlauInitializeCloudKitSchema` (Scheme → Run → Arguments).
- [ ] Check the log (`subsystem == "com.joeblau.blau" && category == "data"`)
      for `Initialized the CloudKit development schema`. An
      `initializeCloudKitSchema failed` line means the schema is not complete:
      fix it before going on.
- [ ] Optionally create one of each model in the app and confirm it syncs to a
      second Debug device.

**3. Review the Development schema in the CloudKit Console**

- [ ] [CloudKit Console](https://icloud.developer.apple.com) → `iCloud.com.joeblau.blau`
      → Development → Schema → Record Types.
- [ ] Every model has a record type (`CD_<Entity>`): `CD_Conversation`,
      `CD_Topic`, `CD_Utterance`, `CD_VoiceProfile`, `CD_VoiceEnrollmentSet`
      (v1) and `CD_Document`, `CD_CollectionItem`, `CD_MemoryEntity`,
      `CD_Fact`, `CD_ProfileBlock` (v2), with a `CD_<property>` field for
      every new property.
- [ ] Voiceprint vectors (`VoiceProfile.centroid`, `VoiceEnrollmentSet.embeddings`)
      are encrypted fields.
- [ ] No field you didn't expect (a typo deployed to Production is forever).
- [ ] Indexes: Core Data mirroring needs none beyond the defaults.

**4. Deploy to Production**

- [ ] Development → **Deploy Schema Changes…** Review the diff the console
      shows: it must only add record types, fields or indexes. Deploy.
- [ ] Production → Schema → Record Types now shows the new types and fields.
- [ ] Do **not** "Reset Development Environment" after deploying unless you
      mean to: it deletes all development data and must be followed by step 2
      again.

**5. Verify the build against Production**

- [ ] The archive is signed with the distribution profile; Xcode sets
      `aps-environment` to `production` when it exports for App Store
      Connect. Check with
      `codesign -d --entitlements - Blau.app` in the exported IPA: it must
      contain `iCloud.com.joeblau.blau`, `CloudKit` and
      `aps-environment = production`.
- [ ] Release builds never run `initializeCloudKitSchema()`
      (`SchemaInitializationPolicy.never`, covered by `PersistenceOptionsTests`).
- [ ] Install the TestFlight build on two devices on the same iCloud account
      and run steps 1, 3, 4 and 9 of the
      [manual sync test plan](sync.md#manual-test-plan-device-a--device-b).
      TestFlight uses Production, so this is the check that the deploy worked.
- [ ] If the build changed the schema, also install it **over** the previous
      TestFlight build on a device with existing data: the migration runs and
      the old conversations are still there and still sync.

## Release history

| Version (build) | Schema version | Schema deployed to Production | Sync test plan run by / result |
| --------------- | -------------- | ----------------------------- | ------------------------------ |
| 0.1.0 (first TestFlight) | 2.0.0 | pending | pending |
