# Knowledge base

What the user tells Blau to know (#65, epic #9): **About Me**, their
**Company**, **Notes** and **Collections** of prompts to practice, such as
YC interview questions. It opens from Settings → Knowledge. Everything is
stored in the synced SwiftData store (`Document` and `CollectionItem`,
[data-model.md](data-model.md#schema-v2-memory)), so it follows the user to
their other devices through iCloud, and the incremental indexer
([memory-indexer.md](memory-indexer.md)) makes every edit searchable for
Grok's `search_memory` tool ([memory-tools.md](memory-tools.md)) without a
rebuild.

| Screen | Stored as | View |
| --- | --- | --- |
| About Me | One `.profile` document: the user's name is its title, what they write its body | `Blau/Knowledge/AboutMeView.swift` |
| Company | One `.company` document: the company's name is its title; the fields and free text are Markdown sections of its body (`CompanyProfile`) | `CompanyView.swift` |
| Notes | `.note` documents, Markdown, written, pasted or imported | `NotesView.swift` |
| Collections | `.collection` documents (the name is the title), each prompt a `CollectionItem` with an optional reference answer | `CollectionsView.swift` |

The write path and the parsing live in BlauKit
(`Packages/BlauKit/Sources/BlauPersistence/Knowledge/`), so they are tested
on the Mac with `swift test`; the app target holds the SwiftUI views.

## Pieces

| Type | Module | What it does |
| --- | --- | --- |
| `KnowledgeBaseEditing`, `KnowledgeBaseStore` | BlauPersistence | Every knowledge-base write: save a document (create or update), delete one, add, edit, delete and reorder collection items. A `ModelActor` on `DispatchQueueModelExecutor`, so nothing saves on the main thread; one save per call |
| `DeferredKnowledgeBaseStore` | BlauPersistence | The store over whichever container is open; the app's container is replaced when the iCloud account changes. `AppEnvironment.knowledgeBase` |
| `KnowledgeDraft` | BlauPersistence | One page being edited: saves 1 s after the last keystroke, flushes when the editor closes or the app leaves the foreground, adopts edits synced from another device |
| `CollectionImport` | BlauPersistence | Pasted or imported text → prompts (and reference answers) |
| `NoteImport` | BlauPersistence | Pasted text or a `.txt` / `.md` file → a note's title and body; decodes the file |
| `CompanyProfile` | BlauPersistence | The company page's fields ⇄ its Markdown body |
| `KnowledgeSettingsView` | app | Settings → Knowledge: a row per screen with its summary (name, count), counted with `fetchCount` and refreshed on every `ModelContext.didSave` |

Views read with `@Query` on the main context (de-duplicating CloudKit
copies by id) and write only through `AppEnvironment.knowledgeBase`.

## Editing and saving

- **Autosave.** Editors bind to a `KnowledgeDraft`. Each change restarts a
  1 s timer; when it fires, the draft calls `saveDocument`, which goes
  through `Document.update(title:body:at:)`: the content hash and
  `updatedAt` change only if the text did, and an unchanged save writes
  nothing. A burst of typing is one save: one SQLite transaction, one
  history transaction for the indexer, one CloudKit export. Leaving the
  editor, or the app leaving the foreground, saves at once. The footer says
  "Saving…", "Saved. Syncs to your devices through iCloud." or that the save
  failed (the text is kept and the next keystroke retries).
- **New pages are created by their first save with text.** Opening New
  Note and leaving without typing creates nothing; a note cleared to
  nothing is deleted when its editor closes.
- **One About Me, one Company.** `saveDocument` for `.profile` or
  `.company` with an id that doesn't exist updates the most recently edited
  page of that kind if there is one, and returns its id, so two editors
  opened before the first save landed never create two pages. Two devices
  that both create the page while offline still can (CloudKit has no
  uniqueness); the screens show the most recently edited one.
- **Edits from another device.** When the stored page's content hash
  changes under an open editor, the draft takes the new text unless the
  user has typed something not yet saved; then their text is saved over it,
  the same last-writer-wins CloudKit applies to the record. A save the draft
  made itself coming back through `@Query` is recognized by its hash and
  ignored.
- **CloudKit copies.** CloudKit can mirror one record twice. Every write
  touches every copy with the id (an edit updates all, a delete removes all,
  with their items); lists show one row per id.

## Company fields

The schema has no columns for the company's fields (adding them would be a
CloudKit schema change for text that is only ever read as text), so
`CompanyProfile` stores each filled-in field as a `##` section of the body,
in a fixed order, then the free text under `## Notes`:

```markdown
## What It Does
Inventory and food-cost app for independent restaurants.

## Traction
40 paying restaurants, $18k MRR.

## Notes
We sell through POS partners.
```

Fields: What It Does, Product, Customers and Market, Business Model,
Traction, Team, Funding, Website. The headings are fixed English (they are
the stored format; the labels on screen are localized). Reading a body back,
a heading that names a field starts it; text before the first heading, under
`## Notes` or under any other heading (kept with its heading) goes to the
notes, so nothing written elsewhere is dropped. The memory index cuts
documents at headings, so the fields come back from `search_memory` as
`[Larderly] [Traction] …`; the memory tools also read the company page
directly for "what does my company do?" when search finds nothing.

## About Me and the ProfileBlock

The issue sketches About Me as the `ProfileBlock` editor. It edits the
`.profile` document instead, and shows the `ProfileBlock` read-only below it
("Blau's Summary") once one exists:

- The schema (#61) already splits the two: `DocumentKind.profile` is "the
  user's own background, written or edited by the user", and the
  `ProfileBlock` is the model-maintained summary that sleep-time
  consolidation (#67) rewrites from active facts, keeping user-authored
  text verbatim. If the user edited the block directly, the next
  consolidation would have nothing to tell their words from its own and
  could rewrite them.
- Documents are indexed and searchable (`search_memory`,
  `kinds: ["profile"]`, and the memory tools' direct read of the profile
  and company pages); `ProfileBlock` is not indexed.
- Pinning the block into every session's instructions and showing the user
  what consolidation changed are #67.

## Collections and pasting

New Collection (and Add Questions… on a collection) is one sheet: a name, a
text box, the system **Paste** button, **Import File…**, and a live count
("30 questions"). Pasting a list whose first line is a heading
(`# YC interview questions`) also names the collection. Create saves the
collection and all its prompts in one `addItems` call (one save), then opens
it.

`CollectionImport` reads one prompt per line:

| Line | Becomes |
| --- | --- |
| `1. What are you building?`, `12) …`, `(3) …`, `4: …`, `- …`, `* …`, `• …`, `Q: …`, `Q3. …`, `Question 7: …` | The prompt, without its marker. `1.5 million users: how?` and `Q4 revenue?` are left alone |
| `A: …` / `Answer: …` | The reference answer of the prompt above (several lines are joined) |
| `prompt⇥answer` | A prompt and its answer, as pasted from a spreadsheet |
| `# Heading` | Not a prompt; the first one before any prompt is the suggested name |
| A repeat (case, spacing, diacritics and trailing punctuation aside) | Dropped and counted ("2 repeats left out"); `addItems` also skips prompts the collection already has |

A collection's prompts are listed in order with their reference answers and
practice record (`practiceCount`, `score`, `lastPracticedAt`, written by
practice mode, #69, [practice.md](practice.md)), under **Practice with
Grok** and the collection's record (practiced, average score, last
practiced, up next). Tap one to edit its prompt or answer, or delete it;
Edit reorders (`reorderItems` renumbers `ordinal` 0, 1, 2…, writing only
items that moved; items another device added meanwhile keep their order
after them); Rename changes the collection's title, which the index carries
into every item's key (`[YC interview questions] …`).

## Notes and importing

Notes are Markdown. The editor has a title and a body, a **Preview** toggle
(headings, lists, quotes, code blocks and inline styles; `MarkdownPreview`),
Share and Delete. Notes come from:

- **New Note.**
- **Paste:** the system Paste button makes a note from the clipboard. A
  short first line followed by more text becomes the title.
- **Import Files…:** `.txt` and `.md` files (several at once) through
  `fileImporter`. A leading `# Heading` is the title, otherwise the file
  name. Files are decoded as UTF-8 (with or without a byte-order mark),
  UTF-16 with a byte-order mark, or Windows-1252; files over 2 MB are
  refused. `UTType.markdown` is iOS 27 only, so the type is looked up by its
  identifier (`net.daringfireball.markdown`), which works on iOS 26.
- **Share extension:** later (the issue lists it as later).

## Speaking to add

"Remember that…" in a conversation goes through Grok's `remember` tool
(#68, [memory-tools.md](memory-tools.md#the-tools)): it stores a
user-origin `Fact`, indexed at once. Facts are listed and deleted in
Settings → Knowledge → What Blau Learned; the knowledge base screens'
footer tells the user they can say it.

## Re-indexing

Nothing in the UI calls the indexer. Each `KnowledgeBaseStore` save is a
persistent-history transaction on the synced store, which posts
`NSPersistentStoreRemoteChange`; the incremental indexer reads it and
re-chunks exactly what changed (a document; its items when its title
changed; an item's document when items were added, edited or deleted) and
embeds only chunks whose text changed. Edits imported by CloudKit from the
user's other devices take the same path. See
[memory-indexer.md](memory-indexer.md#incremental-indexing).

## Tests

| What | Where |
| --- | --- |
| The store: create, update, unchanged saves, blank editors, one profile and company page, CloudKit copies, collection names, 30 pasted prompts in one save and in order, duplicates, edit, delete, reorder, practice records kept, the deferred store following the container | `BlauPersistenceTests/Knowledge/KnowledgeBaseStoreTests` |
| Pasting and importing: the 30-question YC paste, answers, tabs, repeats, list markers, headings, line endings, note titles, file encodings; company fields round-trip | `BlauPersistenceTests/Knowledge/KnowledgeImportTests` |
| Autosave: one save per burst, flush, adopting synced edits, unsaved typing wins, failures, discard, singleton redirect | `BlauPersistenceTests/Knowledge/KnowledgeDraftTests` |
| Re-indexing: notes, the company page and a pasted 30-question collection become searchable through the running indexer with no call; edits, renames and deletes follow; the index equals a from-scratch rebuild | `BlauMemoryTests/Indexing/KnowledgeBaseIndexingTests` |
| App wiring: the environment writes to the open store and the main context sees it; the Knowledge rows; summaries, Markdown preview, failure messages | `BlauTests/KnowledgeBaseAppTests` |
| UI: a 30-question YC collection by pasting, timed (< 60 s); editing a question's answer; About Me, Company and a note saving as you type, with the preview | `BlauUITests/KnowledgeBaseUITests` |

```sh
cd Packages/BlauKit && swift test --filter "Knowledge"
make test-ui DESTINATION='id=<simulator udid>'   # or -only-testing:BlauUITests/KnowledgeBaseUITests
```

## On a device

iCloud sync needs two devices signed in to the same iCloud account (see
[sync.md](sync.md#manual-test-plan-device-a--device-b) for the setup):

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | On A, Settings → Knowledge → Collections → New Collection, Paste a 30-question list, Create. | The collection opens with 30 questions in well under a minute. | pending |
| 2 | Wait for A to sync ("On" in Settings → iCloud), open Collections on B. | The collection is there with 30 questions in the same order. | pending |
| 3 | On B, edit a question's reference answer and reorder two questions. | A shows the change after it syncs. | pending |
| 4 | On A, edit the Company page's Traction field; on B, ask Grok "what's our traction?". | Grok answers from the new text (`search_memory` with `kinds: ["company"]`); Settings → Knowledge → Search Index on B shows an incremental pass in Console (`category == "memory"`). | pending |
| 5 | Open the same note on A and B; type on A, wait for sync while B's editor is open and untouched. | B's editor shows A's text without reopening. | pending |
| 6 | Delete the note on B. | It disappears on A, and searching for its words finds nothing on either device. | pending |
