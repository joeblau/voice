# Memory indexer

The incremental indexer (#63, epic #9) keeps the local memory search index
([memory-index.md](memory-index.md), #62) in step with the synced SwiftData
store. Text written on this device, and text CloudKit imports from the
user's other devices, becomes searchable without a rebuild; a full rebuild
(new device, recreated index, expired history) runs newest first, survives
the app being killed, and finishes in a `BGProcessingTask`. All of it backs
off when the device is hot or in Low Power Mode.

The code is in `Packages/BlauKit/Sources/BlauMemory/Indexing/`; the app
side (background task, Settings) is in `Blau/Memory/` and `Blau/Settings/`.

```swift
// The app does this through MemoryIndexingController, once per store
// generation (see "In the app" below).
let indexer = MemoryIndexer(
    index: try MemoryIndex.open(at: stack.location.memoryIndexURL),
    reader: SwiftDataMemorySources(container: stack.container),
    feed: SwiftDataMemoryChangeFeed(
        container: stack.container,
        cursors: HistoryCursorStore(modelContainer: stack.derivedContainer),
        storeURL: stack.syncedStoreURL),
    embedder: textEmbeddings,                          // #60; nil or not installed: keyword only
    gate: IndexingGate(performance: performancePolicy)) // #75
Task(priority: .utility) { await indexer.run() }
```

## Pieces

| Type | Where | What it does |
| --- | --- | --- |
| `MemoryIndexer` | BlauMemory | The actor that does all the work, one piece at a time: applies store changes, runs and checkpoints full passes, embeds the backlog, publishes `MemoryIndexingStatus` |
| `MemoryChangeFeed`, `SwiftDataMemoryChangeFeed` | BlauMemory | What changed: SwiftData history read with a `PersistentHistoryTracker` of its own (consumer `memory-index`), signalled by `NSPersistentStoreRemoteChange` |
| `SwiftDataMemoryChangeResolver` | BlauMemory | Traces each changed record to the source whose chunks it appears in (`MemorySourceChanges`) |
| `MemorySourceReader` | BlauMemory | Reads sources by id, ids per kind, and every source with its date; `SwiftDataMemorySources` implements it |
| `MemoryIndexingController` | BlauMemory | `@MainActor @Observable`: one indexer per `PersistenceController.generation`, status for Settings, the background task's entry point |
| `MemoryIndexBackgroundTask` | `Blau/Memory` | Registers and schedules the `BGProcessingTask` |
| `MemoryIndexSettingsSection`, `MemoryIndexPresentation` | `Blau/Settings` | Settings → Knowledge → Search Index: status, progress, rebuild |

## Incremental indexing

1. **Signal.** Core Data posts `NSPersistentStoreRemoteChange` for every
   transaction on the synced store, the app's own saves and CloudKit
   imports alike (verified on the macOS SDK: a local save posts it with the
   store's URL). `RemoteChangeMonitor` filters it to the synced store, and
   `run()` waits `debounce` (5 s; a conversation saves every 2 s) so a burst
   is read once.
2. **Read history.** The feed's tracker reads every transaction after its
   cursor, with `fetchNewChanges(savingCursor: false)`.
3. **Resolve.** `SwiftDataMemoryChangeResolver` fetches the inserted and
   updated records by `persistentModelID` (500 per `IN` query) and maps them
   to sources:

   | Changed record | Re-chunked source |
   | --- | --- |
   | `Conversation` | itself |
   | `Utterance`, `Topic` | its conversation (topic titles are in exchange keys) |
   | `Document` | itself and its collection items (their keys carry its title) |
   | `CollectionItem` | its document |
   | `Fact` | itself, and the conversation of `sourceUtteranceID` (facts are in exchange keys) |
   | `MemoryEntity` | its facts (statements start with its name) and their conversations |

   Deleted records can't be fetched. SwiftData records an *update* of the
   parent whose to-many relationship lost a child (verified: deleting an
   utterance reports its conversation as updated), so deleted utterances,
   topics and collection items re-chunk their parent through the table
   above. A deleted conversation, document, collection item or fact asks
   for a **sweep** of its kind: the index's source ids minus the store's are
   orphans and are removed. A fact's exchange is found through the index's
   `fact_link` table (below), since `sourceUtteranceID` is a plain id, not a
   relationship.
4. **Apply.** Each source is read again (`MemorySourceReader.read`), chunked
   with the same `MemoryChunker` the rebuild uses, and written with
   `MemoryIndex.replace`. A chunk keeps its vector while its `contentHash`
   (SHA-256 of the key text) and the vector's `modelVersion` match; only the
   others are embedded. Editing one paragraph of a long note embeds one
   chunk; a new exchange embeds one chunk.
5. **Commit.** The cursor is saved only after the write. A change that was
   read but not written (the app killed in between) is read again on the
   next launch; one whose write failed starts a verification pass instead,
   since history won't report it again in this process.

### Why chunk hashes rather than `Document.contentHash`

The issue sketched comparing each source's `contentHash` + `modelVersion`.
Only `Document` has a source-level hash; conversations, facts and items
don't, and a document's hash can't say *which* chunks changed. The
indexer compares at the chunk level instead (each chunk's `contentHash`
and its vector's `modelVersion`), which re-embeds strictly less: an edit
re-embeds the chunks whose key text changed and nothing else. Re-chunking
the source is cheap CPU work next to embedding.

### Fact links

A fact extracted from an utterance is listed in that exchange's key
(`facts: …`). When the fact is edited or deleted, the exchange must be
re-chunked, but after a deletion nothing in the store says which
conversation it came from. The index therefore records, for every
conversation it writes, the facts its keys were built with
(`MemoryIndex.SourceChunks.linkedFactIDs`, table `fact_link`, index schema
version 2). `MemoryIndexRebuilder` records them too.

## Full pass

A full pass re-reads every conversation, document (with its items) and
fact. It starts when:

| Trigger | History |
| --- | --- |
| The index has never finished a rebuild (new device, first launch with #63, deleted, corrupt or old-schema file) | Skipped to now first (`skipToLatest`): the pass reads everything as it is after that point, so replaying history would only duplicate it |
| History expired (`historyWasReset`) | The tracker already moved to now |
| One history read touches more than `incrementalLimit` (500) sources, e.g. a big CloudKit import, and no pass is running | Committed: the pass covers it |
| The chunking changed (`indexer.chunking` differs: policy or time zone) | Kept |
| Settings → Rebuild Index | Kept |

- **Newest first.** Sources are ordered by date, newest first: a
  conversation's start, a document's last edit, a fact's `validFrom`. On a
  new device, recent conversations are searchable first.
- **Steps.** Each step reads 16 conversations (or 256 documents and facts),
  chunks them, embeds what has no current vector, writes, and saves a
  checkpoint in the index's `index_state` (`indexer.fullPass`: start, the
  last source written, how many are done). Search works on what is done.
- **Resumable.** After a kill, the next launch reads the checkpoint and
  continues after the last source written. Everything else in memory is
  rebuilt from the store. A step that was interrupted between its write
  and its checkpoint is redone, and its chunks keep the vectors they got.
- **Concurrent changes.** Changes keep flowing during a pass and are
  applied between steps, on the same actor, so a pass never overwrites a
  newer change with an older read.
- **End.** Orphans of every kind are removed (with their fact links'
  conversations re-chunked), the rebuild is recorded (`needsRebuild` turns
  `false`) with the chunking fingerprint, and the checkpoint is cleared.

## Embedding

- With a model, chunks are embedded as they are written.
- Without one (`TextEmbeddingService` reports `notInstalled`, as it does
  until the model is hosted, docs/models.md), or when embedding fails,
  chunks are written for keyword search and `vectorsUnavailable` says why.
- **Backlog.** Whenever the indexer is signalled (store changes, the app
  becoming active) it compares the index's chunk count with the vectors of
  the current model version. Chunks without one (the model was just
  installed, or replaced: a new `modelVersion`) are embedded 256 at a time,
  newest content first (`chunksNeedingEmbedding(…, newestFirst: true)`),
  with progress in `MemoryIndexingStatus.embedding`. A model change
  therefore needs no re-chunking pass.

## Throttling

Every incremental pass, full-pass step and embedding step first awaits the
`IndexingGate` (#75) over the app's `PerformancePolicy`:

| Level (thermal state, Low Power Mode, battery) | Indexing |
| --- | --- |
| `normal` | Immediately |
| `reduced` (`serious` thermal, or Low Power Mode) | Deferred up to 5 minutes, or until `normal` |
| `minimal` (`critical`, or battery almost empty) | Suspended until the level improves |

While held, the status is `.waiting(mode)` and Settings says so. Nothing is
lost: the work resumes where it was.

## In the app

- **Composition.** `AppEnvironment.memoryIndexing` is built for every
  environment kind; `start()` follows `PersistenceController.generation`
  (Observation's `Observations`) and builds a new `MemoryIndexer` for each
  store generation, because models, contexts and history identifiers of a
  replaced container are invalid. The index file is opened once and shared.
  An in-memory store (previews, unit and UI tests, a store that failed to
  open) gets no index, so tests never build one.
- **Foreground.** The indexer runs at `.utility` priority whenever the app
  runs, so a rebuild makes progress while the app is open.
- **Background.** When the app leaves the foreground with a rebuild or an
  embedding backlog left, it submits a `BGProcessingTaskRequest`
  (`com.joeblau.blau.memory-index`, no network, external power not
  required since the gate already backs off on battery). The handler opens
  the stores if the app was launched for it, waits until the indexer is
  idle, and completes; on expiration it stops waiting, the process is
  suspended mid-step, and it reschedules. The next run resumes from the
  checkpoint. Registration happens in `BlauApp.init` (live app only),
  before launch finishes, as BackgroundTasks requires. On iOS 27 the
  request is submitted with the async `submitTaskRequest(_:)`;
  `submit(_:)` is deprecated there.
- **Settings → Knowledge → Search Index.** Status (Up to date, Updating…, Rebuilding…,
  Waiting, Paused), a progress bar for a rebuild or embedding backlog
  ("1,200 of 3,400"), the number of passages, when it was last rebuilt, and
  Rebuild Index.

## Telemetry

`Log.memory` (never text, only counts): full pass start, resume and finish
at `notice`, each incremental pass at `info`, failures at `error`, the
background task's start, end and scheduling. Embedding is the shared
service's `memory.embed` signpost ([performance.md](performance.md)); the
indexer adds no interval of its own.

## Testing

| What | How |
| --- | --- |
| Indexer logic (`swift test`) | `MemoryIndexerTests`: first build skips history, newest-first order, partial re-embedding of an edited note, new utterances, sweeps, fact links, renamed collections, large imports, expired history, chunking changes, keyword-only then backlog, model change, re-embed all, throttling, the run loop; every case compares the index with a from-scratch `MemoryIndexRebuilder` build |
| 10k-chunk rebuild resumes after a kill (`swift test`) | `MemoryIndexerRebuildTests`: 500 conversations × 20 exchanges on an on-disk index, cancelled mid-pass, reopened from the file by a new indexer: it continues after the checkpoint, embeds only what was missing, and ends identical to a from-scratch build; progress survives the relaunch |
| SwiftData end to end (`swift test`) | `SwiftDataIncrementalIndexingTests`: a note edited through a CloudKit-import-authored context becomes searchable with no call (remote-change notification → history → resolver → reader), conversations likewise; 13 kinds of change, applied incrementally, each match a full rebuild; a change read but not committed is replayed; the resolver and reader |
| Controller (`swift test`) | `MemoryIndexingControllerTests`: on-disk store indexed and followed, in-memory store left alone, a new indexer per generation on the same file, rebuild |
| Tracker (`swift test`) | `PersistentHistoryTrackerTests`: deferred cursor saves, `skipToLatest` |
| App wiring (`make test-unit`) | `MemoryIndexingWiringTests` (Info.plist identifier and `processing` mode, no index in hosted tests), `MemoryIndexPresentationTests` |

Measured on the Mac (M-series, debug build, hashing embedder): the resumed
part of the 10k-chunk rebuild (about 8,700 chunks) took 4.7 s.

### On a device

The parts no simulator or test runner can show: CloudKit delivering a
change from another device, and iOS granting a `BGProcessingTask`.

**Note edited on device A becomes searchable on device B** (follow the
setup in [sync.md](sync.md#manual-test-plan-device-a--device-b)):

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | On B, open Settings → Knowledge → Search Index. | "Up to date" (after a first rebuild), a passage count. | pending |
| 2 | On A, create a note with a distinctive word (until the knowledge base UI #65 exists, a DEBUG build inserting a `Document`). | It syncs (A: "Syncing…" then "On"). | pending |
| 3 | Keep B in the foreground for up to a minute. | B's passage count grows; a keyword search on B (debug tooling or #64's search) finds the word. | pending |
| 4 | On A, edit one paragraph of the note. | B finds the new text and no longer the old; Console (`category == "memory"`) shows one incremental pass with 1 embedded (when the model is installed). | pending |
| 5 | Delete the note on A. | B no longer finds it. | pending |

**Rebuild of 10k chunks completes in the background and resumes after
kill:**

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | Install on a device with ~10k chunks of data (or sign in to an account that has it), or delete the index (`Application Support/Blau/Derived/MemoryIndex.sqlite`) and relaunch. | Settings → Knowledge → Search Index: "Rebuilding…" with a progress bar. | pending |
| 2 | Kill the app from the app switcher at about 30%. Relaunch. | Progress continues from where it was, not from 0. | pending |
| 3 | Background the app; in Xcode, pause and run `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.joeblau.blau.memory-index"]`, resume. | Console: "Memory index background task started", then "finished" once done. | pending |
| 4 | Or leave the device idle overnight. | Next morning, "Up to date"; `needsRebuild` false. | pending |
| 5 | Warm the device (or turn on Low Power Mode) during a rebuild. | "Waiting" or "Paused"; it continues when conditions recover. | pending |
