# Memory tools

Grok pulls knowledge on demand during a voice conversation through four
client-side function tools (#68, epic #9): `search_memory`, `get_entity`,
`remember` and `forget`. They run on the device over the synced store and
the local search index; nothing about memory leaves the phone except the
tool outputs Grok asks for.

```
Grok ──function call──▶ TurnOrchestrator ─▶ RealtimeToolRunner ─▶ SearchMemoryTool … (BlauRealtime)
                                                                      │  MemoryToolBackend (BlauCore)
                                                                      ▼
                                       MemoryToolService (BlauMemory) ─▶ MemorySearch (#64) over MemoryIndex (#62)
                                                                      └▶ SwiftData: documents, topics, entities, facts
```

| Piece | Module | Role |
| --- | --- | --- |
| `MemoryToolBackend` and its value types | BlauCore | The contract. BlauRealtime and BlauMemory are siblings, so the protocol sits below both (architecture rule 2) |
| `MemoryToolService` | BlauMemory | The backend: hybrid search with sources, entity timelines, remembering and forgetting facts |
| `SearchMemoryTool`, `GetEntityTool`, `RememberTool`, `ForgetTool`, `MemoryTools` | BlauRealtime | The function tools: schemas, argument checks, output shaping and the token budget |
| Memory section of `RealtimeInstructions` | BlauRealtime | When to call which tool |
| `TurnOrchestrator` tool rounds | BlauRealtime | Runs the tools inside a turn and asks for the follow-up |
| `ChatToolCall`, `ChatToolChip` (rows under the timeline's bullets) | BlauRealtime, app | "Searched memory" in the chat; the full payload in DEBUG |
| `MemoryTools.service(indexing:textEmbeddings:)`, `.registry(backend:enabled:)` | app | The composition root: the backend over the indexing controller's current store and index, behind the `memoryTools` flag |

## The tools

### `search_memory(query, after?, before?, kinds?, limit = 8)`

Hybrid retrieval (#64: BM25 + vectors, weighted RRF, time expressions,
entity expansion) over past conversations, the knowledge base and facts.

| Argument | Meaning |
| --- | --- |
| `query` | Plain words. Time words ("last week") stay in it: `MemorySearch` ranks memories from that time first, which #64 tuned as a soft filter |
| `after`, `before` | A hard window: `YYYY-MM-DD` (that day's start in the user's time zone), `YYYY-MM`, or an ISO 8601 date-time. `before` is exclusive; the same day as both bounds means that whole day |
| `kinds` | Any of `conversation`, `company`, `profile`, `note`, `collection`, `fact`. Plurals and `document` / `knowledge_base` (every document kind) are accepted too |
| `limit` | 1 to 10 |

Output, best first:

```json
{"results":[
  {"date":"2026-10-02","kind":"company","source":"Company · Larderly","text":"Inventory and food-cost app for independent restaurants…"},
  {"date":"2026-09-30 14:05","kind":"conversation","source":"Conversation · Fundraising","text":"…"},
  {"date":"2026-03-01","id":"6F1C…","kind":"fact","source":"Fact · told by the user","text":"User lives in Austin","until":"2026-09-01"}]}
```

- **Source and date** on every result: the document's kind and title, the
  conversation's topic, a collection's name, whether a fact was told by the
  user or inferred. Dates are in the user's time zone; conversations carry
  the minute.
- **Facts carry their id**, which is what `forget` takes. Only facts do:
  documents are edited in the knowledge base, not forgotten by voice.
- **Narrowing documents by kind.** The index stores "document", not which
  kind, so `MemoryToolService` searches four times the hits wanted and
  keeps the documents of the kinds asked for (one store lookup per search).
- **The company question.** When a search narrowed to the knowledge base
  (`company`, `profile`, `note`) finds nothing, the company and profile
  documents asked for are read from the store (most recently edited first,
  700 characters each; notes are too many to list in place of a search). On a fresh install the
  embedding model isn't downloaded yet and "what does my company do?"
  shares no word with a document that says "Inventory and food-cost app for
  independent restaurants", so BM25 alone can't find it; the store can. The
  same path answers before the index exists.
- **Facts that no longer hold** (superseded, or forgotten) are left out of
  ordinary searches and come back, marked `until`, when the search is about
  a time (`after` / `before`, or a time expression in the query), so "where
  did I live last year" still works.
- **Without vectors** the output says `"note": "Matched on words only…"`.
- **Nothing found** is not an error: `{"results":[],"message":"Nothing in
  memory matches that."}`.

### `get_entity(name)`

Everything memory knows about one person, company, place or project:

```json
{"entity":{"name":"Alex Moreno","type":"person","aliases":["Alex"],
  "facts":[{"id":"…","origin":"conversation","since":"2025-01-10","text":"Alex Moreno worked at Stripe","until":"2026-06-30"},
           {"id":"…","origin":"conversation","since":"2026-06-30","text":"Alex Moreno designs gardens at Field Office"}]},
 "also_matching":["Alex Chen"]}
```

Names match the entity's name or an alias, ignoring case, diacritics and
punctuation: the same words score highest, then a name holding every word
asked for ("Alex" → "Alex Moreno"), then a name mentioned among other words
("my friend Alex Moreno"). CloudKit copies of one entity are merged by id.
The timeline is oldest first, current and past facts alike. No match is
`{"entity":null,"message":…}`.

### `remember(text, about?)`

Stores a fact the user told (`FactOrigin.user`), as one self-contained
sentence: the predicate is empty and the object holds the sentence, which
`Fact.statement()` returns as it is. `about` links it to the entity with
that name (or alias), creating one of type `other` if there is none; "me",
"the user" and the like mean the user. Saying the same thing again (case
and whitespace aside) returns the existing fact. The fact's chunk is
written to the index at once, embedded when the model is installed, so the
next search finds it; the incremental indexer (#63) then reconciles it with
the store's history.

### `forget(id, confirm?)`

Forgetting needs a spoken confirmation, and the tool enforces it rather
than trusting the prompt:

1. `forget(id)` changes nothing. It answers `"status":"needs_confirmation"`
   with the fact and an instruction to read it back and ask.
2. After the user says yes, `forget(id, confirm: true)` invalidates the
   fact (`invalidatedAt = now`) and answers `"forgotten"`.

The confirming call is only accepted in a **later tool chain** than the one
that asked. A chain starts with each response the runner didn't request
(the user's turn) and runs through the follow-ups it requests, and the
runner hands tools that number in a task-local
`RealtimeToolCallContext`. So Grok can't ask and confirm in one breath; the
user has to have spoken in between. A request expires after five minutes.
An id that isn't a fact fails with a message saying only facts can be
forgotten.

The issue's design says "invalidate", and so does the data model (facts
are add-only and validity-dated, #61): a forgotten fact stops being true
from that moment, leaves ordinary recall (and entity expansion, which only
adds current facts), and stays as history for time-scoped questions and the
entity timeline. Deleting outright would also remove it from the user's other
devices' history and can't be undone; if that's wanted it belongs in the
knowledge base UI (#65) or the privacy controls (#79).

## The token budget

Every output stays under **about 1,500 tokens** (`MemoryToolSettings
.maximumOutputTokens`, UTF-8 bytes / 4 like `ProfileBlock`): it becomes
conversation context and is paid for on every later turn. A result's text is
at most 700 characters (search snippets are 320). `search_memory` keeps
results best first while they fit, shortens the first one that doesn't if a
useful part fits, and counts the rest in `omitted`. `get_entity` drops the
oldest facts first (`earlier_facts_omitted`). Tests check the budget with
ten long hits and with an 80-fact timeline.

## When Grok calls them

The instructions get a **Memory** section whenever the session has the
tools (only the lines for the tools it has):

- search before answering anything the user told or wrote down before,
  their company or work, notes, or an earlier conversation; don't guess;
- `kinds: ["company"]` for the company, product, customers, team or
  traction, `["profile"]` for the user's background; keep time words in
  the query, use `after` / `before` only for exact dates;
- prefer newer results, treat `until` as no longer true, say so when
  nothing comes back;
- `get_entity` for "what do you know about Alex";
- `remember` when asked to, or for a lasting fact the user clearly wants
  kept, as one third-person sentence;
- `forget`: find the fact, ask, and confirm only after a yes.

The general Tools section already asks for a few spoken words ("let me
check") before a call, so a lookup never sounds like a dropped line. Each
tool's description repeats its essentials.

## Inside a turn

`TurnOrchestrator` takes the session's `RealtimeToolRegistry` (`tools:`)
and owns the `RealtimeToolRunner`:

1. It passes the runner every response, function-call and error event,
   **after** handling the event itself and in order, through one serial
   feed. Barge-in, a new or lost connection, an interruption and stop go
   through the same feed as "cancel everything", so a cancel can never
   overtake the next turn's events.
2. A `response.done` whose response made function calls (from
   `arguments.done`, `output_item.*` or the response's output) doesn't end
   the turn. What Grok said before the call is stored, its audio finished,
   and the turn waits (`agentThinking` once the filler has played), with
   `realtime.turn` still open.
3. The runner sends each output straight to the client, then asks for the
   follow-up through the orchestrator (`ToolEventRouter`), which sends the
   `response.create` tagged with the waiting turn and held while another
   response is active, exactly like the turn's own request. The follow-up's
   audio and transcript continue the same turn; it can call tools again.
4. The user talking over the filler or saying something new abandons the
   turn as before; the tool round is dropped with it (nothing more is sent
   for it, and there is no response to cancel). If the runner drops the
   round, or no follow-up is asked for within 20 s
   (`toolFollowUpTimeout`), the turn ends and Blau goes back to listening.

Before this issue the runner existed (#38) but nothing fed it, and the
orchestrator ignored (and deleted) any response it hadn't asked for, which
is what an untagged follow-up from the runner would have been.

## In the chat

Each call is a subtle centered chip ("Searching memory…", "Searched
memory", "Saved to memory", "Couldn't search memory") between the question
(and the "let me check") and the answer, from `TurnSnapshot.toolCalls`. The
current turn's chips sit with the reply as it plays; finished ones join the
stored rows by start time. In DEBUG builds the orchestrator keeps each
call's arguments and output (`keepsToolPayloads`) and tapping the chip
shows them, pretty-printed. Chips live in memory for the conversation on
screen: the store has no record of tool calls (adding one is a schema
change), so a relaunched conversation shows none.

## Wiring and flags

`AppEnvironment.live()` builds the `MemoryIndexingController` (#63) first,
then `MemoryTools.service(indexing:textEmbeddings:)`: a `MemoryToolService`
whose context is the controller's `toolContext` (the current store, index
and indexer, replaced on every iCloud account change), embedding queries
and remembered facts with the shared `TextEmbeddingService`. The same
service fills the `memory` slot (BlauCore's `MemoryService`). With the
`memoryTools` flag on (the default; read at launch), the four tools go into
`RealtimeSessionServices`' registry, so they are both declared in
`session.tools` and run by the orchestrator.

## Telemetry

- `memory.search` (#64) times the retrieval behind each `search_memory`.
- `realtime.toolCall` times each call from its arguments to its output, ending
  `search_memory succeeded`, `forget timed_out`…
- `Log.memory`: counts only (candidates, hits, whether vectors ran, entities
  matched, "stored a fact"); `Log.realtime`: tool rounds and follow-ups. No
  query, memory text or tool payload is ever logged.

## Latency

The acceptance criterion is that a tool round trip adds **under 300 ms
p50**. The client's share, from the call's arguments (and `response.done`)
reaching the runner to the follow-up `response.create` being sent, is
measured by `MemoryToolIntegrationTests.aToolRoundTripAddsWellUnder300Milliseconds`
over a real store and index with a hashing embedder:

| Knowledge base | Chunks | p50 / p95, M3 Max (Mac reference) | iPhone |
| --- | --- | --- | --- |
| 400 notes (every `swift test`, debug build) | 802 | 3.4 / 4.4 ms | pending |
| 10,000 notes (`BLAU_INDEX_BENCHMARK=1`, optimized) | 20,002 | 14.8 / 39.0 ms | pending |

Mac: M3 Max, macOS 27.2, 2026-10-08, on a machine shared with many other
builds (load average about 500), so the p95s are upper bounds. Before the
store fallback was limited to the company and profile documents, a
`kinds: ["company"]` search that missed read all 10,000 notes from the
store and the p95 was 818 ms; it now fetches only those documents.

What it leaves out, to add on a device: the query embedding (one text
through the shared service, about 12 to 20 ms per text on the M3 Max's
Neural Engine, docs/embeddings.md; iPhone pending), and the extra network
round trip for the output and the follow-up, plus Grok's time to start
answering, which only a live session shows. The second part needs real
xAI credentials and an iPhone: compare `realtime.firstAudio` for turns with
and without a tool call in the debug HUD or Instruments.

```sh
cd Packages/BlauKit
swift test --filter MemoryToolIntegrationTests
BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O --scratch-path .build/optimized \
  --filter "MemoryToolIntegrationTests/aToolRoundTrip"
```

## Testing

| What | Where |
| --- | --- |
| Backend over a real SwiftData store and index: sources and dates, narrowing by kind, the company question with and without an index, remember (indexed at once, deduplicated, linked to an entity), forget (hidden from ordinary recall, kept as history), entity matching and timelines | `BlauMemoryTests/Tools/MemoryToolServiceTests` |
| Tools over a fake backend: argument mapping and validation, dates in the user's time zone, the output format, the token budget, failures as messages, the spoken-confirmation rule | `BlauRealtimeTests/Tools/MemoryToolsTests` |
| Chains and call details in the runner | `BlauRealtimeTests/Tools/RealtimeToolCallContextTests` |
| Tool rounds in the orchestrator: the follow-up continues the turn, payloads, interruption, a round that never follows up, no runner | `BlauRealtimeTests/Turns/TurnOrchestratorToolTests` |
| The Memory instructions | `RealtimeInstructionsTests`, `SessionUpdateSnapshotTests` |
| Chips | `BlauRealtimeTests/Chat/ChatToolCallTests` |
| End to end: the `memory-tool` fixture replayed through the orchestrator with the real backend; remember, search, forget; the latency | `BlauKitIntegrationTests/MemoryToolIntegrationTests` |
| The app's wiring: declared, run, flag off, reading the open store | `BlauTests/MemoryToolsAppTests` |

## Needs a device or a live session

- Grok actually calling `search_memory` for "What does my company do?" and
  answering from the result (the replayed fixture shows the client side;
  the model's choice needs real xAI credentials).
- The tool round trip on an iPhone, end to end.
- The chip and its DEBUG payload sheet on screen.
