# Memory index

The local search index behind memory search (#62, epic #9): every
conversation exchange, knowledge-base document, collection item and fact
cut into chunks, full-text indexed with **SQLite FTS5 (BM25)** and, once
embedded by the shared text embedding service ([embeddings.md](embeddings.md)),
carrying a **256-d int8 vector** that is searched by brute force with
Accelerate. Hybrid retrieval (#64, [memory-search.md](memory-search.md))
fuses the two rankings; the incremental indexer (#63,
[memory-indexer.md](memory-indexer.md)) keeps the index current and is
what builds it in the app. The code is in
`Packages/BlauKit/Sources/BlauMemory/Index/`.

The index is **derived data**: local only, never synced, excluded from
backups, and fully rebuildable from SwiftData ([data-model.md](data-model.md)).

```swift
let index = try MemoryIndex.open(at: StoreLocation.applicationSupport.memoryIndexURL)

// Build it (or rebuild it) from SwiftData.
let rebuilder = MemoryIndexRebuilder(
    index: index, sources: SwiftDataMemorySources(container: container), embedder: textEmbeddings)
if try await index.needsRebuild { try await rebuilder.rebuild() }

// At launch, load every vector of the installed model into the matrix.
try await index.loadVectors(modelVersion: try await textEmbeddings.currentModelVersion())

// The raw rankings; MemorySearch (#64, memory-search.md) fuses them.
let query = try await textEmbeddings.embed(["ramen place in Osaka"], as: .query)[0]
async let vector = index.vectorSearch(query, limit: 50)
async let keyword = index.keywordSearch("ramen place in Osaka", limit: 50)
let chunks = try await index.chunks(withIDs: (try await keyword).map(\.chunkID))

// Hybrid search: fusion, time, entity expansion, snippets.
let results = try await MemorySearch(index: index, embedder: textEmbeddings).search("ramen place in Osaka")
```

## Pieces

| Type | What it does |
| --- | --- |
| `MemoryIndex` | The SQLite file (GRDB `DatabasePool`, WAL): chunk rows, the FTS5 table, the vector blobs; the in-memory `VectorMatrix`; keyword and vector search; writes that keep both in step |
| `VectorMatrix` | Every vector of one model version in one contiguous `[Int8]`; O(1) add and remove; brute-force cosine top-K with `vDSP_vflt8` + `vDSP_mmul`; kind and time filters |
| `MemoryChunk` | One chunk: `text` (what a hit shows), `keyText` (what is indexed and embedded), source, ordinal, `contentHash`, `createdAt`, topic and conversation |
| `MemoryChunker` | Cuts snapshots into chunks, deterministically (below) |
| `ChunkingPolicy` | Chunk size (from the model's sequence length), overlap, facts per exchange, time zone of the dates in keys |
| `KeywordQuery` | Turns a plain-text query into a safe FTS5 pattern |
| `MemoryIndexRebuilder` | Rebuilds the index from a `MemorySourceProvider`, reusing every vector whose key text didn't change; fills in missing vectors. The app uses the incremental indexer's resumable pass instead ([memory-indexer.md](memory-indexer.md)); this one-shot rebuild is the reference the indexer's tests compare with |
| `SwiftDataMemorySources` | Reads conversations, documents, collection items and facts from the synced store as Sendable snapshots, merging CloudKit duplicates; also the indexer's `MemorySourceReader` (sources by id) |
| `MemoryChunkEmbedding` | What the rebuilder embeds with; `TextEmbeddingService` and `TextEmbeddingModel` conform |
| `MemoryIndexSearchBenchmark` | The 50k-chunk search benchmark (`memory.index.search50k`) |

## Schema

One SQLite file, `Application Support/Blau/Derived/MemoryIndex.sqlite`
(`StoreLocation.memoryIndexURL`, next to the derived SwiftData store):

| Table | Holds |
| --- | --- |
| `chunk` | `rowid`, `id` (UUID, unique), `sourceID`, `sourceKind`, `ordinal`, `text`, `keyText`, `contentHash`, `modelVersion`, `vector` (int8 × 256 blob), `vectorScale`, `createdAt`, `topicID`, `conversationID` |
| `chunk_fts` | FTS5 over `keyText`, external content (`content='chunk'`), tokenizer `porter unicode61 remove_diacritics 2`; kept in sync by triggers that fire only when the key text actually changes, so attaching a vector never rewrites the full-text index |
| `chunk_vocab` | `fts5vocab` over `chunk_fts`: how many chunks hold each stem (the common-word cutoff below) |
| `index_state` | When the last full rebuild finished (`rebuiltAt`), and the indexer's bookkeeping (`stateValue(forKey:)`): its rebuild checkpoint and the chunking the index was built with ([memory-indexer.md](memory-indexer.md)) |
| `fact_link` | `(conversationID, factID)`: the facts each conversation's exchange keys list (`SourceChunks.linkedFactIDs`), so editing or deleting a fact re-chunks its exchange |

`PRAGMA user_version` holds `MemoryIndex.schemaVersion` (2 since #63 added
`fact_link`). A file that isn't a database (`SQLITE_NOTADB`), is corrupt
(`SQLITE_CORRUPT`) or has another schema version is deleted and recreated
empty, and `needsRebuild` turns `true`: nothing in it is irreplaceable. Any
other failure to open (a full disk, or a file that can't be read because
the app launched in the background before first unlock) is thrown and the
file is kept, since recreating it would mean embedding every chunk again.
Bump the version when the schema changes.

A vector is stored with the `modelVersion` of the model that made it
([embeddings.md](embeddings.md#model-version)). Vectors of different models
are never compared: the matrix holds one version, a search with a query
from another model loads that model's rows instead, and
`chunksNeedingEmbedding(modelVersion:)` lists the rows to re-embed.

## Chunking

`MemoryChunker` works on Sendable snapshots, never on `@Model` objects, and
is deterministic: the same SwiftData state always gives the same chunk ids
(`MemoryChunk.id(kind:sourceID:ordinal:)`, a SHA-256 of kind, source and
position, pinned by a test) and the same key texts. That is what lets a
rebuild keep vectors.

**Conversations: one exchange per chunk.** An exchange is the user's turn
and Blau's reply, grouped exactly like the topic segmenter's
`ExchangeAssembler` (a user utterance after Blau has spoken starts the next
one; system utterances, partials and blank text are skipped). The key text
is the exchange with LongMemEval's fact-augmented prefix, and the previous
exchange as a one-exchange overlap after it:

```
[March 14, 2026] [Fundraising] facts: Sequoia led the seed round
User: We closed the seed round with Sequoia leading.
Blau: Congratulations! How much did you raise?
Earlier: …the end of the previous exchange
```

- The date is the exchange's start, spelled out in English (Gregorian, the
  policy's time zone) so it doesn't depend on the device locale. Spelled-out
  months also give BM25 and the embedding something to match "in March"
  against. The incremental indexer pins the time zone in the index the
  first time it runs, so travelling doesn't re-chunk and re-embed every
  chunk whose date would change ([memory-indexer.md](memory-indexer.md)).
- The topic is left out while it still has its placeholder title.
- `facts:` lists the facts extracted from the exchange's utterances
  (`Fact.sourceUtteranceID`), at most five and at most half the budget.
  Invalidated facts are left out (#173): a superseded statement ("User
  lives in Berlin") would keep boosting the exchange for the old value and
  take one of the five places. They stay in the exchange's fact links
  (`fact_link`), so un-invalidating or editing one re-chunks the exchange,
  and each stays searchable as its own chunk with `(until …)`. Writing
  `<statement> (until <date>)` in the prefix instead was considered; it
  boosts the exchange for the old value all the same.
- The overlap comes **after** the exchange, so if anything is cut by the
  model's 128-token window it is the context, never the exchange itself.
  It is trimmed from the front (`…`) to fit.
- An exchange too long for one chunk is split at sentences (words, then
  characters, if it must); each piece keeps the prefix and the piece
  before it as its overlap.

**Documents: split by heading and paragraph.** Markdown ATX headings set a
heading path; paragraphs are packed greedily into chunks, and a heading
starts a new chunk once the current one has `minimumDocumentTokens`. Each
key is prefixed with the title and the heading path, e.g. `[Larderly]
[Pricing › Enterprise]`. A document with no body is one chunk holding its
title.

**Collection items: one chunk each**, the prompt and its reference answer,
keyed with the collection's title (`[YC interview]`). An item is never
split; an answer longer than the model's window is embedded from its start
and still fully searchable by BM25.

**Facts: one chunk each**, `[January 15, 2026] Sequoia led the seed round`,
with `(until …)` once a fact is invalidated, so "where did I work in March"
can still find it.

### Chunk size

The issue sketched 200–400-token document chunks. The shared embedding
model (#60) reads 128 tokens, prompt included, so a 400-token chunk would be
embedded from its first quarter only. Chunk sizes therefore follow the
model: `ChunkingPolicy.forSequenceLength(n)` allows 7/8 of the window (the
margin covers the token estimate), capped at 400, with documents breaking at
headings from half of that. For the shipped model that is **112 tokens**;
a 512-token model would get the issue's 200–400.

Tokens are counted with `ApproximateTokenCounter`, not the model's
tokenizer, so chunk boundaries don't move when the model is installed or
replaced: the FTS rows stay put and only vectors are (re)computed. A
`TextEmbeddingModel` is also a `ChunkTokenCounting` if exact counts are
ever wanted.

The estimate is meant never to fall below EmbeddingGemma's real count
(#173), so a chunk that fits is never truncated when it is embedded. Per
Unicode scalar, plus 9 for the prompt, `<bos>` and `<eos>`:

| Text | Tokens |
| --- | --- |
| A run of ASCII letters | Its weight / 5, rounded up; a lowercase letter weighs 1, an uppercase one 3, and a letter next to a digit at least 4 |
| An ASCII digit | 1: Gemma splits numbers into single digits |
| A space | 0 before an ASCII letter (it becomes part of `▁word`), else 1 |
| Other ASCII: punctuation, symbols, newlines | 1 |
| U+0100–U+036F: Latin Extended, IPA, combining marks | 2: the rarer ones fall back to UTF-8 bytes |
| Any other 2- or 3-byte scalar: accents, Cyrillic, CJK, Thai... | 1 |
| A 4-byte scalar: emoji, CJK Extension B... | 4: one token per byte when it isn't in the vocabulary |

It was checked against the model's own `tokenizer.json` (from
`unsloth/embeddinggemma-300m@bfa3c846`, byte-identical to the gated
`google/embeddinggemma-300m` file: same SHA-256, `6852f8d5…`) through
`TextEmbeddingModel.tokenCount(of:as:)` on 55 samples: digit-heavy text
(order numbers, phone numbers, dates, money, hex, UUIDs), Chinese, Japanese
and Korean, emoji (including ones outside the vocabulary), fourteen
samples of other scripts, symbols and code, and English. It is at or above the model's count
on every one, exact on a run of digits, and also on all 265 memory-eval key
texts. It overestimates English by about a quarter (1.23× on the eval key
texts) and non-Latin scripts by two to three times, where a token covers
several characters. `ApproximateTokenCounterTests` holds the measured
counts; `BLAU_EMBEDDINGGEMMA_TOKENIZER=<dir with tokenizer.json> swift test
--filter EmbeddingGemmaTokenCountTests` measures them again.

The rule it replaced, UTF-8 bytes / 4, fell short by up to two thirds on
digit-heavy text (28 for a 76-digit number the model reads as 85 tokens)
and below the real count on 155 of the 259 eval key texts; 9 of them went
past the 112-token budget (the largest 127). With the new rule the largest
eval chunk is 98 tokens. The rule #173 started from (one token per digit
and per scalar of 3 or more bytes, bytes / 4 for the rest) still fell short
on 30 of the 55 samples: a space before a number, punctuation, mixed case
and characters outside the vocabulary are tokens of their own.

`ProfileBlock.approximateTokenCount` keeps bytes / 4. The profile is
pinned to Grok's context, which has another tokenizer and room to spare,
and its 1,500-token budget is a target for consolidation, not a window that
cuts text off.

A change to the chunking rules bumps `MemoryIndexer.chunkingVersion`, part
of the chunking fingerprint (`v2` since #173), so every existing index gets
one full pass ([memory-indexer.md](memory-indexer.md)).

## Writing

`replace(_:embeddings:)` replaces all chunks of one or more sources in one
transaction. Per chunk:

| Chunk | Vector |
| --- | --- |
| In `embeddings` | Stored, with its model version |
| Same id and `contentHash` as before | Kept |
| New, or its key text changed | None until `setEmbeddings`; keyword search finds it at once |

Chunks a source no longer has are deleted (from FTS too, by trigger).
`setEmbeddings` stores vectors only if the chunk still has the hash that was
embedded, so a chunk re-cut while it was being embedded never gets a stale
vector.

Every write runs on GRDB's serial writer, and the in-memory matrix is
updated there right after the commit, so the matrix always matches the
file. Searches run concurrently with writes (WAL).

## Searching

**Vector search** (`vectorSearch`) never touches SQLite once the matrix is
loaded. The query's int8 codes are multiplied against the matrix in blocks
of 256 rows (converted to `Float` with `vDSP_vflt8`, multiplied with
`vDSP_mmul`; int8 dot products are exact in `Float`), divided by both
norms (the same cosine as `TextEmbedding.cosineSimilarity(to:)`), filtered
by kind and time, and the best `limit` kept in a heap. 50k × 256 codes are
12.8 MB. Issue #1 sets the switch to an HNSW index (USearch) at around
200k chunks.

**Keyword search** (`keywordSearch`) is BM25 over the key texts.
`KeywordQuery` never lets query text act as FTS5 syntax: it splits the text
into words (letters and digits, folded like the index's tokenizer), drops
English stop words unless nothing else is left, quotes each word and joins
them with `OR`. FTS5 computes `bm25()` for every matching row, so a word
that appears in thousands of chunks makes a query cost tens of
milliseconds while adding almost nothing to the ranking (its IDF is tiny).
Like Lucene's `CommonTermsQuery`, words in more than
`commonTermDocuments(chunkCount:)` chunks (0.5% of the index, at least 256)
are left out when the query has rarer words; a query of only common words
matches chunks containing all of them. When no query word is common (as on
any index of a few hundred chunks), the ranking is exact BM25. Without filters the FTS
table is ranked alone and only the top rows are looked up; with filters it
is joined with `chunk`.

Which words are common is decided over the whole index, not within the
filter, so a filtered search could otherwise come back empty: in "Sequoia
fundraising" filtered to last week, "Sequoia" may only occur in older chunks
while last week's chunks only say "fundraising". A filtered search that
finds fewer than `limit` chunks with the narrowed pattern therefore runs
again with every query word `OR`'ed and returns that exact BM25 ranking.
That second pass walks every chunk holding a common word, so it costs more;
only filtered searches that came up short pay for it. Unfiltered searches
keep the cutoff, since a rare word in the index always matches something.

Scores: BM25 (negated `bm25()`, higher is better) and cosine. They are only
comparable within one search; `MemorySearch` (#64) fuses ranks, not scores
([memory-search.md](memory-search.md)).

## Rebuilding

`MemoryIndexRebuilder.rebuild()` reads every conversation (16 at a time),
document, collection item and fact through `MemorySourceProvider`, chunks
them, embeds what has no current vector (in batches of 256 chunks, which
the embedding service runs 32 at a time), writes, removes sources that no
longer exist, and records the rebuild. It doesn't empty the index first:
search keeps working while it runs, an interrupted rebuild resumes cheaply,
and a rebuild with nothing changed embeds nothing. `reembedAll: true`
recomputes every vector.

Without a model (not downloaded yet, or failing to load or run), the
rebuild finishes for keyword search, `report.embeddingFailure` says why,
and `embedMissingVectors()` fills the vectors in once the model works.

The index is fully rebuildable from SwiftData: `SwiftDataRebuildTests`
builds it from a real SwiftData store, deletes the file, rebuilds, and gets
the same chunks, the same vectors and the same search results; a deleted
document disappears on the next rebuild. `SwiftDataMemorySources` merges
records CloudKit duplicated (one conversation, document or fact created on
two devices): utterances and topics are combined by id, the most recently
edited document wins, and a fact keeps its earliest invalidation.

## Performance

The acceptance criterion is **a search over 50k chunks within 20 ms p95 on
an A17**. `memory.index.search50k` measures it ([benchmarks.md](benchmarks.md#memory-index-62)):

| Metric | M3 Max (Mac reference) | iPhone 15 Pro (A17 Pro) |
| --- | --- | --- |
| Hybrid (vector + BM25 at once) p50 / p95 | 2.6 / 5.0 ms | pending |
| Vector p50 / p95 | 2.4 / 3.6 ms | pending |
| BM25 p50 / p95 | 1.5 / 3.7 ms | pending |
| Loading 50k vectors at launch | 422 ms | pending |

## Telemetry

`Log.memory`: opening failures and recreation at `error`, matrix loads and
rebuild start and end (counts, duration) at `notice`. Text and queries are
never logged. The fused search (`MemorySearch`, #64) is one
`memory.search` interval ([performance.md](performance.md)).

## Testing

| What | How |
| --- | --- |
| Chunking (`swift test`) | `ExchangeChunkingTests`, `DocumentChunkingTests`, `MemoryChunkIdentityTests`, `KeywordQueryTests` |
| Token estimate (`swift test`) | `ApproximateTokenCounterTests`: at or above EmbeddingGemma's measured count on 55 samples, pinned values, the per-scalar rules. `EmbeddingGemmaTokenCountTests` (opt-in, `BLAU_EMBEDDINGGEMMA_TOKENIZER`) measures them again with the real tokenizer |
| Matrix (`swift test`) | `VectorMatrixTests`: agrees with brute-force `cosineSimilarity` across Accelerate blocks, swap-remove, filters, zero and mismatched vectors, top-K |
| Index (`swift test`) | `MemoryIndexTests`: round trip, BM25 with stemming, the common-word cutoff (with and without filters), FTS syntax in queries, filters, vector reuse, matrix updates on write, model-version isolation, persistence, corrupt and old-schema files recreated, an unreadable file kept, searching while writing |
| Rebuild (`swift test`) | `MemoryIndexRebuilderTests` (reuse, changes, deletions, new model, keyword-only fallback, a wrong vector count, cancellation, invalidated facts left out of exchange keys but still linked) and `SwiftDataRebuildTests` (the acceptance criterion, CloudKit duplicates) |
| BM25 quality (`swift test`) | `KeywordRetrievalEvalTests`: BM25 alone on #59's eval set finds every keyword-style query in the top 5 |
| 50k benchmark on the Mac (opt-in) | `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O --scratch-path .build/optimized --filter MemoryIndexSearchBenchmarkTests` |
| 50k benchmark on an iPhone | `make bench` (`MemoryIndexBenchmarks.testSearch50k`) or the debug benchmark screen |
