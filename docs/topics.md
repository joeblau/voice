# Topic segmentation

`BlauTopics` watches the conversation as it streams and decides when it has
moved to a new topic. This document describes the streaming segmentation
engine (#52). Confirming boundaries and titling topics with Foundation Models
(#53), the topic lifecycle (#54) and offline re-segmentation (#55) build on
its events.

The engine is a streaming variant of TextTiling (Hearst, 1997) over exchange
embeddings, with hysteresis so a brief digression doesn't split a topic.
It is pure Swift, deterministic and has no clock or I/O, so every rule below
is unit-tested on the Mac.

## Pieces

| Type | What it does |
| ---- | ------------ |
| `TopicUnit` | One finalized exchange: the user's utterance(s) and the agent's reply, with its time range on the audio timeline |
| `ExchangeAssembler` | Groups the `Utterance` stream into `TopicUnit`s. A user utterance after agent speech closes the exchange; call `flush()` on `response.done` or at session end |
| `TextEmbedder` (BlauCore) | `embed(_:) async throws -> [Float]`. Lives in BlauCore so BlauMemory's shared EmbeddingGemma service (#60) can implement it and the composition root can pass it in |
| `NLContextualTextEmbedder` | Apple's on-device `NLContextualEmbedding`, mean-pooled over its subword token vectors. The production embedder until #60. Never downloads assets itself: call `prepare(allowAssetDownload: true)` where a download is acceptable |
| `LexicalTextEmbedder` | Hashed bag of stemmed content words (the signal the original TextTiling used). Needs no model, gives identical vectors everywhere. The reference embedder for tests and the fallback while contextual assets are missing |
| `TopicSegmenter` | The engine: units and embeddings in, events out |
| `StreamingTopicSegmenter` | Actor that embeds each unit, runs the engine inside the `topics.segment` signpost interval and logs decisions under `Log.topics` |
| `TopicConfig` | Every parameter |
| `SegmentationMetrics` | Pk and WindowDiff, for evaluating against labelled transcripts |

```swift
let segmenter = StreamingTopicSegmenter(embedder: embedder, config: .contextualEmbedding)
var exchanges = ExchangeAssembler()

if let unit = exchanges.add(utterance) {
    for event in try await segmenter.append(unit) {
        switch event {
        case .candidate(let boundary): ...  // provisional break; #53 may start labelling
        case .confirmed(let boundary): ...  // new topic starts at boundary.unitID (#54)
        case .rejected(let boundary, let reason): ...  // drop the provisional break
        }
    }
}
```

## How a boundary is decided

Gap `g` sits between unit `g − 1` and unit `g`; a boundary at gap `g` means
unit `g` starts the new topic.

1. **Similarity.** Once `rightWindow` units after the gap exist, the gap gets
   `sim(g) = cos(mean(left window), mean(right window))`, with the
   `leftWindow` (3) units before it and the `rightWindow` (2) units after it.
2. **Depth.** TextTiling depth: climb the similarity curve left from `g`
   while it keeps rising to find `leftPeak`, do the same to the right for
   `rightPeak`, and take `(leftPeak − sim) + (rightPeak − sim)`. The climb
   is capped at `peakSearchLimit` gaps.
3. **Running statistics.** Each gap's depth, once two more gaps have been
   scored (so its right peak has formed), feeds a running mean `μ` and
   standard deviation `σ` (Welford). The entry threshold is
   `θ = max(minimumDepth, μ + kσ)`. No candidate is raised until
   `minimumSamples` depths have settled.
4. **Explicit cues.** If the user's text in unit `g` contains a cue phrase
   ("let's switch gears", "new topic", "on another note"...), the gap's score
   is `depth + cueBoost × θ`; otherwise the score is the depth.
5. **Candidate.** Among the most recent `leftWindow + rightWindow` gaps, the
   eligible gap with the highest score raises `.candidate(at:)` if its score
   is above `θ`. A gap is eligible if the boundary would close a topic of at
   least `minimumTopicUnits` units *and* `minimumTopicDuration`.
6. **Hysteresis (exit).** While a candidate is pending, the newest
   `rightWindow` units are compared with the units before the deepest dip.
   The conversation has *recovered* when that similarity climbs back to
   `dip + recoveryFraction × (leftPeak − dip)` (a higher level than the dip
   that triggered entry) and the newest units are at least half as close to
   the old topic as to the units since the dip. Then the candidate is
   `.rejected(_, reason: .recovered)`, and the units of the digression are
   left out of every later similarity window, so the way back doesn't look
   like another dip.
7. **Sustain.** A candidate is confirmed only after `sustainUnits` more units
   have arrived since its deepest dip was first scored, and not while the
   similarity is still falling at the newest gap (a deeper dip may be
   forming).
8. **Cooldown.** It is also held until `cooldown` has passed on the audio
   timeline since the previous confirmation.
9. **Retroactive placement.** The boundary is confirmed at the deepest
   (highest-scoring) eligible dip seen while the candidate was pending, which
   can be a few exchanges before or after the gap that raised it:
   `.confirmed(boundary)`.
10. **End of stream.** `finish()` rejects a pending candidate with
    `.endOfStream`. A candidate pending for more than `peakSearchLimit` gaps
    is resolved immediately (a safety valve; it does not happen in practice).

Only one candidate is pending at a time, and each candidate is resolved by
exactly one `.confirmed` or `.rejected` event.

## Parameters (`TopicConfig`)

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `leftWindow` | 3 | Units averaged before a gap |
| `rightWindow` | 2 | Units averaged after a gap |
| `thresholdSigmas` | 1.0 | `k` in `μ + kσ` |
| `minimumDepth` | 0.1 (0.02 in `.contextualEmbedding`) | Floor for the threshold; depends on the embedder's similarity scale |
| `minimumSamples` | 5 | Settled depths needed before the statistics are trusted |
| `sustainUnits` | 2 | Units after the dip before confirming |
| `minimumTopicUnits` | 4 | Shortest topic, in exchanges |
| `minimumTopicDuration` | 60 s | Shortest topic, on the audio timeline |
| `cooldown` | 30 s | Time between confirmations |
| `recoveryFraction` | 0.5 | Exit level of the hysteresis, from the dip (0) to the left peak (1) |
| `cueBoost` | 0.5 | Cue bonus as a fraction of `θ` |
| `cuePhrases` | `TopicConfig.defaultCuePhrases` | Phrases that announce a topic change |
| `peakSearchLimit` | 32 | Cap on the depth climb, in gaps |

Use `TopicConfig.contextualEmbedding` with `NLContextualTextEmbedder` and
`TopicConfig.default` with `LexicalTextEmbedder`.

## Evaluation

The labelled transcripts are in
`Packages/BlauKit/Tests/BlauTopicsTests/Fixtures/ScriptedTranscripts.swift`.
`ScriptedTranscriptTests` runs them through `LexicalTextEmbedder` and checks
Pk and WindowDiff (window `k` = half the mean reference segment length), that
the single-topic transcript is never split, and that the brief digression
doesn't flap. `SyntheticConversationTests` adds 60 seeded generated
conversations (about 2,600 exchanges, 240 boundaries, 101 digressions).

| Transcript | Exchanges | Reference | Lexical: found, Pk / WindowDiff | Contextual (macOS 27.2): found, Pk |
| ---------- | --------- | --------- | ------------------------------- | ---------------------------------- |
| `threeTopics` | 18 | 6, 12 | 6, 12 — 0 / 0 | 6, 12 — 0 |
| `briefDigression` | 18 | 12 (digression at 6–7) | 12 — 0 / 0 | none — 0.38 |
| `explicitCues` | 15 | 5, 10 | 5, 10 — 0 / 0 | 5, 10 — 0 |
| `singleTopic` | 14 | none | none — 0 / 0 | none — 0 |
| `fourTopics` | 24 | 7, 12, 18 | 7, 12, 18 — 0 / 0 | 6, 12, 18 — 0.10 |
| 60 synthetic conversations | ~2,600 | 240 | mean Pk 0.030 / WindowDiff 0.031; 6 of 101 digressions split | n/a |

The contextual column comes from the opt-in
`NLContextualTextEmbedderTests` (`BLAU_DEVICE_TESTS=1 swift test --filter
NLContextualTextEmbedderTests`), which uses the OS model if its assets are
already on the machine and skips otherwise. Mean-pooled `NLContextualEmbedding`
vectors are a weaker topic signal than lexical overlap on these short,
keyword-dense transcripts (it missed the Japan boundary after the digression);
EmbeddingGemma (#59, #60) is expected to replace it. Neither embedder ever
split the digression.

## Performance

Budget: **< 5 ms per update on device**, measured as `TopicSegmenter.append`
(the `topics.segment` interval), excluding the embedding. An update costs one
similarity (sums of five vectors and a cosine with vDSP), a bounded depth
search over the last few gaps and, while a candidate is pending, one more
cosine pair, so it is independent of conversation length.

| Where | Workload | Result |
| ----- | -------- | ------ |
| Mac host, debug `swift test` (`TopicSegmenterBudgetTests`, fastest of 5 replays per update) | 400 exchanges, 1,024-d, incl. a 120-exchange topic | p50 0.23–0.29 ms, p99 0.54–0.66 ms, max 0.76–0.85 ms per update |
| Mac host, debug, XCTest `measure` | same, whole run | 0.116 s for 400 updates (0.29 ms each) |
| iPhone, Release | same | **pending** (needs a device) |

To measure on a device, run the XCTest case on the BlauKit package scheme:

```sh
cd Packages/BlauKit
xcodebuild test -scheme BlauKit-Package \
  -destination 'platform=iOS,id=<device udid>' \
  -only-testing:BlauTopicsTests/TopicSegmenterPerformanceTests \
  -only-testing:BlauTopicsTests/TopicSegmenterBudgetTests
```

In the app, the `topics.segment` interval shows each update in Instruments
(see [performance.md](performance.md)).
