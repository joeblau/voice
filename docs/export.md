# Markdown export

Blau can save every conversation as a Markdown file in the user's own iCloud
Drive, so they always have a readable copy of what they said, outside the app
(issue #78, epic #7). The synced SwiftData store stays the source of truth
([sync.md](sync.md)); the files are a copy that is regenerated from it.

## Where the files go

The files live in the `Documents` folder of the ubiquity container
`iCloud.com.joeblau.blau` (the same container as the CloudKit database), which
Files shows as **iCloud Drive → Blau** and Finder as **iCloud Drive → Blau**.
`project.yml` sets this up:

| Setting | Value | Why |
| ------- | ----- | --- |
| Entitlement `com.apple.developer.icloud-services` | adds `CloudDocuments` to `CloudKit` | iCloud Drive (documents) for the container |
| Entitlement `com.apple.developer.ubiquity-container-identifiers` | `iCloud.com.joeblau.blau` | The container `FileManager.url(forUbiquityContainerIdentifier:)` opens |
| Info.plist `NSUbiquitousContainers` → `iCloud.com.joeblau.blau` | `NSUbiquitousContainerIsDocumentScopePublic: true`, `NSUbiquitousContainerName: Blau`, `NSUbiquitousContainerSupportedFolderLevels: Any` | Publishes `Documents` to iCloud Drive under the name **Blau** |

Things to know (Apple's "Configuring iCloud services"):

- iOS only rereads `NSUbiquitousContainers` when `CFBundleVersion` changes. If
  the folder doesn't show up after changing the key, bump the build number
  and reinstall.
- With automatic signing, Xcode enables iCloud Documents on the App ID and
  the container. A manually managed App ID needs **iCloud Documents** turned
  on in the developer portal (the container already exists for CloudKit).
- Unsigned builds (`CODE_SIGNING_ALLOWED=NO`: CI, `make test`) have no iCloud
  entitlement. Blau knows from the `BlauCloudKitEnabled` Info.plist key and
  never asks for the container; Settings says the build can't export.
- The folder appears in Files once Blau has created it, i.e. after the first
  export. iCloud Drive must be on for Blau (Settings → Apple Account → iCloud
  → iCloud Drive → Apps Using iCloud Drive).

## Format

One file per conversation, named after its start time, title and the first
eight hex digits of its id:

```
2026-10-08 14.03 Hiring Plan (7b0c1d2e).md
```

```markdown
---
title: "Hiring Plan"
conversation: 7B0C1D2E-3F40-4152-8364-758697A8B9CA
started: 2026-10-08T14:03:00-07:00
ended: 2026-10-08T15:10:00-07:00
time-zone: America/Los_Angeles
topics: 2
utterances: 5
generator: Blau Markdown export 1
---

# Hiring Plan

2026-10-08 14:03 – 15:10

## Hiring Plan

14:03 – 14:20

> Deciding who to hire first.

**14:03:12 · You:** I think we need a designer first.

**14:03:20 · Grok:** Why a designer before an engineer?

## Fundraising

14:20 – 15:10

**14:20:05 · You:** Let's talk money.
```

- **Title**: the conversation's title, else the first topic with a real
  title, else "Conversation".
- **Topics** are `##` headings in the order they were talked about, with
  their time span and summary. Utterances before the first topic come right
  after the title; any other utterance without a topic goes under
  `## No topic`. A topic the conversation came back to is headed again with
  "(continued)".
- **Utterances**: only final ones with text (partials are never stored).
  Speakers are You, Grok and Blau (system notes). Each utterance is one line:
  whitespace is folded and Markdown syntax characters are escaped, so a
  transcript never turns into formatting.
- **Times** are shown in one time zone, recorded in the front matter. A time
  on a different day than the conversation's start shows its date.
- **The front matter** is YAML, so tools like Obsidian read it. `generator`
  marks Blau's files; `conversation` identifies the conversation.

## Idempotency

The rendered file is a pure function of the stored conversation and the
time zone: no export date, device name or locale goes into it. The exporter
(`MarkdownExporter`, BlauPersistence) finds a conversation's existing file by
the id in its name and confirms it with the front matter, then:

| Situation | Does |
| --------- | ---- |
| Same bytes as the file on disk | Nothing: no write, the modification date stays, nothing for iCloud Drive to upload |
| Conversation changed (new utterance, topic edit, summary) | Rewrites the file in place |
| Title changed | Renames the file (one coordinated move), then rewrites it if the content changed |
| Several files for one conversation (two devices renamed it at once) | Keeps one, removes the others |
| Another file already has the name | Uses the full id in the name instead |
| A file that isn't a Blau export, or can't be read | Never touched |
| A conversation was deleted in Blau | Its file stays (it is the user's copy); delete it in Files |

**Two devices.** iCloud Drive syncs the folder, so every device sees every
export. A device exporting a conversation that already has a file reuses the
time zone written in that file, so devices in different time zones render
identical bytes and never rewrite each other's files back and forth. If two
devices write the same file while offline, iCloud Drive keeps conflict
versions; after each write the exporter marks them resolved and removes them
(`NSFileVersion`), since the file is regenerated from the synced store anyway.

**Edits are replaced.** The export is a copy. A user's edits to an exported
file are overwritten the next time that conversation is exported; Settings
says so. Their own files in the folder are never touched.

## Manual and automatic export

Settings → **Markdown Export** (`MarkdownExportSettingsSection`, backed by
`MarkdownExportController`):

- **Export Now** exports every conversation, including one being recorded.
- **Export Automatically** (off by default, kept in `UserDefaults`). Turning
  it on exports every conversation that has ended. While on:
  - `MarkdownExportController.run()` follows `PersistenceController.storeChanges()`
    (local saves that post `NSPersistentStoreRemoteChange`, CloudKit imports
    from other devices, the refresh when the app becomes active) and, 5 s
    after the last change, exports the conversations whose conversation,
    topic or utterance rows changed. It reads them from SwiftData history
    with its own cursor (consumer `markdown-export`, kept in the derived
    store), so changes made while Blau wasn't running are exported at the
    next launch.
  - Conversations still being recorded are skipped until they end, so a long
    session isn't re-uploaded every few seconds; ending one triggers its
    export.
  - Leaving the foreground runs a pending export at once, under a background
    task assertion.
  - If an automatic export fails (iCloud Drive off, say), the next one
    exports everything, so the changes it had read are not lost.
- The section shows the last result: how many conversations are up to date
  and how many files changed, or why it couldn't export.

## Threading

Nothing touches files or SwiftData on the main thread:

- `MarkdownExporter` is an actor whose executor is its own serial
  `DispatchSerialQueue` (utility QoS), so the blocking `NSFileCoordinator`
  calls never run on the main thread or tie up Swift's cooperative pool.
- `FileManager.url(forUbiquityContainerIdentifier:)`, which Apple says not
  to call on the main thread, is only called there.
- Conversations are read with a fresh `ModelContext` per conversation
  (`SwiftDataConversationExportSource`) and copied into
  `ConversationExportSnapshot` values, so a full export holds one
  conversation in memory at a time and never shares models with the UI or
  the pipeline's `ConversationStore`.
- Every file access is coordinated (`CoordinatedMarkdownFileSystem`): reads
  of a file that is still downloading wait for it, and iCloud Drive sees each
  write, move and delete as one change.

Logs go to category `data` (`Log.data`): one line per export with the counts
and duration, and errors per conversation. Titles and text are never logged.

## Tests

- `swift test` in `Packages/BlauKit` (`Tests/BlauPersistenceTests/Export`):
  the format (golden file), names, escaping, time zones; idempotency (a
  second export writes nothing and keeps modification dates), renames,
  duplicates, foreign files, cross-device time zones, failure isolation; the
  history-to-conversation mapping; the controller's toggle, debounce,
  catch-up and retry after a failure. They run against temporary folders
  with the real coordinated file system.
- `BlauTests/MarkdownExportAppTests`: the built app's `NSUbiquitousContainers`,
  the environment's export, and the Settings text.
- `BlauUITests/MarkdownExportUITests`: Export Now on a simulator without
  iCloud Drive explains why.

## Manual test plan: Files → iCloud Drive → Blau

Needs a build signed with the team that owns `iCloud.com.joeblau.blau`, on an
iPhone signed in to iCloud with iCloud Drive on (and a Mac on the same
account for step 7).

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | Record a short conversation with at least two topics, stop it. Settings → Markdown Export → Export Now. | Status: "N conversations exported: N new, 0 updated." | pending |
| 2 | Open Files → iCloud Drive. | A **Blau** folder with one `.md` per conversation, named `<date> <time> <title> (<id>).md`. | pending |
| 3 | Open a file (Quick Look) or in a Markdown app. | Front matter, `# title`, a `##` heading per topic with its span and summary, utterances with `HH:mm:ss · You/Grok`. | pending |
| 4 | Export Now again. Check the files' modification dates in Files (Get Info). | Status: "all up to date"; dates unchanged; no new files. | pending |
| 5 | Rename a topic (or the conversation) in Blau, Export Now. | The file is renamed (still one file per conversation) and shows the new title. | pending |
| 6 | Turn on Export Automatically, record and stop a new conversation, wait ~10 s. | Its file appears without tapping Export Now. | pending |
| 7 | On a Mac signed in to the same account, open Finder → iCloud Drive → Blau. | The same files. | pending |
| 8 | Turn off iCloud Drive for Blau, Export Now. | "iCloud Drive isn't available…"; nothing crashes. Turn it back on. | pending |
