# Memory evaluation

The memory evaluation harness (#70, epic #9) measures how well Blau's
memory finds and answers things, LongMemEval style
([arXiv:2410.10813](https://arxiv.org/abs/2410.10813)), on a personal
dataset: months of one user's conversations with Blau, knowledge-base
documents, entities and validity-dated facts, and questions of five types.
It reports, for each retrieval system and question type:

- **Retrieval**: Recall@k, Complete@k (every piece of evidence in the top
  k), Hit@1, MRR@10, nDCG@10, and, for knowledge updates, whether the current
  record outranks the superseded ones.
- **Answers**: end-to-end accuracy, an LLM reading the top memories and an
  LLM judge grading its answer against the reference.

```sh
make eval-memory      # retrieval + answers; reports in .build/memory-eval
```

It is text only (no audio) and hermetic: the index is built from the
dataset with the app's own chunker and indexer, the vectors are recorded
(no model download), and the reader and judge are Apple's on-device model
(no key, no network). Retrieval takes about two seconds; the answers about
three and a half minutes on an M3 Max. Retrieval is also checked on every
`swift test` (`MemoryEvalRetrievalTests`), and a nightly CI job runs the
whole thing and fails on a regression ([below](#nightly-ci)).

## Results (2026-10-08)

Mac host (M3 Max, macOS 27.2), debug build, recorded
Qwen3-Embedding-0.6B vectors (256-d int8, the reference #64 was tuned on),
`MemorySearch` defaults, Apple's on-device model as reader and judge. The
full generated report, with every answer the judge rejected, is
[memory-eval/report.md](memory-eval/report.md); its JSON is the committed
baseline, [memory-eval/baseline.json](memory-eval/baseline.json).

Retrieval over the 95 answerable questions (top 10):

| System | Recall@5 | Complete@5 | Hit@1 | MRR@10 | nDCG@10 | Recall@10 | Current first |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **`hybrid`** (`MemorySearch` as the app runs it) | **0.900** | **0.874** | **0.663** | **0.781** | **0.808** | **0.979** | **0.650** |
| `hybrid-no-entities` (no entity expansion) | 0.884 | 0.832 | 0.695 | 0.803 | 0.822 | 0.968 | 0.450 |
| `bm25-fallback` (no embedding model) | 0.932 | 0.895 | 0.642 | 0.770 | 0.805 | 0.974 | 0.750 |
| `dense` (vectors alone) | 0.805 | 0.726 | 0.579 | 0.717 | 0.743 | 0.926 | 0.550 |

`hybrid` by question type, with answer accuracy:

| Type | Questions | Recall@5 | Complete@5 | MRR@10 | Current first | Answer accuracy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| single-fact | 30 | 1.000 | 1.000 | 0.772 | – | 93.3% (28/30) |
| temporal | 25 | 0.800 | 0.760 | 0.777 | – | 64.0% (16/25) |
| knowledge-update | 20 | 0.850 | 0.850 | 0.654 | 0.650 | 80.0% (16/20) |
| multi-hop | 20 | 0.925 | 0.850 | 0.925 | – | 70.0% (14/20) |
| abstention | 20 | – | – | – | – | 75.0% (15/20) |
| **all** | **115** | **0.900** | **0.874** | **0.781** | **0.650** | **77.4% (89/115)** |

The answer stage is deterministic: two runs of the same build gave the same
115 answers and verdicts (greedy decoding).

### Findings

- **On this set BM25 alone beats hybrid** (Recall@5 0.932 against 0.900).
  #59's set is mostly paraphrases, where the vector ranking wins and BM25
  weighs 0.4; this set's questions usually share a word with the memory
  that answers them, as spoken questions about one's own life tend to.
  The [sweep](#tuning) finds BM25 at weight 1.0 and k = 10 among the
  best here (0.958 / MRR 0.817), but on #59's set that drops MRR@10 to
  0.689, below the dense model alone, which #64's test forbids. The two
  sets pull in opposite directions, so the defaults stay; settle it on
  real queries once there are some, and with EmbeddingGemma's vectors
  (gated, not recorded yet).
- **Knowledge updates are where retrieval is weakest**: the current
  record ranks above the superseded one for only 13 of 20 updates.
  Nothing in the ranking prefers newer records, so "what's our MRR" finds
  the June and July MRR documents and the August figure in a YC answer
  before September's (`ku-07`, rank 6), and an earlier tempo run outranks
  the latest one (`ku-15`). Entity expansion helps (0.45 → 0.65), because
  it adds an entity's currently valid facts. A recency tiebreak, or
  ranking an invalidated fact below its replacement, is the obvious next
  step.
- **Relative times work; calendar ones don't boost.** "Last week",
  "yesterday", "on Sunday" and "two days ago" put the evidence first in
  12 of 14 questions (one of the 14 is "which POS systems does Larderly
  sync today", where "today" is read as a time, harmlessly). "In July",
  "at the end of September" and "in mid-September" miss the top 5 in 3 of
  5, by design (#64 turned the calendar boost off because it hurt "MRR
  August 2026"-style questions).
- **Entity expansion trades precision for coverage**: +1.6 points of
  Recall@5 and +4.2 of Complete@5, but Hit@1 falls from 0.695 to 0.663,
  because expanded facts land above the direct hit (`tr-09`: four facts
  that name Biscuit push July's ear-infection conversation to rank 8).
- **The reader is the bottleneck on reasoning.** With Recall@5 at 0.90,
  the on-device model gets 64% of temporal questions (date arithmetic:
  "109 days" for 76) and 70% of multi-hop right, and answers 4 of 20
  unanswerable questions from a near miss ("Biscuit is Sofia's dog"; a
  fifth abstained, but the judge misread it). Grok, the model that answers
  in the app, should do better; run it with `MEMORY_EVAL_READER=xai`
  ([pending](#pending)).
- **The on-device judge is good enough to gate on.** A manual read of all
  115 verdicts disagreed with 5: three correct answers rejected (`sf-19`,
  `mh-02`, `ab-04`) and two shaky ones accepted (`ku-11`, which also
  repeats the superseded plan, and `ab-06`, which lists memories without
  saying it doesn't know). About 96% agreement.

## What it measures

### The dataset

`Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/MemoryEval`, synthetic
(the user, Jordan Hale, and everyone else are fictional). It extends #59's
retrieval eval set, the same persona, with conversations that update or
contradict earlier ones:

| | Count | What |
| --- | ---: | --- |
| Sessions | 80 (89 exchanges) | July 6 to October 6, 2026: a Japan trip, half marathon training, hiring, an apartment lease, a seed round, a dog, a parent's birthday... |
| Documents | 65 | 56 company documents (MRR by month, team, pricing...), 8 notes, and a 45-item YC interview collection |
| Facts | 59 | Subject, predicate, object, validity; 6 since invalidated, 18 linked to the exchange they came from |
| Entities | 24 | People, the dog, companies, customers, funds |
| Questions | 115 | 30 single-fact, 25 temporal, 20 knowledge-update, 20 multi-hop, 20 abstention |

The questions are asked on Wednesday, October 7, 2026 at noon UTC (the
manifest's `now`), with Monday as the first day of the week, so "last week"
is always September 28 to October 4.

| Type | Example | Needs |
| --- | --- | --- |
| single-fact | "What did you suggest I eat on the morning of the race?" | One exchange, document or fact, said by the user or by Blau |
| temporal | "How did my tempo run go last week?", "How many days before the half marathon did I first run ten miles without knee pain?" | The time of what was said; distractors on the same subject at other times |
| knowledge-update | "How much does Biscuit weigh?" (32 pounds, then 35) | The latest record; the superseded ones are listed as `stale` |
| multi-hop | "What does my partner do for work now?" (partner → Alex → Alex's new job) | Two or more records joined through an entity |
| abstention | "What's my cat's name?" | Nothing: the right answer says memory doesn't know |

### Retrieval systems

| System | What runs |
| --- | --- |
| `hybrid` | `MemorySearch` with its defaults: BM25 + vectors fused by weighted RRF, the relative-time boost, entity expansion through the dataset's graph. The primary system: per-question results and the answers come from it |
| `hybrid-no-entities` | The same without the entity graph |
| `bm25-fallback` | `MemorySearch` without an embedding model, as before the model is downloaded |
| `dense` | `MemoryIndex.vectorSearch` alone |

The index is built by `MemoryIndexRebuilder` and `MemoryChunker` (the
shipped 128-token policy) from snapshots of the dataset, exactly as the app
builds it from SwiftData: one chunk per exchange with the date, topic and
extracted facts in its key, documents by section, one chunk per collection
item and per fact. A ranking is the evidence ids of the top 10 results,
each record once.

### Metrics

| Metric | Definition |
| --- | --- |
| Recall@k | Share of a question's evidence pieces in the top k. A piece can have alternatives (`"n-006\|f-biscuit-weight-2"`: the exchange or the fact extracted from it) |
| Complete@k | 1 if every piece is in the top k (LongMemEval's recall_all@k) |
| Hit@k | 1 if any piece is in the top k (recall_any@k) |
| MRR@10 | 1 / rank of the first evidence, 0 past rank 10 |
| nDCG@10 | Binary gain for the first record of each piece |
| Current first | Knowledge updates: 1 if the current evidence is in the top 10 and above every `stale` record |
| Answer accuracy | Share of questions the judge accepted. A reader or judge error, or a verdict that isn't yes or no, counts as wrong and as a failure |

Abstention questions have no evidence, so they count for answers only.

### Answers

The reader (`LLMMemoryEvalReader`) gets the top 8 memories from `hybrid`,
each with the date it was said or written and its kind, and "no longer true
since …" for an invalidated fact, plus today's date. It is told to answer
from them alone, prefer the most recent when they disagree, and say it
doesn't know otherwise. It stands in for Grok reading `search_memory`
results (#68): the same snippets, dated.

The judge (`LLMMemoryEvalJudge`) uses LongMemEval's grading prompts
(`evaluate_qa.py`) per question type: off-by-one day counts are accepted for
temporal questions, an answer that also mentions the old value is accepted
for knowledge updates as long as the updated answer is there, and for
abstention the question is whether the response says the question can't be
answered. One sentence is added for the small on-device judge: extra
details, dates or quotes are fine as long as the answer is there and nothing
contradicts it.

| Model | Id | Where |
| --- | --- | --- |
| Apple's on-device model (`FoundationModelsEvalLanguageModel`) | `apple-foundation-models` | Greedy, `.permissiveContentTransformations` guardrails (it transforms the user's own memories; otherwise money and health topics are refused), a fresh session per call. Needs Apple Intelligence; the default |
| Any OpenAI-compatible chat endpoint (`ChatCompletionsEvalLanguageModel`), xAI by default | the model id | Temperature 0, retries on 429 and 5xx. Local, opt-in runs only: the key comes from `XAI_API_KEY` in the shell, never from the repo or CI |

## Running it

| Variable | Default | |
| --- | --- | --- |
| `MEMORY_EVAL_READER` | `auto` | `auto` (the on-device model when it can run, else retrieval only), `foundation-models`, `xai`, `none` |
| `MEMORY_EVAL_JUDGE` | `auto` | The same choices; `auto` follows the reader |
| `MEMORY_EVAL_XAI_MODEL` | | The xAI model id, required for `xai`, with `XAI_API_KEY` set |
| `MEMORY_EVAL_REQUIRE_ANSWERS` | `0` | `1` fails when no reader can run |
| `MEMORY_EVAL_TYPES` | all | e.g. `temporal,multi-hop` |
| `MEMORY_EVAL_QUESTIONS` | all | e.g. `ku-07,tr-09` |
| `MEMORY_EVAL_LIMIT` | all | The first N questions |
| `MEMORY_EVAL_DATASET` | the bundled set | Another dataset directory |
| `MEMORY_EVAL_VECTORS` | the bundled recording | Another recorded-vectors file, or `none` (BM25 only) |
| `MEMORY_EVAL_OUTPUT` | `.build/memory-eval` | `report.json`, `report.md`, `summary.txt` |
| `MEMORY_EVAL_THRESHOLDS` | `docs/memory-eval/thresholds.json` | The gate; empty disables it |
| `MEMORY_EVAL_GATE` | `1` | `0` reports a failed gate without failing |
| `MEMORY_EVAL_BASELINE` | `docs/memory-eval/baseline.json` | Prints the change against it; empty disables it |
| `MEMORY_EVAL_CONFIGURATION` | `debug` | The `swift test` configuration |

`make eval-memory` runs `scripts/eval-memory.sh`, which runs
`MemoryEvalRunTests` with `BLAU_MEMORY_EVAL=1` (skipped otherwise, so
`swift test` stays fast). A run with a type, id or count filter is partial:
the gate then checks only the per-type limits of the types that ran.

To try Grok as the reader (and judge):

```sh
XAI_API_KEY=... make eval-memory MEMORY_EVAL_READER=xai MEMORY_EVAL_XAI_MODEL=<model id>
```

Its accuracy has no limits in the thresholds yet, so the gate notes it and
checks retrieval only.

### Code

`Packages/BlauKit/Sources/BlauMemory/Evaluation/Memory/`:

| Type | What it does |
| --- | --- |
| `MemoryEvalDataset` | Loads and validates a dataset directory (ids, references, dates, evidence) |
| `MemoryEvalCorpus` | The dataset as SwiftData-like snapshots, the entity graph, and chunk → evidence id |
| `MemoryEvalRecordedEmbeddings` | Replays recorded vectors by key-text hash (chunks and queries) |
| `MemoryEvaluator` | Builds the index, runs every system, answers and judges |
| `MemoryEvalRetrievalMetrics`, `MemoryEvalAnswerMetrics` | The metrics above |
| `LLMMemoryEvalReader`, `LLMMemoryEvalJudge` | The prompts, over any `MemoryEvalLanguageModel` |
| `FoundationModelsEvalLanguageModel`, `ChatCompletionsEvalLanguageModel` | The models |
| `MemoryEvalReport`, `MemoryEvalThresholds` | `report.json`, the tables, the comparison and the gate |

Tests in `Tests/BlauMemoryTests/Evaluation/Memory`: the dataset (the
committed set is well formed, every record becomes chunks and back,
validation errors), the metrics on hand-built rankings, the prompts and
verdict parsing, the chat-completions request and retries (fake transport),
the evaluator end to end on a small dataset with fake reader and judge, the
report and the gate, and `MemoryEvalRetrievalTests` on the committed set.

## Dataset format

A directory: `manifest.json` and any number of `*.json` files, each with
some of `entities`, `sessions`, `documents`, `facts` and `questions`, merged
in file-name order. Dates are ISO 8601 (`2026-09-15T19:00:00Z`) or a day
(`2026-09-15`, noon UTC).

```json
{"name": "blau-memory-eval", "version": 1, "consent": "Synthetic. …", "userName": "Jordan",
 "now": "2026-10-07T12:00:00Z", "timeZone": "UTC", "firstWeekday": 2}
```

```json
{
  "entities": [{"id": "alex", "name": "Alex Moreno", "aliases": ["Alex"], "type": "person"}],
  "sessions": [{"id": "s-2026-09-15-alex-new-job", "startedAt": "2026-09-15T19:00:00Z", "topic": "Alex's new job",
                "turns": [{"id": "n-003", "user": "Alex started the new job today…", "assistant": "Congratulations…"}]}],
  "documents": [{"id": "co-056", "kind": "company", "title": "MRR September 2026", "body": "…", "updatedAt": "2026-10-01"},
                {"id": "yc", "kind": "collection", "title": "YC interview questions", "updatedAt": "2026-09-01",
                 "items": [{"id": "yc-001", "prompt": "What are you working on?", "answer": "…"}]}],
  "facts": [{"id": "f-alex-job-2", "subject": "alex", "predicate": "works as", "object": "a senior park designer…",
             "validFrom": "2026-09-15T19:00:00Z", "source": "n-003"},
            {"id": "pf-003", "subject": "alex", "predicate": "works as", "object": "a landscape architect…",
             "validFrom": "2026-06-01", "invalidatedAt": "2026-09-15T19:00:00Z"}],
  "questions": [{"id": "ku-02", "type": "knowledge-update", "question": "What does Alex do for work?",
                 "answer": "A senior park designer for the City of Oakland's parks department.",
                 "evidence": ["n-003|f-alex-job-2"], "stale": ["pf-003"]}]
}
```

- Turns, documents, collection items and facts share one id namespace:
  they are what evidence cites. Turns are two minutes apart in a session.
- A fact reads like `Fact.statement()`: the subject entity's name (or
  `User`), the predicate and the object. `source` is the turn it was
  extracted from, which puts it in that exchange's key.
- `evidence` lists every piece an answer needs; `a|b` means either record
  will do. Abstention questions list none. `stale` (knowledge updates
  only) lists superseded records.
- The loader refuses a missing consent, duplicate ids, unknown references,
  facts invalidated before they start, records dated after `now`, and
  questions without evidence (or abstentions with some).

After editing the dataset, record the vectors again (below), run `swift
test --filter MemoryEval`, and update the baseline.

### Recording vectors

The hermetic runs replay vectors recorded once with a reference model,
keyed by the SHA-256 of each chunk's key text and of each question. The
key texts come from the Swift chunker, so export them first:

```sh
cd Packages/BlauKit && BLAU_MEMORY_EVAL_EXPORT=/tmp/memory-eval-texts.json swift test --filter MemoryEvalExportTests
cd ../.. && .venv/bin/python scripts/embeddings/record_memory_eval_vectors.py /tmp/memory-eval-texts.json
```

That writes
`Tests/BlauMemoryTests/Fixtures/MemoryEvalVectors/qwen3-embedding-0.6b-256d-int8.json`
(the Python environment is in [benchmarks.md](benchmarks.md); add
`HF_HUB_OFFLINE=1` to stay on the Hugging Face cache, and `--model
embeddinggemma-300m` for the shipped model once it is downloadable). A text
without a recorded vector fails the run with the command to run, rather
than quietly measuring BM25 alone; `MemoryEvalRetrievalTests` also checks
the recording holds exactly the current texts.

## Regression gate

[memory-eval/thresholds.json](memory-eval/thresholds.json) holds the lowest
acceptable value of each metric:

- **Retrieval**, per system overall, and for `hybrid` per question type.
  Retrieval is deterministic (recorded vectors, a fixed `now`), so the
  limits are the baseline less about one or two questions. They are checked
  on every `swift test` (`MemoryEvalRetrievalTests`, so a pull request that
  makes retrieval worse fails `package-tests`), by `make eval-memory` and
  nightly.
- **Answers**, per reader and judge (`apple-foundation-models`): overall
  accuracy, per type, and at most 5 failures. The on-device model changes
  with OS updates, so these leave five to fifteen points. They are checked
  only when that reader and judge ran.

A system in the thresholds that didn't run fails the gate (for example
`MEMORY_EVAL_VECTORS=none`: only `bm25-fallback` runs, and the gate reports
`hybrid`, `hybrid-no-entities` and `dense` as not run).

### Updating the baseline

After a change that moves the numbers on purpose (a new model or recording,
a retrieval change, new questions):

1. `make eval-memory MEMORY_EVAL_GATE=0` on a Mac with Apple Intelligence
   and read the comparison with the old baseline.
2. Copy `.build/memory-eval/report.json` to `docs/memory-eval/baseline.json`
   and `report.md` to `docs/memory-eval/report.md`.
3. Update [thresholds.json](memory-eval/thresholds.json) from the new
   numbers, with the margins above.
4. Update the results above and add a row to [History](#history).

`MemoryEvalRetrievalTests` checks that the thresholds accept the baseline,
cover every system and type, and that the baseline was made from the
current dataset.

## Tuning

`BLAU_MEMORY_EVAL_TUNING=1 swift test --filter MemoryEvalTuningTests`
sweeps `MemorySearch.Configuration` on this set (retrieval only), as #64
swept #59's. On 2026-10-08 (Recall@5 / Complete@5 / MRR@10 / current first):

| BM25 weight | k = 10 | k = 20 (default k) | k = 60 |
| --- | --- | --- | --- |
| 0.2 | 0.868 / 0.821 / 0.783 / 0.65 | 0.879 / 0.842 / 0.773 / 0.65 | 0.874 / 0.832 / 0.714 / 0.65 |
| **0.4 (default)** | 0.911 / 0.884 / 0.787 / 0.65 | **0.900 / 0.874 / 0.781 / 0.65** | 0.879 / 0.842 / 0.736 / 0.65 |
| 0.6 | 0.937 / 0.916 / 0.808 / 0.70 | 0.937 / 0.916 / 0.788 / 0.65 | 0.916 / 0.884 / 0.768 / 0.65 |
| 0.8 | 0.937 / 0.916 / 0.816 / 0.70 | 0.932 / 0.905 / 0.802 / 0.70 | 0.932 / 0.905 / 0.778 / 0.65 |
| 1.0 | 0.958 / 0.937 / 0.817 / 0.70 | 0.942 / 0.916 / 0.798 / 0.70 | 0.942 / 0.916 / 0.782 / 0.70 |

On #59's set (#64's sweep, same day), BM25 at 0.6–1.0 brings MRR@10 down
to 0.674–0.712, below the dense model's 0.714, which
`HybridRetrievalEvalTests` forbids; see the first finding. Expansion decay
0.5 (the default) is best on Recall@5; 0 gives up 1.6 points of Recall@5 and
0.20 of current first, 1.0 loses 4.2 points. The relative-time weight
matters (0 → 1: MRR@10 0.739 → 0.781); 2 changes nothing.

## Nightly CI

The `memory-eval` job in [ci.yml](../.github/workflows/ci.yml) runs nightly
(and from **Actions > CI > Run workflow** with **Also run the memory
evaluation**). It restores the package build from the `package-tests`
cache, runs `make eval-memory`, writes `report.md` to the run's summary page
and uploads `report.json`, `report.md` and `summary.txt` as
`memory-eval-report-<attempt>`, kept 90 days: the history, night by night.
It fails when the gate fails.

GitHub's macOS runners are virtual machines, and Apple Intelligence doesn't
run in a VM, so there the reader is unavailable: the job runs retrieval
(the gate's retrieval limits still apply) and the report says the answers
were skipped. To gate answers nightly too, run the job on a self-hosted
Apple silicon Mac with Apple Intelligence turned on (repository variable
`BLAU_CI_RUNNER`) and set `BLAU_CI_MEMORY_EVAL_REQUIRE_ANSWERS=1`, which
fails the job if the model can't run. `BLAU_CI_MEMORY_EVAL_READER`
overrides the reader (never `xai`: CI has no secrets,
[ci.md](ci.md#secrets)).

## Pending

| Check | How | Result |
| --- | --- | --- |
| First nightly run on CI | The `memory-eval` job's first artifact: retrieval should match the baseline exactly; answers skipped on the hosted runner | Pending |
| Answers gated nightly | A self-hosted runner with Apple Intelligence and `BLAU_CI_MEMORY_EVAL_REQUIRE_ANSWERS=1` | Pending |
| Grok as the reader | `MEMORY_EVAL_READER=xai` with a key; then add limits for it | Pending (needs an xAI key) |
| The shipped embedding model | Record EmbeddingGemma-300m vectors once the gated model is available ([benchmarks.md](benchmarks.md#text-embedding-model-59)) | Pending |

## History

| Date | Dataset | Vectors | hybrid Recall@5 / Complete@5 / MRR@10 | Answers (reader / judge) | Accuracy | Machine |
| --- | --- | --- | --- | --- | ---: | --- |
| 2026-10-08 | v1, 115 questions | Qwen3-Embedding-0.6B 256-d int8 | 0.900 / 0.874 / 0.781 | Apple on-device / Apple on-device | 77.4% | M3 Max, macOS 27.2, debug |
