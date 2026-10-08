# Privacy and data controls

Issue #79 (epic #7). What Blau keeps, where, what leaves the device, how the
user exports or deletes it, and the privacy manifest App Review reads. The
user-facing side is Settings → Privacy & Data (`Blau/Settings/PrivacySettingsView.swift`).

## What Blau keeps, and where

| Data | Where | Synced | Deleted by |
| ---- | ----- | ------ | ---------- |
| Conversations, topics, transcript (`Conversation`, `Topic`, `Utterance`) | SwiftData, private CloudKit database of `iCloud.com.joeblau.blau` | Yes | Delete All Conversations, Delete All Data |
| Knowledge base pages (`Document`, `CollectionItem`): About Me, Company, Notes, Collections | Same | Yes | Delete Knowledge Base, Delete All Data |
| What Blau learned (`Fact`, `MemoryEntity`) and the pinned profile summary (`ProfileBlock`) | Same | Yes | Delete Learned Facts, Delete Knowledge Base, Delete All Data |
| Voiceprint (`VoiceProfile`, `VoiceEnrollmentSet`); vectors are CloudKit-encrypted fields | Same | Yes ([product decision 2 in #1](voice-id.md)) | Delete Voiceprint (here or in Voice ID), Delete All Data |
| Memory search index (FTS5 + int8 vectors) | Application Support, this device | No, rebuilt from the store | Follows the store: the incremental indexer drops deleted records from SwiftData history ([memory-indexer.md](memory-indexer.md)) |
| Profile consolidation log (profile text before/after each run) and extraction notes | Application Support / `UserDefaults`, this device | No | Delete Learned Facts, Delete Knowledge Base, Delete All Data (`ProfileConsolidator.eraseLocalHistory()`) |
| Share-sheet exports (Export Conversations, Export All Data) | The app's temporary directory | No | Replaced by the next export; removed by every delete |
| Markdown copies in iCloud Drive → Blau (#78, [export.md](export.md)) | The user's iCloud Drive | Yes (iCloud Drive) | Not by Blau: they are the user's files, deleted in Files |
| xAI API key | Keychain, iCloud Keychain ([xai-auth.md](xai-auth.md)) | Yes | Settings → xAI Account → Remove Key |
| Settings and preferences | `UserDefaults`, this device | No | Deleting the app |
| Audio | Nowhere | – | Captured audio is processed in memory and never written to disk or sent |

## What is sent to xAI

Blau has no server. Every request goes from the iPhone straight to xAI with
the user's own key (#33), under the user's xAI account. The pane's
**What's Sent to xAI** section lists the same four things
(`SentToXAISection.items`):

| What | When | Code |
| ---- | ---- | ---- |
| The **text** of what the user says: only utterances the voice ID gate accepted, transcribed on device. No audio | Every turn | `TurnOrchestrator` commits text items ([realtime.md](realtime.md)) |
| The session instructions: the pinned profile summary, the user's About Me page and up to 40 current facts; today's date | Every `session.update` | `RealtimeInstructions`, `PinnedMemoryProvider` ([memory-profile.md](memory-profile.md)) |
| Results of the memory tools Grok calls (`search_memory`, `get_entity`, ...), at most ~1,500 tokens each | When Grok asks | [memory-tools.md](memory-tools.md) |
| With **Learn From Conversations** on: each closed topic's transcript (fact extraction) and the facts, notes and topic summaries for consolidation | After a topic closes; weekly | [memory-extraction.md](memory-extraction.md), [memory-profile.md](memory-profile.md#privacy) |
| A fixed sample sentence | Voice preview in Settings → Voice | `RealtimeVoicePreviewer` |

What comes back: Grok's reply as 24 kHz PCM audio and its transcript, tool
calls, and the results of web and X search when those are on (they run at
xAI). Topic titles and labels come from the on-device Foundation Models,
not xAI.

## Exporting everything

**Export All Data** (`DataExportSection`) writes a zip and offers it through
the share sheet:

```
Blau Export 2026-10-08.zip
└── Blau Export 2026-10-08/
    ├── README.md          what each file holds, with counts
    ├── blau-data.json     every record (DataExport, encoded)
    ├── Conversations.md   every conversation (the same Markdown as Settings → iCloud → Export Conversations)
    └── Knowledge.md       About Me, Company, Notes, Collections, the profile summary, what Blau learned
```

- `DataExport.snapshot(in:exportedAt:app:)` (BlauPersistence) reads every
  model on a `ModelContext` of its own, off the main actor, into plain
  `Codable` values. `DataExporter` formats them and
  `DataExportArchiver` zips the folder with `NSFileCoordinator`'s
  `.forUploading` option, so no compression library is needed.
- The JSON has `format: "com.joeblau.blau.export"` and `formatVersion: 1`
  (bumped only when a field is removed or changes meaning), the schema
  version, ISO 8601 dates with milliseconds, and enumerations as their stored
  raw values, so values written by a newer app version on another device are
  exported as they are. Partial (uncommitted) utterances are in the JSON,
  not in the Markdown. Ordering is deterministic: two exports of the same
  data are the same file.
- **The voiceprint is described, not exported.** Its model version,
  enrollment dates, devices and clip counts are in the JSON; the centroid
  and clip embeddings are not. They are a biometric template only Blau's
  speaker model can use, and an export is a file that gets shared and kept;
  the user loses nothing they could read or take elsewhere.
- The zip lives in the app's temporary directory (`DataExportFiles`). On
  iOS the files are written with complete file protection. Each export
  replaces the last, and every delete in Privacy & Data removes it.

## Deleting

Each **Delete** button asks first, with a count, and is refused while a
conversation is recording (the pipeline writes to the same store).
`PrivacyDataEraser.erase` runs:

1. For the learned facts or the knowledge base, waits for a consolidation
   that is already running (`ProfileConsolidator.waitUntilIdle()`), so it
   can't write a new profile summary from facts that are about to go.
2. `DataEraser.erase(scope, in:)` (BlauPersistence) fetches and deletes
   every record of the scope's models **one by one** and saves. Each
   deletion lands in the persistent history, and `NSPersistentCloudKitContainer`
   exports it as a CloudKit record deletion, so the records leave iCloud and
   every other device on the account. A batch delete would bypass the
   history and never reach CloudKit.
3. Removes the share-sheet exports, and for the learned facts or the
   knowledge base drops this device's consolidation log, its notes and the
   pinned-memory cache (`ProfileMemory.memoryErased()`), so the next session's
   instructions no longer carry what was deleted.

| Scope (`DataEraseScope`) | Records |
| ------------------------ | ------- |
| `conversations` | `Utterance`, `Topic`, `Conversation` |
| `learnedFacts` | `Fact`, `MemoryEntity`, `ProfileBlock` (the user's pages stay) |
| `knowledge` | `CollectionItem`, `Document` and everything `learnedFacts` covers |
| `voiceprint` | `VoiceEnrollmentSet`, `VoiceProfile` |
| `everything` | All of the above: every model in `CurrentSchema` |

Facts keep the utterance they came from as an id, not a relationship, so
deleting conversations keeps what was learned from them; Delete Learned Facts
is the control for that.

## The privacy manifest

`Blau/Resources/PrivacyInfo.xcprivacy` (the app) and
`BlauWidgets/PrivacyInfo.xcprivacy` (the Live Activity extension) are copied
to each bundle's root. The app binary statically links BlauKit and
FluidAudio, so the app's manifest covers them; GRDB ships its own manifest in
`GRDB_GRDB.bundle`. FluidAudio's resource bundle has none (its file-size reads
are covered by the app's FileTimestamp entry).

**Tracking:** none. `NSPrivacyTracking` is false and there are no tracking
domains.

**Collected data:** `NSPrivacyCollectedDataTypeOtherUserContent`, linked to
the user, not used for tracking, for app functionality: the text in "What is
sent to xAI" above, which xAI (a third party) receives and may retain under
its own terms. Data that stays on the device or in the user's private iCloud
database (the voiceprint, audio, diagnostics until the user shares them) is
not "collected" in Apple's sense. The App Store Connect privacy labels should
match: **User Content → Other User Content, linked, app functionality**.

**Required-reason APIs:**

| Category | Reason | Why | Where |
| -------- | ------ | --- | ----- |
| `UserDefaults` | `CA92.1` (the app's own defaults) | Settings, feature flags, onboarding progress, the extraction queue | Throughout `Blau/` and BlauKit; no app group |
| `FileTimestamp` | `C617.1` (files in the app or iCloud container) | Sizes of downloaded speech models and the memory index; FluidAudio's download checks (`attributesOfItem`) | `ModelStore`, FluidAudio `ModelCache`, `FileDownloader` |
| `FileTimestamp` | `3B52.1` (files the user picked) | The size of a note file chosen in the document picker, before importing it | `KnowledgeBaseSupport` |
| `DiskSpace` | `E174.1` (enough space to write) | Free space is checked before a speech model download; the download is refused when it wouldn't fit | `ModelStore.volumeAvailableCapacity` |
| `SystemBootTime` | `35F9.1` (elapsed time within the app) | Host time for audio frame timestamps and `CLOCK_UPTIME_RAW` for the performance HUD's CPU meter; never sent off the device | `CaptureHub.HostTime`, `SystemCPUTimeSource` |

The issue named the first three categories. `SystemBootTime` is declared too:
`AVAudioTime.hostTime(forSeconds:)` and `CLOCK_UPTIME_RAW` read the same
counter as `mach_absolute_time`, one of the listed APIs.

**Purpose strings:** `NSMicrophoneUsageDescription` (in `project.yml`) is the
only one Blau needs. Apple's `SpeechAnalyzer`/`SpeechTranscriber` (the
fallback transcriber) doesn't require speech recognition authorization, so
there is no `NSSpeechRecognitionUsageDescription`; no other protected
resource (photos, contacts, location...) is used. Live Activities need
`NSSupportsLiveActivities`, not a purpose string.

### Checking it

`make check-privacy` runs `scripts/check-privacy-manifest.py`:

- validates both manifests: a property list with the four top-level keys,
  only Apple's documented data types, purposes, API categories and reason
  codes, no category twice, no tracking flag without `NSPrivacyTracking`;
- scans the sources each manifest covers (`Blau/`, BlauKit's sources and the
  FluidAudio checkout for the app; `BlauWidgets/` and the shared activity
  attributes for the extension) for the required-reason symbols, and fails
  when one is used but its category isn't declared, naming the file and
  line. A declared category no source uses is a warning;
- with `PRIVACY_BUNDLE=<Blau.app or .xcarchive>`, checks that the app and
  every extension in the build carry a valid manifest at their root, and
  validates resource bundles' manifests.

`scripts/tests/test-privacy-manifest.sh` (part of `make test-scripts`, which
CI's lint job runs) tests the checker. `BlauTests/PrivacyAppTests` checks the
manifests are inside the built app and extension. The release checklist
([release.md](release.md#privacy-manifest-and-labels)) adds Xcode's privacy
report from the signed archive.

## Recording indicator

While Blau is listening, the recording Live Activity shows on the lock screen
and in the Dynamic Island, with a Stop button (#26,
[background.md](background.md)); iOS's own microphone indicator shows as
well. It is started when a conversation starts and ended when it stops, and a
stale one left by a killed run is ended at launch.

## Tests

| Where | Covers |
| ----- | ------ |
| `DataMaintenanceTests` (BlauPersistence) | Every scope, including `learnedFacts` keeping the user's pages; counts; deletions saved to the store |
| `DataExportTests` (BlauPersistence) | The snapshot holds every record; JSON round trip with millisecond dates; the voiceprint's vectors are left out; deterministic output; both Markdown files; the README; the folder; the zip unzips (with `ditto` on macOS) to the same files |
| `ProfileConsolidatorTests` (BlauMemory) | `eraseLocalHistory()` drops records and notes and keeps the schedule; `waitUntilIdle()` waits for a running consolidation |
| `PrivacyAppTests` (BlauTests) | The app's and the extension's manifests are bundled with the declared reasons; the pane's wording; deleting learned facts clears the pinned cache, the log, the notes and the exports; deleting is refused during a conversation; export files are replaced and removed |
| `SettingsUITests` | Export All Data opens the share sheet; deleting learned facts and conversations asks first |
| `test-privacy-manifest.sh` | The checker accepts the repository's manifests and rejects bad reasons, categories, data types, missing keys, undeclared APIs and bundles without manifests |

## Manual test plan

Prerequisites as in [sync.md](sync.md#manual-test-plan-device-a--device-b):
two devices on the same iCloud account, the same build on both (Debug with
Development, or TestFlight with Production).

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | On A, record two conversations, add a note, let Blau learn a fact (or say "remember that..."), enroll the voiceprint. Wait for B to show all of it. | B has the conversations, the note, the fact in What Blau Learned, and "Enrolled" in Voice ID. | pending |
| 2 | On A, Settings → Privacy & Data → Export All Data → Share Export → Save to Files. Unzip it in Files. | The folder has `README.md`, `blau-data.json`, `Conversations.md`, `Knowledge.md`; the JSON has both conversations, the note, the fact and the voiceprint without vectors. | pending |
| 3 | On A, Delete Learned Facts. | A's What Blau Learned is empty; the note stays. Within a minute B's is empty too. The next conversation's instructions (Console, `realtime` category) carry no facts. | pending |
| 4 | On A, Delete All Conversations. | Both disappear on A, then on B. In the CloudKit Console (`iCloud.com.joeblau.blau`, private database, zone `com.apple.coredata.cloudkit.zone`), querying `CD_Conversation` and `CD_Utterance` returns no records. | pending |
| 5 | On A, Delete Voiceprint. | Voice ID says "Not enrolled" on A and then on B; `CD_VoiceProfile` and `CD_VoiceEnrollmentSet` have no records. | pending |
| 6 | Put B in airplane mode, Delete All Data on A, then reconnect B. | B empties after it reconnects; nothing reappears on A. | pending |
| 7 | Archive a signed build in Xcode → Organizer → right-click → Generate Privacy Report. | The report lists Blau (Other User Content; UserDefaults, FileTimestamp, DiskSpace, SystemBootTime), BlauWidgets and GRDB, with no errors. Validate App succeeds. | pending |

Record the device models, iOS versions, build and results in the PR or the
release notes that ran the plan.
