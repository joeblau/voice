# Release

Blau ships to testers through TestFlight. Every build comes from
[`.github/workflows/release.yml`](../.github/workflows/release.yml): push a
`v*` tag on `main` and the workflow archives that commit in Release, exports
an App Store Connect IPA, checks it, uploads it to TestFlight and publishes a
GitHub pre-release with notes built from the merged pull requests. Nothing is
built or signed on a laptop, and no build number is typed by hand.

This page covers how to cut a release, what the pipeline does, the one-time
setup it needs, and the checks that must pass before **every** build: the
CloudKit schema deploy and the privacy manifest.

## Cutting a release

1. **Pick the version.** `MARKETING_VERSION` in [`project.yml`](../project.yml)
   is the version testers see (`CFBundleShortVersionString`). For a new
   version, change it in a pull request and merge it. More builds of the same
   version need no change.
2. **Deploy the CloudKit schema** if the model changed: run the
   [Production schema deploy checklist](#production-schema-deploy-checklist)
   and set the `BLAU_CLOUDKIT_PRODUCTION_SCHEMA` variable to the deployed
   version. The workflow refuses to upload a build whose schema isn't
   recorded as deployed.
3. **Run the [privacy checklist](#privacy-manifest-and-labels)** if a
   dependency, a data type or a required-reason API changed.
4. **Tag the commit on `main` and push the tag:**

   ```sh
   git switch main && git pull
   git tag -a v0.1.0 -m "Blau 0.1.0"
   git push origin v0.1.0
   ```

   The tag must be `v<MARKETING_VERSION>`, optionally with a suffix for a
   further build of the same version: `v0.1.0-beta.2`, `v0.1.0-rc.1`.
5. **Approve the deployment** in the run (**Actions → Release**) if the
   `testflight` environment has required reviewers.
6. **Wait for processing.** The run ends once the upload is accepted; the
   build shows up in App Store Connect → TestFlight within 5 to 30 minutes
   and Apple emails the account holder. Paste the run's
   `what-to-test.txt` (artifact `release-notes-<attempt>`, also on the run's
   summary page) into the build's **What to Test**, then add the build to a
   tester group.
7. **Verify the build against Production** (step 5 of the schema checklist)
   and add a row to the [release history](#release-history).

A failed run uploads nothing. Fix the cause on `main` and push a new tag
(`v0.1.0-beta.2`), or re-run the failed job: see
[Build numbers](#version-and-build-numbers) for when a re-run is safe.

## What the pipeline does

`release.yml` has two jobs:

**`testflight`** (macOS, the same `xcode-27` runner and Xcode selection as
[CI](ci.md#runner-and-xcode)), in the `testflight` environment:

| Step | What it checks or does |
| ---- | ---------------------- |
| Upload or dry run | A tag push uploads. **Run workflow** is a dry run unless **Upload to TestFlight** is ticked. |
| Version and build number | `release.py version`: the tag must be `v<MARKETING_VERSION>[-suffix]`; build number = run number + `BLAU_BUILD_NUMBER_OFFSET`. |
| Check the release commit | Uploads need a `v*` tag on a commit that is on `main`. |
| CloudKit Production schema | `release.py schema`: the version of `CurrentSchema` must equal `BLAU_CLOUDKIT_PRODUCTION_SCHEMA`. A warning on dry runs. |
| Privacy manifests | `make check-privacy`. |
| Release notes | `release.py notes`: Markdown for GitHub, plain text for TestFlight; shown on the run's summary page. |
| Signing certificate | Optional; see [Signing](#signing). |
| Archive, export and upload | `make testflight` ([`scripts/release/testflight.sh`](../scripts/release/testflight.sh)): `xcodebuild archive` (Release, automatic signing through the API key, `DEVELOPMENT_TEAM` and `CURRENT_PROJECT_VERSION` on the command line), `check-privacy-manifest.py bundle` on the archive, `xcodebuild -exportArchive` with `method = app-store-connect`, [`verify-ipa`](#ipa-verification), then `xcrun altool --upload-package`. |

The job uploads the release notes, the verification report and a summary as
the `release-notes-<attempt>` artifact (90 days). It never uploads the IPA,
the archive or build logs: the repository is public.

**`github-release`** (Linux, after a successful upload from a tag) creates the
GitHub pre-release for the tag, titled `Blau <version> (<build>)`, with the
Markdown notes. It is a separate job so the only job with a write token never
sees the signing secrets. Re-running it updates the release instead of
failing. It finds the notes artifact through the `testflight` job's
`notes_artifact` output, never through its own attempt number, so "Re-run
failed jobs" still finds the artifact the reused `testflight` attempt
uploaded. Promote the release from pre-release when the build goes to the App
Store.

Both jobs run one at a time per tag and are never cancelled half way through
an upload.

## Version and build numbers

- **Marketing version** (`CFBundleShortVersionString`): `MARKETING_VERSION`
  in `project.yml`, one to three integers. The tag only has to agree with it,
  so the source tree always says which version it is.
- **Build number** (`CFBundleVersion`): `BLAU_BUILD_NUMBER_OFFSET` (default 0)
  plus the release workflow's run number, passed as `CURRENT_PROJECT_VERSION`
  to `xcodebuild archive`. A command-line setting applies to every target, so
  the widget extension's build number always matches the app's. The run
  number grows with every run of `release.yml`, so build numbers only go up,
  across versions too. `CURRENT_PROJECT_VERSION: "1"` in `project.yml` is
  what local and simulator builds use.
- The export sets `manageAppVersionAndBuildNumber = NO`, so Xcode never
  rewrites the number.

App Store Connect rejects a build number it has already seen for the
version. Set `BLAU_BUILD_NUMBER_OFFSET` above the highest build already
uploaded when:

- builds were uploaded by hand from Xcode before the pipeline existed, or
- the workflow file was renamed or recreated (its run number restarts at 1).

Re-running a job keeps its run number. Re-running a `testflight` job that
failed **before** "Archive, export and upload" finished is safe. If the
upload itself went through (the log shows altool's `UPLOAD SUCCEEDED`) and a
later step failed, don't re-run it; push a new tag instead.

## Release notes

`scripts/release/release.py notes` lists the first-parent commits of `main`
between the previous `v*` tag and the release commit. Pull requests are
squash-merged ([CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests)), so each
commit is `Title (#123)`; GitHub merge commits (`Merge pull request #123 …`)
are understood too, and a direct commit is listed with its hash. It writes:

- `release-notes.md`: the GitHub release body, with links to each pull request
  and a full-changelog compare link.
- `what-to-test.txt`: plain text for TestFlight's **What to Test**, cut to the
  field's 4,000 characters with a pointer to the GitHub release.

Preview the notes for the next release with `make release-notes`.

## Dry runs and local releases

**Actions → Release → Run workflow** on any branch, without ticking **Upload
to TestFlight**, does everything except the upload: version, schema (as a
warning), privacy, notes, archive, export and verification. Use it after
changing signing, capabilities, `project.yml` or the workflow. Ticking
**Upload to TestFlight** on a `v*` tag retries a release; on a branch it
fails.

The same script runs locally:

```sh
# Archive, export and verify into .build/release; signs with the accounts in
# Xcode > Settings > Accounts.
make release-archive TEAM_ID=ABCDE12345 BUILD_NUMBER=1000

# Upload too, with an App Store Connect API key.
make testflight TEAM_ID=ABCDE12345 BUILD_NUMBER=1000 \
    ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_….p8
```

A local upload uses up a build number the workflow will reach later, so raise
`BLAU_BUILD_NUMBER_OFFSET` past it. `testflight.sh` lists every variable.

## One-time setup

### Apple Developer and App Store Connect

1. **App IDs** (developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers): `com.joeblau.blau` with **iCloud** (CloudKit, container
   `iCloud.com.joeblau.blau` assigned) and **Push Notifications** (CloudKit
   change notifications), and `com.joeblau.blau.widgets`. Automatic signing
   can register them, but assigning the iCloud container is most reliable by
   hand or with one archive from Xcode.
2. **The app record** (App Store Connect → Apps → +): iOS, bundle ID
   `com.joeblau.blau`, name Blau, any SKU.
3. **An API key** (App Store Connect → Users and Access → Integrations → App
   Store Connect API → Team Keys → +) with the **Admin** role. The export
   signs with a cloud-managed Apple Distribution certificate and creates or
   updates provisioning profiles, which a key with a lower role can't do.
   Download `AuthKey_<id>.p8` (only possible once) and note the key ID and the
   issuer ID shown above the key list.
4. **Export compliance** needs no action: `ITSAppUsesNonExemptEncryption` is
   `NO` in the Info.plist (`project.yml`), because Blau only uses the
   encryption built into iOS (HTTPS and WSS, the Keychain, CloudKit) and
   SHA-256 digests. Revisit it if Blau ever adds its own cryptography.

### GitHub

Create an environment named **`testflight`** (Settings → Environments). Add
required reviewers so every release waits for an approval, and a deployment
tag rule `v*` (plus the default branch if you want dry runs from it).

Secrets of the `testflight` environment:

| Secret | Value |
| ------ | ----- |
| `APP_STORE_CONNECT_API_KEY_ID` | The API key's ID, e.g. `2X9R4HXF34` |
| `APP_STORE_CONNECT_API_ISSUER_ID` | The issuer ID (a UUID) |
| `APP_STORE_CONNECT_API_KEY_P8` | The `.p8` file: `base64 -i AuthKey_<id>.p8 \| pbcopy`, or its PEM text |
| `BLAU_SIGNING_CERTIFICATE_P12` | Optional, see [Signing](#signing): `base64 -i dev.p12 \| pbcopy` |
| `BLAU_SIGNING_CERTIFICATE_PASSWORD` | Optional: the `.p12`'s password |

Variables (environment or repository):

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `BLAU_TEAM_ID` | none, required | The 10-character Apple Developer team ID (Membership details) |
| `BLAU_CLOUDKIT_PRODUCTION_SCHEMA` | none | Schema version deployed to CloudKit Production, e.g. `2.0.0`; set it after each deploy |
| `BLAU_BUILD_NUMBER_OFFSET` | `0` | Added to the run number ([Build numbers](#version-and-build-numbers)) |
| `BLAU_TESTFLIGHT_INTERNAL_ONLY` | `0` | `1` exports with `testFlightInternalTestingOnly`: internal testers only, never external or App Store |
| `BLAU_CI_RUNNER`, `BLAU_CI_XCODE_VERSION` | as [CI](ci.md#runner-and-xcode) | Runner label and Xcode pin |

The secrets reach only the steps that use them, as environment variables;
the API key is written to a private temporary file for the archive step and
deleted when it ends. `make test-scripts` fails if `release.yml` maps a
secret anywhere else, references `XAI_DEV_API_KEY`, uploads an IPA, archive
or result bundle, or uses an action not pinned to a commit SHA. Release
builds never contain the developer xAI key: `Release.xcconfig` blanks it and
the embedded-secrets build phase fails the build if one is set
([configuration.md](configuration.md#release-builds-fail-on-embedded-keys)).

## Signing

Signing is automatic, through the API key; nothing is checked in and no
provisioning profile is managed by hand:

- `xcodebuild archive -allowProvisioningUpdates -authenticationKey…` signs
  the archive with an **Apple Development** identity, creating or updating
  the development profiles for both bundle IDs.
- `xcodebuild -exportArchive` re-signs for App Store Connect with a
  cloud-managed **Apple Distribution** certificate and App Store profiles.
  This is where `aps-environment` becomes `production` and
  `com.apple.developer.icloud-container-environment` becomes `Production`
  (`iCloudContainerEnvironment` in the export options), even though
  `project.yml` declares the development values Debug builds need.

A fresh runner has no development identity, so without help xcodebuild
creates a new Apple Development certificate on every run, and the team's
certificate list fills up. To avoid that, export one Apple Development
certificate with its private key from Keychain Access as a `.p12` and store it
in `BLAU_SIGNING_CERTIFICATE_P12` and `BLAU_SIGNING_CERTIFICATE_PASSWORD`.
[`scripts/release/signing-keychain.sh`](../scripts/release/signing-keychain.sh)
imports it into a temporary keychain for the job and deletes the keychain at
the end. If you run without it, revoke the "Created via API" development
certificates in the developer portal from time to time.

## IPA verification

Before anything is uploaded, `release.py verify-ipa` unpacks the exported IPA
and fails the release unless:

- the bundle ID is `com.joeblau.blau`, and the version and build number are
  the ones the run computed, in the app and in `BlauWidgets.appex`;
- it is a Release build (`BlauEnvironment = release`) with CloudKit on
  (`BlauCloudKitEnabled = YES`, which only a signed build has), no developer
  xAI key and `ITSAppUsesNonExemptEncryption = NO`;
- every bundle has a valid signature from an Apple Distribution certificate,
  an App Store provisioning profile (no device list) and no `get-task-allow`;
- the app is entitled to `iCloud.com.joeblau.blau` for CloudKit and iCloud
  Drive, with `aps-environment = production` and the Production iCloud
  environment.

The results are on the run's summary page and in `verify-report.md`. This
replaces the manual `codesign -d --entitlements` check on the exported IPA.

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `tag v0.2.0 is version 0.2.0 but project.yml's MARKETING_VERSION is 0.1.0` | Bump `MARKETING_VERSION` on `main`, delete the tag (`git push --delete origin v0.2.0`) and tag the new commit. |
| `no deployed Production schema is recorded` / `the CloudKit Production schema is recorded as …` | Run the [schema checklist](#production-schema-deploy-checklist), then set `BLAU_CLOUDKIT_PRODUCTION_SCHEMA`. |
| `… is not on main` | Only commits merged to `main` are released. |
| `Set the BLAU_TEAM_ID variable` | Add the variable to the `testflight` environment or the repository. |
| `Cloud signing permission error` or `No signing certificate "iOS Distribution" found` during export | The API key's role is too low; create an Admin key. |
| `No profiles for 'com.joeblau.blau' were found` or an iCloud container error during archive | The App ID lacks a capability or the container isn't assigned; see [One-time setup](#apple-developer-and-app-store-connect). |
| altool: `The bundle version must be higher than the previously uploaded version` | Raise `BLAU_BUILD_NUMBER_OFFSET` and push a new tag. |
| altool: `No suitable application records were found` | Create the app record in App Store Connect. |
| The build sits in "Missing Compliance" | `ITSAppUsesNonExemptEncryption` is missing from the Info.plist; it belongs in `project.yml`. |
| The build installs but Settings shows sync "Paused" | The Production schema lacks a record type or field: the schema step was skipped. Deploy it; the data uploads once it exists. |

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
a build, not after. The release workflow enforces this with
`BLAU_CLOUDKIT_PRODUCTION_SCHEMA`.

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
      release). `scripts/release/release.py schema` prints the version the
      build ships.
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
      every new property. v3 adds no record type, only the field
      `CD_endReasonRaw` (String) on `CD_Utterance`.
- [ ] Voiceprint vectors (`VoiceProfile.centroid`, `VoiceEnrollmentSet.embeddings`)
      are encrypted fields.
- [ ] No field you didn't expect (a typo deployed to Production is forever).
- [ ] Indexes: Core Data mirroring needs none beyond the defaults.

**4. Deploy to Production**

- [ ] Development → **Deploy Schema Changes…** Review the diff the console
      shows: it must only add record types, fields or indexes. Deploy.
- [ ] Production → Schema → Record Types now shows the new types and fields.
- [ ] Set the `BLAU_CLOUDKIT_PRODUCTION_SCHEMA` variable (Settings → Secrets
      and variables → Actions → Variables, or the `testflight` environment) to
      the deployed version, e.g. `2.0.0`.
- [ ] Do **not** "Reset Development Environment" after deploying unless you
      mean to: it deletes all development data and must be followed by step 2
      again.

**5. Verify the build against Production**

- [ ] The release run's **IPA verification** passed (summary page or
      `verify-report.md`): distribution signature, `iCloud.com.joeblau.blau`,
      `CloudKit`, `aps-environment = production` and the Production iCloud
      environment. For a build made outside the workflow, run
      `scripts/release/release.py verify-ipa --ipa Blau.ipa --version <v> --build <n>`.
- [ ] Release builds never run `initializeCloudKitSchema()`
      (`SchemaInitializationPolicy.never`, covered by `PersistenceOptionsTests`).
- [ ] Install the TestFlight build on two devices on the same iCloud account
      and run steps 1, 3, 4 and 9 of the
      [manual sync test plan](sync.md#manual-test-plan-device-a--device-b).
      TestFlight uses Production, so this is the check that the deploy worked.
- [ ] If the build changed the schema, also install it **over** the previous
      TestFlight build on a device with existing data: the migration runs and
      the old conversations are still there and still sync.

## Privacy manifest and labels

Run this before every TestFlight or App Store upload too (#79,
[privacy.md](privacy.md#the-privacy-manifest)). The release workflow already
runs the automated half (`make check-privacy`, and the bundle check on the
archive); the rest needs Xcode and App Store Connect.

- [ ] `make check-privacy PRIVACY_BUNDLE=<path to the .xcarchive>` passes:
      both manifests are valid, every required-reason API in the sources is
      declared, and the app and BlauWidgets carry their manifests. (Automatic
      in the release workflow; run it by hand for an archive made in Xcode.)
- [ ] Xcode → Organizer → the archive → right-click → **Generate Privacy
      Report**. It lists Blau, BlauWidgets and GRDB with no errors, and Blau's
      entries match the table in privacy.md. (`make release-archive` leaves
      an archive in `.build/release/Blau.xcarchive`; open it in the
      Organizer.)
- [ ] **Validate App** in the Organizer succeeds (it rejects missing or
      invalid required-reason declarations). App Store Connect runs the same
      validation on every upload and emails about problems.
- [ ] App Store Connect → App Privacy matches the manifest: **User Content →
      Other User Content**, linked to the user, used for App Functionality,
      not for tracking. No other data types.
- [ ] If a dependency was added or updated, check whether it ships a
      `PrivacyInfo.xcprivacy` (and is on Apple's list of SDKs that must) and
      re-run the report.

## Release history

| Version (build) | Tag | Schema version | Schema deployed to Production | Sync test plan run by / result |
| --------------- | --- | -------------- | ----------------------------- | ------------------------------ |
| 0.1.0 (first TestFlight) | pending | 3.0.0 | pending | pending |
