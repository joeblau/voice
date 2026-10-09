# Practice mode

Rehearse answers to a collection of questions by voice, with Grok as the
interviewer (#69, epic #9): "let's practice YC questions", and Grok asks a
question, listens, gives short feedback against the reference answer,
follows up like a partner would, keeps score and moves on. Collections are
the knowledge base's ([knowledge-base.md](knowledge-base.md)): a
`.collection` document whose prompts are `CollectionItem`s with optional
reference answers.

```
"Let's practice YC questions"
        │  (spoken, or "Practice with Grok" on a collection)
        ▼
Grok ──function calls──▶ TurnOrchestrator ─▶ RealtimeToolRunner ─▶ practice tools (BlauRealtime)
                                                                     │  PracticeCoordinator: the run, the scheduler
                                          PracticeBackend (BlauCore) ├▶ PracticeStore (BlauPersistence): synced record
                                     PracticeRunRecording (BlauCore) └▶ TopicLifecycle (BlauTopics): the run's topic
```

| Piece | Module | Role |
| --- | --- | --- |
| `PracticeBackend`, `PracticeRunRecording`, `PracticeCollection`, `PracticeItem` | BlauCore | The contracts. BlauRealtime, BlauPersistence and BlauTopics are siblings, so they sit below all three (architecture rule 2) |
| `PracticeScheduler` | BlauCore | Which question next: least recently and worst practiced first |
| `PracticeCollectionMatcher` | BlauCore | Which collection the user means ("YC questions" → "YC interview questions") |
| `PracticeStore`, `DeferredPracticeStore` | BlauPersistence | Reads collections and writes each attempt to the synced store, off the main thread |
| `PracticeCoordinator`, `ListCollectionTool`, `NextPracticeQuestionTool`, `RecordPracticeResultTool`, `EndPracticeTool` | BlauRealtime | The run's state and the four function tools |
| Practice section of `RealtimeInstructions` | BlauRealtime | How to be the interviewer |
| `TopicLifecycle: PracticeRunRecording` (`TopicLifecycle+Practice.swift`) | BlauTopics | Each run as a topic of its own |
| `PracticeTools.coordinator(persistence:topics:)`, `PracticeLauncher` (`Blau/Practice/PracticeMode.swift`) | app | Wiring, and "Practice with Grok" from the Collections screen |

## The tools

The issue lists three tools; there are four. `end_practice` closes the run
(and its topic) and returns what to sum up, so Grok's wrap-up is grounded
in the scores rather than its memory of the last ten minutes. Every output
stays under about 1,500 tokens, like the memory tools.

### `list_collection(name?)`

Without a name, the user's collections with their record:
`{"collections":[{"name":"YC interview questions","questions":30,"practiced":12,"average_score":0.68,"last_practiced":"2026-10-08"}]}`.
With a name, that collection's questions in order:
`{"collection":{…},"questions":[{"id":"…","number":1,"prompt":"What are you building?","times_practiced":2,"last_score":0.6,"last_practiced":"2026-10-08","has_reference_answer":true}],"omitted":0}`.
Reference answers are left out of listings (they only come with the
question being asked); a long collection is cut to the budget and the rest
counted in `omitted`.

### `next_practice_question(collection)`

The next question to ask, never one already asked in this run, with its
reference answer (up to 900 characters) and record, and where the run
stands:

```json
{"collection":"YC interview questions","started":true,
 "question":{"id":"…","number":3,"prompt":"Why now?","reference_answer":"…","times_practiced":1,"last_score":0.4,"last_practiced":"2026-10-01"},
 "run":{"asked":1,"answered":0,"total":30},
 "instruction":"Ask this question as written, then stop and listen. …"}
```

The first call for a collection starts a run (`"started": true`); asking for
another collection ends the run and starts a new one. When every question
has been asked: `{"done":true,…,"instruction":"… Call end_practice …"}`.

Names are matched leniently (`PracticeCollectionMatcher`): case,
diacritics, punctuation and plurals aside, an exact title first, then a
title holding every significant word ("yc", "interview"; filler such as
"my", "questions" or "practice" doesn't count), then a partial match. A
vague name ("my questions") picks the only collection when there is one.
No match fails with the user's collection names, so Grok can ask which.

### `record_practice_result(item_id, score, notes?)`

Writes one attempt to the question's practice record and adds it to the
run. `score` is 0 to 1 (1 as strong as the reference answer, 0.5 partly
there, 0 missed); a model answering on a 10- or 100-point scale (`7`,
`"80%"`) is scaled down, anything else is rejected. `item_id` is the id
`next_practice_question` returned; a question number of the run's
collection (`2`) is accepted too. Answering a question again in the same
run replaces its entry in the run (the record counts both attempts).
Output: `{"recorded":{"id","prompt","score","previous_score","times_practiced"},"run":{…}}`.

### `end_practice()`

Ends the run and returns `{"ended":{"collection","asked","answered","average_score","to_work_on":[…],"strongest":{…}}}`:
up to three answers under 0.7, weakest first, and the best one at 0.8 or
above. Without a run: `{"message":"No practice run is going on."}`.

## Spaced repetition

`PracticeScheduler` orders a collection's questions, least recently and
worst practiced first:

1. **Never practiced** questions first, in the collection's order.
2. **Practiced** ones by how overdue they are: time since the last
   practice divided by the question's interval. The interval starts at one
   day, doubles with each practice (at most six times) and is scaled by
   the latest score, from a fifth of it for a missed answer to 1.8 times
   for a perfect one. A weak answer from three days ago comes before a
   strong one from yesterday; of two practiced at the same time, the
   weaker comes first.
3. Ties: the lower score, then the earlier practice, then the collection's
   order.

Questions asked in the current run are skipped, so a run of ten never
repeats one. The next run starts with whatever is most overdue then.

## Starting a run

- **By voice.** The Practice section of the instructions tells Grok to
  switch modes when the user asks to practice, drill or rehearse, and to
  call `next_practice_question` (or `list_collection` when it isn't sure
  which collection). Nothing on the client listens for the phrase: the
  model decides, like any other tool call.
- **From the app.** Settings → Knowledge → Collections → a collection →
  **Practice with Grok** closes Settings, starts a conversation if none is
  running (through the record button, so a failed start shows its usual
  alert) and sends `Let's practice my "YC interview questions" collection.
  Ask me the questions one at a time.` as the user's turn
  (`PracticeTools.startRequest`, `RealtimeService.send`). It shows in the
  chat like anything the user said, so the transcript reads the way the
  run went.

## How Grok runs it

The Practice section (only when the session has the tools):

- act as the interviewer, like a sharp YC partner: direct, curious,
  encouraging but honest;
- ask the returned question as written, one at a time, then stop and
  listen;
- after each answer, concise and specific feedback against the reference
  answer: what landed, what was missing, one way to sharpen it; never read
  the reference answer aloud unless asked; one follow-up when the answer
  is vague;
- then `record_practice_result` with a score and a one-line note, and
  `next_practice_question` in the same reply (the two run in parallel; the
  follow-up response asks the next question);
- stop when the user wants to or the questions run out: `end_practice`
  and a short summary;
- answer "how am I doing?" from the tools, never from made-up scores.

The general Tools section already asks for a few spoken words before a
call, which here is the feedback itself.

## Each run is a topic

A run is its own topic, titled "Practice: YC interview questions", so the
timeline shows it as one row and its summary is the run's record:

```
Practiced 10 of 30 questions in YC interview questions, average 68%.
- What are you building? 80%. Lead with the customer, then the product.
- Why now? 40%. Name the market shift; you only described the product.
…
```

`TopicLifecycle` implements `PracticeRunRecording`:

- **Opening.** The topic starts at the user's request (their latest
  utterance, as fed to the lifecycle or, if that hasn't happened yet, as
  stored), split from the topic before it, which closes and is refined as
  usual. If nothing came before the request in that topic (practice was
  the first thing said), that topic becomes the run's.
- **During the run** the segmenter keeps scoring exchanges, but its
  boundaries are ignored: ten unrelated questions would otherwise make ten
  topics. Boundaries it raises later for exchanges up to the run's end are
  ignored too (the run drew those edges). The title is final, the summary
  is the tools' (a labeler never replaces it, on close or otherwise), and
  re-segmentation leaves the topic alone.
- **Edits later.** A "Merge with Previous" or "Split Here" from the
  timeline relabels the topics it touches, also after the conversation
  finished or the app relaunched, when the lifecycle no longer tracks the
  run. `TopicLifecycle.refine` therefore also checks the stored topic: one
  `PracticeRunTopic` recognizes keeps its title and summary (merging the
  next topic into the run's, or splitting the run's own topic, leaves the
  run's part with its record; a new part split off is labeled as usual).
  The guard is in `refine`, not `ConversationStore.applyTopicLabel`, since
  the run's own updates write through that. The other direction, "Merge
  with Previous" on the run's own topic, is refused with
  `TopicLifecycle.EditError.practiceRun` ("A practice run keeps its own
  topic. Merge the next topic into it instead."): the store would delete
  the run's topic and keep the earlier one's title, so the record would be
  lost, and during a live run the lifecycle would go on recording to the
  deleted topic. `TopicLifecycle.merge` checks the live run state (which
  also covers a run renamed before its first answer) and the stored topic
  (`PracticeRunTopic`, for runs after the conversation or a relaunch).
- **Summary.** Rewritten after every recorded answer, so a run cut short
  (the conversation ends, the app is killed) still has its record.
- **Closing.** After `end_practice` the topic stays current until the user
  speaks again, so Grok's wrap-up stays in it; then a new topic opens at
  that utterance and is titled as usual. A conversation that finishes
  during a run closes it.
- **Never blocking.** Every request returns at once and the work runs on
  the lifecycle's queue, in order with the transcript, so a tool call never
  waits for a labeling call. A run started before the lifecycle has the
  conversation gets its topic on its next question.

`PracticeCoordinator` treats a run as over once its topic closed or its
conversation finished; without a recorder (no topic lifecycle), after 30
minutes untouched.

**Calls of one reply.** The tool runner starts the calls of one reply in
parallel, and every coordinator operation suspends (store reads and
writes, the recorder). Left to the actor alone they would interleave: an
`end_practice` could close the run while the same reply's
`record_practice_result` waited on the store, dropping that answer from
the wrap-up and its note from the record for good, and two
`next_practice_question` calls could each start a run. So `nextQuestion`,
`record` and `endRun` run one at a time, in the order they reach the
coordinator (an operation tail, like `TopicLifecycle`'s queue). The runner
starts each call in a detached task, so a result can still reach the
coordinator just after the `end_practice` of its own reply. A result for
the run that ended within the last 10 seconds
(`PracticeToolSettings.lateResultWindow`) therefore still joins that run's
record, and its topic's summary is refreshed with it.

**Consolidation leaves the record alone.** Profile consolidation (#67)
rewrites the summaries of closed topics in ended conversations as one
short sentence. A run's summary is its only record of the notes, so
`PracticeRunTopic` (BlauCore) marks a run's topic by its title prefix
("Practice: ") or, once the user renames it, by the record's headline
("Practiced N of M questions in …"). `ProfileTopic.acceptsSummary` is
false for such a topic, and `ConversationStore.replaceTopicSummary`
refuses to rewrite one too. The runs are still shown to consolidation, as
context.

## The practice record and iCloud

The record lives on `CollectionItem` in schema v2: `practiceCount`, `score`
(the latest scored attempt, `0...1`; an unscored attempt keeps it) and
`lastPracticedAt`. `PracticeStore.recordPractice` updates every CloudKit
copy of the item in one save on the synced store: one SQLite transaction
and one persistent-history transaction, which CloudKit mirroring exports
to the user's private database, so the stats show on their other devices
(test: `eachAttemptIsOneHistoryTransactionOnTheSyncedStore`). The run's
notes travel in the practice topic's summary, which syncs with the
conversation. No schema change was needed: the fields were added for this
issue in v2 (#61), and per-attempt notes didn't justify a v3 (a new
CloudKit record type and a migration) when the topic already carries them.

Two devices practicing the same question while offline merge last writer
wins per field (CloudKit's rule): the count can be one short. That's
acceptable for a practice counter; it is not a ledger.

## In the Collections screen

A collection's screen opens with **Practice with Grok** and its record:
Practiced (7 of 30), Average Score, Last Practiced and Up Next (what the
scheduler would ask first now). Each question shows "Practiced 3 times ·
80% · 2 days ago"; its editor shows the same with the date. The
collections list says "30 questions · 7 practiced".

## Wiring and flags

`AppEnvironment.live()` builds the `TopicLifecycle` first, then
`PracticeTools.coordinator(persistence:topics:)` (a
`DeferredPracticeStore` over the open container, replaced on an iCloud
account change, and the lifecycle as recorder) and adds the four tools
after the memory tools in `RealtimeSessionServices`' registry. They ride on
the `memoryTools` flag (Settings → Knowledge → Grok Can Search Memory):
practice reads the knowledge base, and turning memory tools off means Grok
doesn't read it.

## Telemetry

Each call is a `realtime.toolCall` interval (#38). `Log.realtime` notes a
run starting and ending with counts; `Log.data` notes each attempt
(scored or not); `Log.topics` the practice topic opening and closing.
Prompts, answers, notes and scores are never logged.

## Testing

| What | Where |
| --- | --- |
| Scheduling: never practiced first, worse and older first, intervals, no repeats in a run, ties; collection name matching; what marks a run's topic | `BlauCoreTests/PracticeSchedulerTests` |
| The store: collections and their record, item order and answers, attempts and clamping, CloudKit copies, one history transaction per attempt on the synced store, the deferred store following the container | `BlauPersistenceTests/Knowledge/PracticeStoreTests` |
| The tools over fakes: a full ten-question run (order, answers, scores, the topic's summaries), the next run's order, switching collections, runs ending, calls of one reply (a result and the end, two next questions, a result just after the end), scores and ids, listing and the budget, failures, the instructions | `BlauRealtimeTests/Tools/PracticeToolsTests` |
| Consolidation never rewriting a run's record, renamed or not | `BlauMemoryTests/Profile/ProfileConsolidatorTests`, `BlauPersistenceTests/ConversationStoreTopicEditTests` |
| Function calls from the scripted server (`ScriptedRealtimeServer.Reply.functionCalls`) | used by the integration test |
| Topics: a run from the request to the next thing the user says, no topics inside it, labels never replacing its title or summary, the first topic taken, a finished conversation, a merge or split after it finished, a second run | `BlauTopicsTests/Lifecycle/PracticeTopicTests` |
| End to end: a full run of ten questions by voice through the real client, orchestrator, tool runner, tools, SwiftData store and topic lifecycle, with a scripted Grok interviewing | `BlauKitIntegrationTests/PracticeModeIntegrationTests` |
| The app's wiring: declared and taught, drilling the open store, "Practice with Grok" as the user's turn, the Collections screen's record | `BlauTests/PracticeModeAppTests` |

```sh
cd Packages/BlauKit && swift test --filter Practice
```

## On a device

Needs an iPhone (and a second device for sync), real xAI credentials and an
enrolled voice:

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | Paste a YC question list (with some `A:` answers) as a collection. Start a conversation and say "Let's practice YC questions". | Grok says a few words and asks question 1 as written. The timeline shows a "Practice: YC interview questions" topic from the request on. | pending |
| 2 | Answer ten questions out loud, some well, some badly, one vaguely. | After each: short feedback against the reference answer (never read out), a follow-up on the vague one, then the next question. No question repeats. | pending |
| 3 | Say "let's stop". | Grok sums up: how many, the average, what to work on. Saying something else afterwards starts a new topic. | pending |
| 4 | Open the collection in Settings → Knowledge → Collections. | Practiced 10 of N, the average, Up Next is an unpracticed or weak question; each answered question shows its score. The practice topic's summary lists the scores and notes. | pending |
| 5 | On a second device on the same iCloud account, open the collection after it syncs. | The same practice record. | pending |
| 6 | Tap **Practice with Grok** on a collection with no conversation running. | Settings closes, the conversation starts and Grok asks the first question. | pending |
| 7 | Start a new run the next day. | It opens with the weakest and least recently practiced questions. | pending |
