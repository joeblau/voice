# Text embeddings

One text-embedding service, shared by memory (#62 - #68) and topic
segmentation (#52), built in #60 on the model #59 chose:
**EmbeddingGemma-300M, its 256-d Matryoshka prefix, stored as int8**
(`TextEmbeddingModelSpec.chosen`). The code is in
`Packages/BlauKit/Sources/BlauMemory/Embeddings/`.

```swift
// The composition root (Blau/Memory/TextEmbeddings.swift):
let textEmbeddings = TextEmbeddings.make(models: speechModels)

// Memory indexing (#62): batches of 32, every vector tagged with its model.
let vectors = try await textEmbeddings.embed(chunks, as: .document)
vectors[0].codes          // 256 × Int8
vectors[0].scale          // value ≈ code × scale
vectors[0].modelVersion   // "embeddinggemma-300m-256d-int8-r1+fp16.wint8.ti8.L128@<revision>"

// Search (#64):
let query = try await textEmbeddings.embed(["when did I start running?"], as: .query)[0]
query.cosineSimilarity(to: vectors[0])   // nil if the model versions differ

// Topic segmentation (#52, #54), through BlauCore's TextEmbedder:
let segmenter = StreamingTopicSegmenter(embedding: await environment.topicEmbedding())
```

## Pieces

| Type | What it does |
| --- | --- |
| `TextEmbeddingService` | The app's one instance (`AppEnvironment.textEmbeddings`). Loads the installed model on first use, shares one load among concurrent callers, reloads when `ModelManager` installs a new revision, unloads when the model is deleted, and remembers a failed load until the installation changes or `retry()` |
| `TextEmbeddingModel` | A loaded model: task prompts, tokenizer, Core ML network, Matryoshka cut, L2 normalization, int8. `embed(_:as:)` takes any number of texts and runs them 32 at a time |
| `TextEmbedding` | One stored vector: int8 codes, scale, `modelVersion`, token count, truncated tokens |
| `SharedTextEmbedder` | The model as a BlauCore `TextEmbedder`, for BlauTopics (which can't import BlauMemory) |
| `TextEmbeddingBundle` | An installed model directory and its `blau-embedding.json`, checked against Blau's own spec for the model |
| `HuggingFaceTokenizer` | The model's `tokenizer.json`, in Swift (below) |
| `TokenEmbeddingTable` | The memory-mapped token table, float16 or int8 (below) |
| `CoreMLTokenEmbeddingModel` | The Core ML network: fills `inputs_embeds` from the table, pads to the model's fixed length, masks the padding |
| `TopicEmbedding` (BlauTopics) | Which embedder a conversation's segmenter uses, with the matching `TopicConfig` |

## The installed model

`scripts/embeddings/convert_coreml.py` converts the model and prepares a
folder for hosting; `ModelManager` downloads that folder as
`ModelID.textEmbedding` ([models.md](models.md)):

```
blau-embedding.json                       spec id, prompts, widths, sequence length, numerics
EmbeddingGemma300M.mlmodelc/              inputs_embeds [1, 128, 768] + attention_mask → embedding [1, 768]
EmbeddingGemma300M.token-embeddings.i8    262,144 rows: float32 scale + 768 int8 codes
tokenizer.json                            Gemma 3 tokenizer
NOTICE                                    Gemma Terms of Use notice
```

`TextEmbeddingBundle` refuses a bundle whose prompts, widths or pooling
differ from `TextEmbeddingModelSpec` for the same model, so the index can
never store vectors made with the wrong prompt.

## Pipeline

For each text, `TextEmbeddingModel`:

1. **Prompts** it for its task (`TextEmbeddingTask`): EmbeddingGemma's
   `task: search result | query: ` for queries and `title: none | text: `
   for everything stored (the model card's retrieval prompts, the ones #59
   evaluated). The topic segmenter embeds exchanges as documents, so an
   exchange the indexer already embedded can be passed straight to
   `StreamingTopicSegmenter.append(_:embedding:)`.
2. **Tokenizes** it with `HuggingFaceTokenizer` and cuts it to the model's
   sequence length, 128 tokens including the prompt and `<bos>`/`<eos>`
   (`tokenizers`' right truncation). `TextEmbedding.truncatedTokens` says
   what was lost; `tokenCount(of:as:)` lets the indexer (#62) split a long
   exchange so nothing is.
3. **Runs the network**: the token rows are copied from the memory-mapped
   table into `inputs_embeds` (int8 rows dequantized to float16 on the way)
   and Core ML runs the fixed-shape model on the Neural Engine. Pooling and
   EmbeddingGemma's two dense layers are inside the model.
4. **Stores** the output: the first 256 components (Matryoshka), L2
   normalized, quantized to int8 with one scale per vector
   (`MatryoshkaEmbedding`, the same code #59's numbers came from).

A non-finite output (the float16 failure #59 warns EmbeddingGemma might
have) becomes a zero vector, which scores 0 against everything, plus a
fault in the `memory` log and `statistics.nonFiniteVectors`, rather than a
NaN in the index.

### Model version

Every vector carries `modelVersion`, for example
`embeddinggemma-300m-256d-int8-r1+fp16.wint8.ti8.L128@57c266a740f5`: the
spec's `vectorIdentifier` (model, stored width, int8, spec revision), the
numerics that change vectors (compute precision, weight compression, token
table format, sequence length) and the first 12 characters of the
installed files' pinned revision. Vectors with different versions are never
compared (`cosineSimilarity(to:)` returns `nil`); the index (#62) stores the
version per row and re-embeds when it changes. `SharedTextEmbedder` reports
it as `TextEmbedder.modelIdentifier`.

### Batches

`embed(_:as:)` runs up to 32 texts per batch (`TextEmbeddingModel
.defaultBatchSize`), each batch inside one `memory.embed` signpost interval
whose end message gives the text and token counts. Within a batch the texts
run one after another on the Neural Engine; on the M3 Max that already
costs about the same per chunk as single predictions in Python (12 ms), so
Core ML's batch API isn't used.

### Sequence length

#59 left it open whether long exchanges need a 256-token model. Blau ships
the 128-token model #59 measured: the Neural Engine compiler wants one fixed
shape, the latency budget is defined at 128 tokens, and the longest text in
the eval set is 78 Gemma tokens with its prompt. Longer chunks are
truncated, reported per vector and in `statistics.truncatedTexts`, and the
indexer can split them with `tokenCount(of:as:)`. A longer model only needs
`convert_coreml.py --lengths 256`; the service reads the length from the
bundle.

## Tokenizer

`HuggingFaceTokenizer` reads the model's `tokenizer.json` and implements the
part of Hugging Face `tokenizers` both candidate models use: added tokens
matched in the raw text (leftmost-longest); `Replace`, `NFC`/`NFD`/`NFKC`/
`NFKD`, `Lowercase`, `Prepend` normalizers; `Split` (string or regex, every
delimiter behavior) and `ByteLevel` pre-tokenizers; the BPE model with byte
fallback or a byte-level alphabet, merges applied by rank exactly like
`Word::merge_all`; and `TemplateProcessing` post-processing with truncation.
Anything else (WordPiece, Unigram, Metaspace, stripping added tokens) throws
`unsupported` instead of tokenizing differently.

It doesn't use Foundation's JSON parsers or Swift string equality for the
vocabulary: `JSONSerialization` drops a leading U+FEFF from strings and a
Swift `Dictionary` merges keys that are canonically equivalent, and Gemma's
vocabulary has tokens of both kinds. `TokenizerJSON` keeps every string's
scalars and `TokenKey` compares tokens byte for byte.

Swift Transformers' `Tokenizers` would have been the alternative; it brings
five more packages (Jinja, the Hub client, Collections, Crypto, yyjson) into
an app that only needs this.

**Parity.** On both real tokenizers the output is identical to the Python
`tokenizers` library on every one of 906 texts: the 416 eval-set texts with
their prompts, 36 edge cases (accents, combining marks, CJK, emoji with
joiners, byte-order marks, added tokens written in the text, long runs),
each plain and truncated to 128 tokens (`TokenizerParityTests`, opt-in,
below). Hermetic tests replay the same check on two tiny tokenizers with
the same layouts, trained by the reference library
(`Fixtures/Tokenizers/`, `scripts/embeddings/make_tokenizer_fixtures.py`).

## Token table

The model takes `inputs_embeds`, because the gather over the 262k-row table
keeps a whole transformer off the Neural Engine (#59). The table ships
beside it and is memory-mapped, so only the rows of tokens actually used
become resident. #59 shipped it as float16 and asked #60 to quantize it;
it is now **int8 with a float32 scale per row** (`.token-embeddings.i8`, the
`convert_coreml.py` default; `--table float16` keeps the old format):

| Model | float16 table | int8 table |
| --- | --- | --- |
| EmbeddingGemma-300M (262,144 × 768) | 403 MB | 202 MB |
| Qwen3-Embedding-0.6B (151,669 × 1,024) | 311 MB | 156 MB |

That halving is what keeps EmbeddingGemma inside #59's 400 MB download
budget (about 100 MB of int8 weights plus the table). It costs nothing
measurable: through the Swift path, Qwen3 has the same Recall@5 with either
table (below). `scripts/embeddings/token_table.py` converts an existing
float16 table or hosting folder.

## Measured (Mac reference)

Qwen3-Embedding-0.6B (#59's fallback; EmbeddingGemma's weights are gated,
see [benchmarks.md](benchmarks.md#text-embedding-model-59)), converted with
int8 weights, 128 tokens, M3 Max, macOS 27.2, `cpuAndNeuralEngine`,
optimized build, `RealTextEmbeddingModelTests`, on a machine shared with
other builds (latencies are upper bounds):

| | float16 table | int8 table |
| --- | --- | --- |
| Recall@5 / Hit@5 / MRR@10 (personal eval set, 256-d int8) | 0.797 / 0.830 / 0.708 | 0.797 / 0.830 / 0.711 |
| Same model through Python and `coremltools` (`convert_coreml.py`'s verification) | 0.797 / 0.830 / 0.708 | |
| `memory.embed.batch32`: 32 chunks of 124 tokens, p50 / p95 (budget 1,600 ms) | 633 / 688 ms | 681 / 714 ms |
| 32 eval chunks (42–72 tokens), p50 / p95 | 372 / 374 ms | 473 / 538 ms |

More in [benchmarks.md](benchmarks.md#shared-embedding-service-60).
**iPhone numbers are pending** (they need a device and the hosted
EmbeddingGemma model).

## Topic segmentation

`StreamingTopicSegmenter` takes any `TextEmbedder`; the composition root
passes `SharedTextEmbedder` through `TopicEmbedding`
([topics.md](topics.md)). `TopicEmbedding.best` picks, once per
conversation (vectors from different models can't share a similarity
window):

1. the shared service, with `TopicConfig.sharedEmbedding`;
2. Apple's `NLContextualTextEmbedder` if its OS assets are already on the
   device, with `TopicConfig.contextualEmbedding`;
3. `LexicalTextEmbedder`, with `TopicConfig.default`.

## Telemetry

Logs go to `Log.memory`: model loads at `notice`, failures at `error`, a
non-finite batch at `fault`, each batch at `debug`. Text is never logged.
Each batch is one `memory.embed` interval ([performance.md](performance.md)).

## Testing

| What | How |
| --- | --- |
| Hermetic (`swift test`) | `HuggingFaceTokenizerTests` (two tiny reference tokenizers, merges, truncation, unsupported features, JSON edge cases), `TokenEmbeddingTableTests` (float16 and int8, Core ML with an int8 table), `TextEmbeddingModelTests` (prompts, Matryoshka + int8, batches of 32 with one signpost each, truncation, non-finite output, and the whole path on a tiny Core ML model with both table formats), `TextEmbeddingBundleTests`, `TextEmbeddingServiceTests` (lazy shared load, reinstall, failure, `TextEmbedder`), `TextEmbeddingBatchBenchmarkTests`, `TopicEmbeddingTests` |
| Topics on the service (`swift test`) | `BlauKitIntegrationTests`: the scripted transcripts through `SharedTextEmbedder` (prompt, int8, dequantization) find the same boundaries as the reference embedder |
| Tokenizer parity (opt-in) | `.venv/bin/python scripts/embeddings/tokenizer_parity.py <dir> --model embeddinggemma-300m`, then `BLAU_TOKENIZER_PARITY=<dir> swift test --filter TokenizerParityTests` |
| Real model (opt-in) | `BLAU_TEXT_EMBEDDING_BUNDLE=<hosting folder> swift test -Xswiftc -O --scratch-path .build/optimized --filter "RealTextEmbeddingModelTests\|RealModelTopicSegmentationTests"`: retrieval eval, batch of 32 against the budget, and the scripted transcripts' topics. (Optimized Debug: `-c release` can't build the test targets, because BlauTelemetry's diagnostics samples are Debug-only) |
| iPhone | `make bench` with the hosting folder in `BlauBenchmarks/Assets/` (`memory.embed.batch32`), or the debug benchmark screen with it in `Documents/Benchmarks/Models/` |

### On-device checks

| Check | How | Result |
| --- | --- | --- |
| A batch of 32 full-length chunks within 1.6 s (p95 ≤ 50 ms per chunk) on the slowest supported iPhone | `memory.embed.batch32` in `make bench` | Pending (device and hosted model) |
| EmbeddingGemma has no non-finite vectors on the Neural Engine | `RealTextEmbeddingModelTests` on the Mac, then the benchmark on a device | Pending (gated weights) |
| First load after install (tokenizer + Core ML) | `Loaded text embedding model … in … ms` in the `memory` log | Pending |
