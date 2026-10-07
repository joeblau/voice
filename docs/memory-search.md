# Memory search

Hybrid retrieval over the memory index (#64, epic #9): BM25 for names and
jargon, vectors for paraphrases, fused by weighted reciprocal rank fusion,
aware of the time a query talks about, and expanded one hop through the
entity graph. It is what `search_memory` (#68) and the evaluation harness
(#70) call. The code is in `Packages/BlauKit/Sources/BlauMemory/Retrieval/`;
the index it searches is in [memory-index.md](memory-index.md).

```swift
let search = MemorySearch(
    index: index,                                  // MemoryIndex (#62)
    embedder: textEmbeddings,                      // TextEmbeddingService (#60), or nil for BM25 only
    entities: CachedMemoryEntityGraph(sources: SwiftDataMemorySources(container: container)))

let response = try await search.search("what did I say about fundraising last week", limit: 5)
for hit in response.results {
    print(hit.date, hit.sourceKind, hit.snippet)   // and hit.sourceID, hit.chunk, hit.signals
}
// Explicit bounds and kinds (what Grok's tool arguments map to):
try await search.search("pricing", after: start, before: end, kinds: [.document, .fact], limit: 10)
```

## Pieces

| Type | What it does |
| --- | --- |
| `MemorySearch` | The pipeline below; one `memory.search` signpost per search |
| `MemorySearchResponse` / `MemorySearchResult` | Results (chunk, snippet, fused score, signals, source, date) and how the search ran: the time filter or expression, whether vectors were used, entities the query named, facts expansion added |
| `RankFusion` | Weighted reciprocal rank fusion over any `Hashable` ids |
| `TemporalQueryParser` | Finds the time range a query talks about, relative to `now` |
| `MemoryEntityGraph` | Entities (names, aliases) and their facts' subjects and validity, with whole-word name matching |
| `CachedMemoryEntityGraph` | Keeps the graph between searches; reloads after `invalidate()` or a minute |
| `SwiftDataMemorySources.entityGraph()` | Reads `MemoryEntity` and `Fact` from the synced store, merging CloudKit duplicates |
| `MemoryQueryEmbedding` | Embeds the query; `TextEmbeddingService` and `TextEmbeddingModel` conform |
| `MemoryReranker` | The optional cross-encoder hook (Qwen3-Reranker-0.6B); off unless one is passed |
| `MemorySearchService` | `MemorySearch` behind BlauCore's `MemoryService` (snippets as `MemoryHit`s) |
| `MemorySearchBenchmark` | `memory.search50k`, the latency criterion |

## One search

1. **Time.** `after` / `before` are a hard filter on every ranking (and
   turn query parsing off). Without them, `TemporalQueryParser` looks for a
   time expression (below). A **relative** one ("last week", "yesterday",
   "3 days ago", "recently") is a soft filter: BM25 and vector search run a
   second time inside its range and both rankings join the fusion
   (`timeWeight` 1), so hits from the range come first and the rest still
   count. A **calendar** one ("in March", "March 14", "2025") doesn't boost
   by default (`calendarTimeWeight` 0).
2. **Candidates.** BM25 over the chunks' key texts and cosine over their
   int8 vectors, 50 each (`candidateDepth`), while the query is embedded
   and the entity graph loads. Without a model (not downloaded yet, or
   failing) the search runs on BM25 alone and says so
   (`usedVectors`, `vectorFailure`).
3. **Fusion.** Weighted RRF: `score = Σ weight / (k + rank)` with the
   vector ranking at weight 1, BM25 at 0.4 and `k = 20` (tuned below).
4. **Entity expansion.** Seeds are the entities the query names and those
   the top five fused hits name (or, for a fact hit, its subject). Each
   seed's valid facts (current ones; with a time filter or expression,
   those valid at some point in it), latest first, five per entity and 20
   in all, join the candidates at half the score of the hit that linked
   them (`expansionDecay`), the top hit's score for an entity the query
   names. A fact found anyway gets that added to its own score. So "what
   is my partner's job" finds "User's partner is Alex Moreno" through BM25
   and then "Alex Moreno designs gardens at a studio in Emeryville", which
   shares no word with the query. Facts about the user (no subject) are
   never expanded; invalidated ones only inside a time range they were
   valid in. An explicit `after` / `before` window stays a hard filter
   here too: a fact is expanded only if its chunk is dated (`validFrom`)
   inside the window, so a fact that became true before `after` and still
   held during the window is not added. Like every result, it must be in
   `timeFilter`.
5. **Dedupe.** One result per chunk, and one per text: the same note or
   fact created on two devices (case and whitespace ignored) shows once.
6. **Rerank** (optional). With a `MemoryReranker`, the top 20 are reordered
   by its scores; if it throws, the fused order stands.
7. **Cut.** The top `limit` (at most 50), each with a snippet: the chunk's
   text with whitespace collapsed, at most 320 characters, the window
   around the first word that shares a stem with a query word, cut at word
   boundaries with "…".

Results carry `signals`: `.keyword`, `.vector`, `.time` (in the query's
range), `.entity` (brought in by expansion, with `linkedEntityID`) and
`.reranked`.

## Fusion weights

#59 found that **equal-weight RRF (k = 60) lost 10 points of Recall@5** to
the dense model on its eval set (0.809 → 0.704 with Qwen3 256-d) and asked
#64 to weight the rankings and tune them on that set. Part of that loss was
the Python reference ranking every document by BM25, including those that
share no word with the query; the real index only returns matches. The
rest is weighting.

`HybridRetrievalEvalTests` measures it through the real index and
`MemorySearch`, hermetically: `scripts/embeddings/record_eval_vectors.py`
recorded Qwen3-Embedding-0.6B's 256-d int8 vectors for all 216 documents
and 200 queries (`Fixtures/RetrievalEvalVectors/`, 147 KB), which reproduce
#59's dense Recall@5 of 0.809 exactly. The sweep
(`BLAU_RETRIEVAL_TUNING=1 swift test --filter HybridRetrievalEvalTests`,
2026-10-08):

| BM25 weight | k = 10 | k = 20 | k = 30 | k = 60 |
| --- | --- | --- | --- | --- |
| 0 (dense only) | 0.809 / 0.714 | 0.809 / 0.714 | 0.809 / 0.714 | 0.809 / 0.714 |
| 0.2 | 0.809 / 0.722 | 0.802 / 0.716 | 0.804 / 0.714 | 0.814 / 0.711 |
| 0.3 | 0.812 / 0.725 | 0.812 / 0.718 | 0.819 / 0.716 | 0.807 / 0.710 |
| 0.35 | 0.814 / 0.728 | 0.822 / 0.720 | 0.814 / 0.715 | 0.794 / 0.707 |
| **0.4** | 0.822 / 0.729 | **0.824 / 0.721** | 0.804 / 0.713 | 0.792 / 0.703 |
| 0.45 | 0.822 / 0.724 | 0.824 / 0.714 | 0.812 / 0.711 | 0.782 / 0.695 |
| 0.5 | 0.819 / 0.725 | 0.809 / 0.712 | 0.799 / 0.698 | 0.782 / 0.688 |
| 1 (equal) | 0.807 / 0.689 | 0.799 / 0.674 | 0.794 / 0.669 | 0.794 / 0.666 |

(Recall@5 / MRR@10; every cell keeps all 9 keyword-style queries in the
top 5.) The defaults are **BM25 at 0.4 and k = 20**, in the middle of the
plateau at k = 10–20 and 0.35–0.45, rather than the issue's k = 60: at k =
60 no BM25 weight beats the dense model's MRR@10. The curve is so flat
there that a chunk both lists rank middling overtakes the dense ranking's
first place, which on paraphrases is usually the answer. The eval
set has 200 queries, so a point is two queries. #70's memory evaluation
swept the same weights on its own set and found it prefers more BM25
([memory-eval.md](memory-eval.md#tuning)); the sets disagree, so these
defaults stay.

| Ranking (personal eval set, top 10) | Recall@5 | Hit@5 | Hit@1 | MRR@10 | Recall@10 |
| --- | --- | --- | --- | --- | --- |
| BM25 alone (FTS5, the index's query builder) | 0.575 | 0.605 | 0.435 | 0.514 | 0.654 |
| Dense alone (Qwen3-Embedding-0.6B, 256-d int8) | 0.809 | 0.845 | 0.610 | 0.714 | 0.847 |
| **`MemorySearch` (defaults)** | **0.824** | **0.855** | **0.615** | **0.721** | **0.888** |
| `MemorySearch` without a model (BM25 + time + expansion) | 0.575 | 0.605 | 0.440 | 0.517 | 0.654 |

By category, hybrid Recall@5: company 0.809, YC answers 0.607, conversations
0.908, profile 0.971 (dense alone: 0.809, 0.552, 0.900, 0.971). The YC
answers stay the hardest slice, as in #59.

**The target** on this set: hybrid Recall@5 and MRR@10 at least the dense
model's own, and every keyword-style query BM25 finds still in the top 5.
`HybridRetrievalEvalTests` asserts it on every `swift test`, plus Recall@5
≥ 0.82 to catch regressions of the tuned defaults. The memory evaluation
(#70, [memory-eval.md](memory-eval.md)) adds question types (temporal,
knowledge updates, multi-hop, abstention), answer accuracy and its own
regression gate. EmbeddingGemma, the shipped model, is gated and not measured yet
([benchmarks.md](benchmarks.md#text-embedding-model-59)); rerun
`record_eval_vectors.py --model embeddinggemma-300m` and the sweep once it
is.

## Time expressions

The issue sketched `NSDataDetector` for relative dates. Measured on the
macOS 26 / iOS 26 SDKs, it **finds nothing** in "last week", "last month",
"in March", "3 days ago", "this year" or "past week"; it resolves what it
does find **against the wall clock** (it has no reference-date API, so
tests can't pin "now"); and it resolves **toward the future** ("March 14"
asked in October is next March, "Monday" is next Monday), while a memory
query is about the past. So `TemporalQueryParser` is a small English
grammar over the query's words, resolved against `now` in the device's
time zone and biased to the past, and `NSDataDetector` is the fallback for
what the grammar doesn't know (numeric dates such as "3/14" or
"12/24/2025"): only its calendar day is kept, plus the year when the query
wrote one, and the day is resolved against `now` like the grammar's.

| Query says | Range | Anchor |
| --- | --- | --- |
| today, tonight, this morning | today | relative |
| yesterday (morning…), the day before yesterday | that day | relative |
| last night | yesterday until 6 am | relative |
| this week / month / year | the calendar period so far | relative |
| last / previous week / month / year | the previous calendar period | relative |
| past week, last 3 days, past couple of weeks, past few months | rolling, until today | relative |
| 3 days ago | that day ±1 (yesterday for 1) | relative |
| a week ago, 2 weeks ago | the 7 days around that day | relative |
| 2 months ago, a year ago | that calendar month / year | relative |
| (last / on) Tuesday, this Friday | the most recent one before today; this week's | relative |
| last / this weekend | the most recent weekend | relative |
| recently, lately, the other day | the last 14 / 7 days | relative |
| March, in May, last March, March 2025 | that month, the most recent unless a year is given | calendar |
| March 14, 14 March, the 14th of March, Jan 5 | that day, likewise | calendar |
| in / during 2025 | that year | calendar |
| 3/14, 12/24/2025 (`NSDataDetector`) | that day | calendar |
| since / after X, before X, between X and Y, from X to Y | open or combined | from X (and Y) |

Weeks start on the locale's first weekday. "May", "Jan" and other
abbreviations only count next to a number or after a word like "in", so
"May I ask" and "what did Jan say" aren't dates; plurals ("on Mondays")
and bare years without "in" ("the 2023 price rise") aren't either. The
first expression in the query wins.

**Why calendar dates don't boost.** A named month or date usually says what
a memory is about, not when it was said: #59's eval asks "MRR August 2026",
"how many paying restaurants did we have in July" and "resolutions for this
year". With the boost on, "MRR August 2026" fell from first to seventh
(behind August conversations). Chunk keys already spell dates out
(`[March 14, 2026] …`, [memory-index.md](memory-index.md#chunking)), so
BM25 matches "March" and "14" when the user does mean when something was
said. Relative expressions have no such lexical hook, which is what the
boost is for. Expansion still uses either kind's range for fact validity.

## Entity expansion and the graph

`MemoryEntityGraph` is an immutable snapshot: entities with their names and
aliases (folded like the index's tokenizer, so case, diacritics and
punctuation don't matter, "Alex's" names Alex, and the longest name wins
where names overlap), and every fact's subject and validity interval. A
fact's chunk id is `MemoryChunk.id(kind: .fact, sourceID: fact.id, ordinal:
0)`, so expansion needs no extra index column. Single-word names that are
stop words ("It", "May") or one letter are never looked for.

Reading every entity and fact for each search would cost more than the
search, so `CachedMemoryEntityGraph` keeps the last graph: concurrent
callers share one load, a failed load isn't kept, and the graph reloads
after `invalidate()` (for the incremental indexer, #63, when entities or
facts change) or once it is a minute old. A graph that fails to load only
turns expansion off for that search.

## Reranker

`MemoryReranker.relevance(of:to:)` returns one score per candidate. The
intended implementation is Qwen3-Reranker-0.6B (a causal LM scoring P("yes")
for a templated query-document prompt) converted to Core ML like #59's
embedding models; it isn't converted or hosted yet, so nothing passes one
and the fused order stands. It reorders the top `rerankDepth` (20) only, and
a failure (including a wrong number of scores) keeps the fused order.

## Performance

The acceptance criterion is **p95 search latency under 50 ms**.
`memory.search50k` builds a 50,000-chunk on-disk index
(`MemoryIndexSearchBenchmark`'s synthetic corpus; a tenth of the chunks are
facts about 2,000 entities named after corpus words, a fifth of them since
invalidated), then runs 200 searches through the full pipeline with a
precomputed query vector: a third say "last week" (the time boost runs) and
a quarter name an entity. Query embedding is excluded; it is one text
through the shared service (`memory.embed`, #60).

| Metric | M3 Max (Mac reference) | iPhone 15 Pro (A17 Pro) |
| --- | --- | --- |
| `search` p50 / p95 (50k chunks, top 10) | 7.6 / 24.2 ms | pending |
| Facts expanded per search (mean) | 15.8 | |
| `build` / `load` (50k vectors) | 9.2 s / 195 ms | pending |

Mac: M3 Max, macOS 27.2, optimized build, 2026-10-08, on a machine shared
with many other builds (load average 200 to 700 during the run), so the
p95 is an upper bound. The same run measured #62's raw index at 2.1 / 4.8
ms p50 / p95 (`memory.index.search50k`): fusion, the second (time-range)
pass, expansion's chunk reads and snippets account for the rest.

Run it on the Mac with `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O
--scratch-path .build/optimized --filter MemorySearchBenchmarkTests`, and
on an iPhone with `make bench` (`MemoryIndexBenchmarks.testHybridSearch50k`)
or "Memory search (hybrid), 50k chunks" on the debug benchmark screen.

## Telemetry

Each search is one `memory.search` interval ([performance.md](performance.md)).
`Log.memory` at `debug`: counts per ranking, facts expanded, results and the
time taken, and why a search ran without vectors; at `error`: a graph that
failed to load or a reranker that failed. Queries and memory text are never
logged.

## Testing

| What | How |
| --- | --- |
| Quality (`swift test`) | `HybridRetrievalEvalTests`: #59's eval set through the real index with recorded Qwen3 vectors; the target above, and the BM25-only fallback keeping keyword queries. `MemoryEvalRetrievalTests`: #70's memory eval set against its thresholds ([memory-eval.md](memory-eval.md)) |
| Weight sweep (opt-in) | `BLAU_RETRIEVAL_TUNING=1 swift test --filter HybridRetrievalEvalTests` |
| Pipeline (`swift test`) | `MemorySearchTests`: fusion and signals, BM25-only fallback, limits and kinds, hard and soft time filters, calendar dates, multi-hop and query-named expansion, validity in a time filter, expansion kept inside an explicit window, graph failures, dedupe, reranker and its failure, snippets, the signpost, `MemorySearchService` |
| Pieces (`swift test`) | `RankFusionTests`, `TemporalQueryParserTests` (every row above against a fixed "now", time zones, first weekday, the `NSDataDetector` fallback), `MemoryEntityGraphTests` (matching, validity, duplicates, the cache, reading SwiftData) |
| Latency on the Mac (opt-in) | `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O --scratch-path .build/optimized --filter MemorySearchBenchmarkTests` |
| Latency on an iPhone | `make bench` or the debug benchmark screen |
| Re-record the eval vectors | `.venv/bin/python scripts/embeddings/record_eval_vectors.py [--model …]` (Hugging Face cache; `HF_HUB_OFFLINE=1` to stay offline) |
