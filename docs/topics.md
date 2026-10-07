# Topic segmentation

`BlauTopics` watches the conversation as it streams and decides when it has
moved to a new topic. This document describes the streaming segmentation
engine (#52), how its candidate boundaries are confirmed and titled by a
language model ([Confirmation and labels](#confirmation-and-labels), #53),
and the [topic lifecycle](#topic-lifecycle) that turns those decisions into
stored topics and applies the user's edits (#54). Offline re-segmentation
(#55) builds on the lifecycle.

The engine is a streaming variant of TextTiling (Hearst, 1997) over exchange
embeddings, with hysteresis so a brief digression doesn't split a topic.
It is pure Swift, deterministic and has no clock or I/O, so every rule below
is unit-tested on the Mac.

## Pieces

| Type | What it does |
| ---- | ------------ |
| `TopicUnit` | One finalized exchange: the user's utterance(s) and the agent's reply, with its time range on the audio timeline |
| `ExchangeAssembler` | Groups the `Utterance` stream into `TopicUnit`s. A user utterance after agent speech closes the exchange; call `flush()` on `response.done` or at session end |
| `TextEmbedder` (BlauCore) | `embed(_:) async throws -> [Float]`. Lives in BlauCore so BlauMemory's shared embedding service (#60) implements it (`SharedTextEmbedder`) and the composition root passes it in |
| `TopicEmbedding` | Which embedder a conversation's segmenter runs on, with its tuned `TopicConfig`: the shared embedding service ([embeddings.md](embeddings.md)), else `NLContextualTextEmbedder` if its assets are on the device, else `LexicalTextEmbedder`. Chosen once per conversation (`AppEnvironment.topicEmbedding()`) |
| `NLContextualTextEmbedder` | Apple's on-device `NLContextualEmbedding`, mean-pooled over its subword token vectors. The fallback while the shared model isn't installed (it was the production embedder until #60). Never downloads assets itself: call `prepare(allowAssetDownload: true)` where a download is acceptable |
| `LexicalTextEmbedder` | Hashed bag of stemmed content words (the signal the original TextTiling used). Needs no model, gives identical vectors everywhere. The reference embedder for tests and the fallback while contextual assets are missing |
| `TopicSegmenter` | The engine: units and embeddings in, events out |
| `StreamingTopicSegmenter` | Actor that embeds each unit, runs the engine inside the `topics.segment` signpost interval and logs decisions under `Log.topics` |
| `TopicConfig` | Every parameter |
| `SegmentationMetrics` | Pk and WindowDiff, for evaluating against labelled transcripts |

```swift
// The shared embedding service (#60) when installed, else a fallback:
let segmenter = StreamingTopicSegmenter(embedding: await environment.topicEmbedding())
var exchanges = ExchangeAssembler()

if let unit = exchanges.add(utterance) {
    for event in try await segmenter.append(unit) {
        switch event {
        case .candidate(let boundary): ...  // provisional break (TopicPipeline labels it, below)
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
    `.endOfStream`. It does not move the scan position, so if more units are
    appended afterwards (a paused or restarted session continuing the same
    conversation) the same dip can be raised again and confirmed. A candidate pending for more than `peakSearchLimit` gaps
    is resolved immediately (a safety valve; it does not happen in practice).

Only one candidate is pending at a time, and each candidate is resolved by
exactly one `.confirmed` or `.rejected` event.

## Parameters (`TopicConfig`)

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `leftWindow` | 3 | Units averaged before a gap |
| `rightWindow` | 2 | Units averaged after a gap |
| `thresholdSigmas` | 1.0 | `k` in `μ + kσ` |
| `minimumDepth` | 0.1 (0.02 in `.contextualEmbedding`, 0.5 in `.sharedEmbedding`) | Floor for the threshold; depends on the embedder's similarity scale |
| `minimumSamples` | 5 | Settled depths needed before the statistics are trusted |
| `sustainUnits` | 2 | Units after the dip before confirming |
| `minimumTopicUnits` | 4 | Shortest topic, in exchanges |
| `minimumTopicDuration` | 60 s | Shortest topic, on the audio timeline |
| `cooldown` | 30 s | Time between confirmations |
| `recoveryFraction` | 0.5 | Exit level of the hysteresis, from the dip (0) to the left peak (1) |
| `cueBoost` | 0.5 | Cue bonus as a fraction of `θ` |
| `cuePhrases` | `TopicConfig.defaultCuePhrases` | Phrases that announce a topic change |
| `peakSearchLimit` | 32 | Cap on the depth climb, in gaps |

Use `TopicConfig.sharedEmbedding` with the shared embedding service,
`TopicConfig.contextualEmbedding` with `NLContextualTextEmbedder` and
`TopicConfig.default` with `LexicalTextEmbedder` (`TopicEmbedding` pairs
them).

## Evaluation

The labelled transcripts are in
`Packages/BlauKit/Tests/BlauTopicsTests/Fixtures/ScriptedTranscripts.swift`.
`ScriptedTranscriptTests` runs them through `LexicalTextEmbedder` and checks
Pk and WindowDiff (window `k` = half the mean reference segment length), that
the single-topic transcript is never split, and that the brief digression
doesn't flap. `SyntheticConversationTests` adds 60 seeded generated
conversations (about 2,600 exchanges, 240 boundaries, 101 digressions).

| Transcript | Exchanges | Reference | Lexical: found, Pk / WindowDiff | Contextual (macOS 27.2): found, Pk | Shared service, Qwen3-Embedding 256-d int8: found, Pk |
| ---------- | --------- | --------- | ------------------------------- | ---------------------------------- | ----------------------------------------------------- |
| `threeTopics` | 18 | 6, 12 | 6, 12 — 0 / 0 | 6, 12 — 0 | 6, 12 — 0 |
| `briefDigression` | 18 | 12 (digression at 6–7) | 12 — 0 / 0 | none — 0.38 | 12 — 0 |
| `explicitCues` | 15 | 5, 10 | 5, 10 — 0 / 0 | 5, 10 — 0 | 5, 10 — 0 |
| `singleTopic` | 14 | none | none — 0 / 0 | none — 0 | none — 0 |
| `fourTopics` | 24 | 7, 12, 18 | 7, 12, 18 — 0 / 0 | 6, 12, 18 — 0.10 | 7, 12, 18 — 0 |
| 60 synthetic conversations | ~2,600 | 240 | mean Pk 0.030 / WindowDiff 0.031; 6 of 101 digressions split | n/a | n/a |

The contextual column comes from the opt-in
`NLContextualTextEmbedderTests` (`BLAU_DEVICE_TESTS=1 swift test --filter
NLContextualTextEmbedderTests`), which uses the OS model if its assets are
already on the machine and skips otherwise. Mean-pooled `NLContextualEmbedding`
vectors are a weaker topic signal than lexical overlap on these short,
keyword-dense transcripts (it missed the Japan boundary after the digression);
EmbeddingGemma (#59, #60) is expected to replace it. Neither embedder ever
split the digression.

The shared-service column (#60) comes from the opt-in
`RealModelTopicSegmentationTests` in `BlauKitIntegrationTests`
(`BLAU_TEXT_EMBEDDING_BUNDLE=<hosting folder> swift test --filter
RealModelTopicSegmentationTests`), run on Qwen3-Embedding-0.6B, #59's
fallback, because EmbeddingGemma's weights are gated: the full production
path (document prompt, Swift tokenizer, int8 token table, Core ML on the
Neural Engine, 256-d int8, dequantized) with `TopicConfig.sharedEmbedding`.
A retrieval model separates topics far more sharply than the contextual
embedding: every labelled boundary scored a depth of 0.92 to 1.45, every
other gap 0.44 or less (the digression's dip, rejected by the hysteresis).
With `.contextualEmbedding`'s floor of 0.02 the single-topic transcript was
split at a 0.21 dip; `.sharedEmbedding` puts the floor at 0.5, between the
two groups. **EmbeddingGemma's column is pending**: rerun the test on its
bundle, and `BLAU_TOPIC_MINIMUM_DEPTH` tries another floor without a code
change. The synthetic conversations are bags of topic keywords, which a
sentence model doesn't read the way it reads speech, so they stay a
lexical-only check.

`SharedEmbedderTopicSegmentationTests` (hermetic, in the same target) runs
the scripted transcripts through the shared service with the lexical
embedder behind it and requires exactly the reference boundaries, so the
service's own steps (prompt, int8 quantization, dequantization) can't
change a topic decision.

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

## Confirmation and labels

Every topic gets a short title and a one-sentence summary, and a language
model reads each candidate boundary before it becomes a topic (#53). The code
is in `Packages/BlauKit/Sources/BlauTopics/Labeling/`.

| Type | What it does |
| ---- | ------------ |
| `TopicPipeline` | Actor wrapping `StreamingTopicSegmenter`: asks the model about each candidate, vetoes it or keeps the model's title, and emits `TopicEvent`s (`.candidate`, `.topicStarted`, `.candidateRejected`). Calls are processed in order even when they overlap |
| `TopicLabelingService` | Actor that tries the labelers in order, normalizes the result, applies the thermal policy, runs the `topics.label` signpost interval and keeps the latency per source |
| `FoundationModelsTopicLabeler` | Apple's on-device model with `@Generable TopicShift { isNewTopic, title, summary }` |
| `RemoteTopicLabeler` | The same task through a `TextGenerator` (BlauCore). In the app that is `XAITextGenerator` (BlauRealtime): xAI's `POST /v1/chat/completions` with the user's Keychain key and JSON-schema structured output |
| `KeywordTopicLabeler` | Nouns and names from `NLTagger`, ranked by TF-IDF against the previous topic. No model, never fails |
| `TopicTitleFormatter` | Enforces ≤ 5 words in Title Case and a one-sentence summary on every label, whatever produced it |
| `TopicLabelPrompt` | The shared instructions and prompt, and the trimming that keeps them inside the context window |
| `TopicLabelingPolicy` | What the thermal state allows (below) |

```swift
let pipeline = TopicPipeline(
    segmenter: StreamingTopicSegmenter(embedder: embedder, config: .contextualEmbedding),
    labeling: .app(xai: xaiServices))  // Blau/Topics/TopicLabeling+App.swift
for event in try await pipeline.append(unit) {
    switch event {
    case .candidate(let boundary, let provisional): ...  // provisional break, maybe a provisional title
    case .topicStarted(let boundary, let label): ...     // open the new topic titled label.title (#54)
    case .candidateRejected(let boundary, let reason): ...  // includes .vetoed
    }
}
// The first topic, once it has a few exchanges, and a topic being refined
// as it closes (#54):
let first = await pipeline.labelTopic()
let refined = await pipeline.labelTopic(in: closed.range, previousTitle: earlierTitle)
```

### Flow

1. **Candidate.** The segmenter raises `.candidate`. The pipeline sends about
   six units around it (up to half after it, never reaching back past the
   start of the topic it would close) and the current topic's title. The
   model answers `isNewTopic`, a title and a summary.
2. **Veto.** If a model (not the keyword fallback) says `isNewTopic: false`,
   the pipeline emits `.candidate` then `.candidateRejected(_, .vetoed)` and
   calls `StreamingTopicSegmenter.vetoPendingCandidate()`, which drops the
   candidate and resumes the scan after the gaps already scored. A boundary
   the user announced ("let's switch gears") isn't vetoed
   (`TopicLabelingPolicy.explicitCueOverridesVeto`).
3. **Confirmation.** When the segmenter confirms, the candidate's title is
   reused if the boundary moved by at most one unit; otherwise the new topic
   is titled then. `.topicStarted` carries the label, and the title becomes
   the "previous title" for the next boundary (`setCurrentTitle(_:)` replaces
   it after a refinement or a manual rename).

The model only sees the units around the candidate, so it can't tell a brief
digression that will come back from a real change; that stays the job of the
segmenter's hysteresis. The veto catches candidates whose words changed but
whose subject didn't.

### Fallbacks

Each labeler is skipped when it isn't available and abandoned after 10 s, on
an error, or when its title is unusable; the next one is tried.

| Order | Labeler | Used when |
| ----- | ------- | --------- |
| 1 | Foundation Models | `SystemLanguageModel.default.isAvailable` (Apple Intelligence on an eligible device, model downloaded) |
| 2 | xAI text API | Apple Intelligence is unavailable or failed, and an xAI key is stored. Model `grok-4.20-0309-non-reasoning` (`XAITextGenerator.defaultModel`), temperature 0, 160 tokens, 10 s timeout |
| 3 | Keywords | Always: no Apple Intelligence and no key, offline, or thermal state `.critical` |

On-device details:

- A fresh `LanguageModelSession` per call; greedy sampling, at most 160
  response tokens.
- **Context window.** The whole request is kept under 75 % of
  `min(contextSize, 4096)` tokens, after the instructions, the schema and the
  reply. Tokens are counted with `SystemLanguageModel.tokenCount(for:)` on
  iOS 26.4+ (estimated at one token per three bytes before). Units far from
  the boundary are dropped first, then turns are cut shorter. If the model
  still throws `exceededContextWindowSize` (`LanguageModelError.contextSizeExceeded`
  on iOS 27), the request is retried once with half the units.
- **Guardrails.** Guided generation always runs under the default
  guardrails, and the model refuses ordinary personal-finance talk (the
  mortgage and tax fixtures) with "May contain sensitive content". Labeling
  only transforms what the user said, so on a guardrail violation or refusal
  the labeler retries once as plain text with
  `.permissiveContentTransformations` (which only relaxes `String` output)
  and parses the JSON reply.

### Thermal policy

Confirmation runs for every candidate, including ones the segmenter later
drops; titling runs once per topic. So under thermal pressure the confirm
step goes first:

| `ProcessInfo.thermalState` | Mode | Behaviour |
| -------------------------- | ---- | --------- |
| `.nominal`, `.fair` | `.full` | Confirm or veto candidates and title topics with a model |
| `.serious` | `.skipConfirmation` | No call at candidates; the segmenter's decision stands. Each confirmed topic is still titled by a model |
| `.critical` | `.keywordsOnly` | No model calls; keyword titles |

The thermal source is a `ThermalStateProviding`. The thermal and power
policy (#75, [performance.md](performance.md#thermal-and-power-adaptation))
tightens this through `TopicLabelingService(performance:)`; the mode is the
stricter of the two:

| `PerformanceLevel` | Mode | Behaviour |
| ------------------ | ---- | --------- |
| `normal` | `.full` | As above |
| `reduced` | `.confirmStrongCandidates` | Only strong candidates (score at least `strongCandidateRatio`, 1.5×, the threshold they cleared) go to the model; weaker ones are left to the segmenter's hysteresis, which drops most of them anyway. Confirmed topics are titled by a model |
| `minimal` | `.skipConfirmation` | No call at candidates; confirmed topics are still titled |

Strong candidates are the ones most likely to be confirmed, so their
provisional title is usually reused and the call isn't wasted; the
`TopicPerformanceLevelTests` check that exactly the strong candidates of a
scripted transcript are sent and that the same topics come out.

### Evaluation

`TopicLabelFixtureTests` runs all 5 scripted transcripts and the 60
synthetic conversations through the whole pipeline and also titles every
reference topic, with three labeler setups: keywords only, a model that
ignores the five-word guide (long, quoted, "Title:"-prefixed answers), and
the xAI path replying with the same. All 884 labels per setup are five
words or fewer.

The opt-in `FoundationModelsTopicLabelerTests`
(`BLAU_DEVICE_TESTS=1 swift test --filter FoundationModelsTopicLabelerTests`)
runs the real on-device model over every scripted boundary and topic:

| Transcript | Model's titles (Mac, macOS 27.2) |
| ---------- | --------------------------------- |
| `threeTopics` | Baking Sourdough Bread · Marathon Training Advice · Mortgage Refinancing Options |
| `briefDigression` | YC Interview Preparation Tips · Japan Trip Planning |
| `explicitCues` | Companion Planting Tips · Kubernetes Deployment Issues · Birthday Party Planning |
| `singleTopic` | Piano Practice Duration |
| `fourTopics` | Car Maintenance Tips · Tax Preparation for Freelancers · Puppy Training Challenges · Podcast Equipment |

All 22 titles were five words or fewer, all 8 real boundaries were
confirmed, and the model did not veto the digression (see Flow above).

### Label latency

`TopicLabelingService.latency(for:)` keeps the last 256 latencies per source
(`p50`, `p90`, `maximum`), and every label is logged under `Log.topics` with
its latency and the running p50. Instruments shows each call as a
`topics.label` interval.

| Where | Labeler | p50 | p90 | Max | Labels |
| ----- | ------- | --- | --- | --- | ------ |
| Mac host (Apple silicon, macOS 27.2), `FoundationModelsTopicLabelerTests`, model warmed | Foundation Models | 2.38 s | 3.25 s | 3.46 s | 22 |
| iPhone 15 Pro or later, Release | Foundation Models | **pending** (needs a device) | | | |
| iPhone without Apple Intelligence | xAI | **pending** (needs a device and a real key) | | | |

The Mac numbers come from a shared machine running other builds; earlier
runs measured p50 2.26–2.70 s. Labeling runs off the audio path and only at
candidate boundaries and topic changes, so seconds of latency don't delay
the conversation; a new topic appears a couple of exchanges after a switch
in any case (#54).

To measure on a device, run the same suite on the package scheme with the
environment variable set in the scheme's test action, or read the
`topics.label` intervals from an Instruments recording of a real
conversation (see [performance.md](performance.md)).

## Topic lifecycle

`TopicLifecycle` (BlauTopics, #54) runs the topics of the live conversation:
it opens them, titles them, refines each one when it closes, and applies the
user's rename, merge and split. It writes through `ConversationStore`
(BlauPersistence), the same store that records the transcript, so the
store's current topic follows every boundary and new utterances join the
right topic. The code is in `Packages/BlauKit/Sources/BlauTopics/Lifecycle/`
and `Packages/BlauKit/Sources/BlauPersistence/ConversationStore+Topics.swift`.

```swift
// Blau/Topics/TopicLifecycle+App.swift and AppEnvironment.live():
let transcript = PersistenceTranscriptRecorder(persistence: persistence)
let topics = TopicLifecycle.app(transcript: transcript, labeling: .app(xai: xai), textEmbeddings: textEmbeddings)
let orchestrator = VoiceLoop.makeOrchestrator(
    ..., transcript: TopicTrackingTranscript(base: transcript, topics: topics), reseedContext: transcript, ...)
// The timeline's context menu (Blau/Topics/TopicEditMenu.swift):
try await topics.rename(topicID, to: "Seed round")
try await topics.mergeWithPrevious(topicID)
try await topics.split(topicID, atUtterance: utteranceID)
```

`TopicTrackingTranscript` stores each utterance, then hands it to the
lifecycle (`ingest`), which queues the work and returns at once: labeling
takes seconds and must never hold up the transcript or the audio. The queue
runs in order, and every store call names its topic, so a decision that
lands after the conversation ended still changes the right topic.

### What happens when

| Moment | What the lifecycle does |
| ------ | ----------------------- |
| Conversation starts | Opens the first topic at the conversation's start, titled "New topic" (`Topic.placeholderTitle`). A resumed conversation with an open topic continues it |
| Each exchange | `ExchangeAssembler` groups the committed utterances; an exchange is scored when the user speaks again or 1 s after the agent's reply was stored (`exchangeSettleDelay`). Its time range is re-based on the wall clock, so user (ASR timeline) and agent (orchestrator clock) speech always arrive in order |
| 3rd exchange of a topic without a model title | Labels the topic so far: provisional title and summary (`firstTitleAfterExchanges`) |
| Candidate the model agreed with | Splits the current topic at the boundary: the new topic appears with the model's provisional title, shown in italics (`titleIsProvisional`) |
| Candidate vetoed in the same step | Nothing is opened |
| Boundary confirmed | Moves the new topic's start to the confirmed gap if it moved, keeps the topic, and **refines the closed topic**: labels all of its exchanges and makes that title final, with a summary |
| Candidate taken back (digression, end of stream) | Merges the provisional topic back into the one before it. If the user renamed the provisional topic, the break is theirs: the topic stays and the one before it is closed and refined instead |
| Conversation ends | Scores the last exchange, takes back an unconfirmed break, refines the last topic; a topic with no utterances is removed. Utterances that arrive afterwards (late transcripts) never reopen topics |

The new topic appears about two exchanges after a real switch: the
segmenter raises a candidate once two exchanges after the gap exist
(`rightWindow`), and the lifecycle shows it then instead of waiting for the
confirmation, which needs `sustainUnits` more. On the scripted transcripts
the switch's first exchange is in a new topic one or two exchanges after it
(`TopicLifecycleTests.aNewTopicAppearsWithinTwoExchangesOfASwitch`), and
after confirmation every topic starts exactly at the labelled boundary.
`Configuration.opensTopicsAtCandidates = false` waits for the confirmation
instead (three to five exchanges).

| Transcript | Switch at exchange | New topic shown after exchange |
| ---------- | ------------------ | ------------------------------ |
| `threeTopics` | 6, 12 | 7 (provisional at 4, moved to 6 on confirmation), 13 |
| `briefDigression` | 12 | 13 (the digression at 6 was shown after 7 and taken back after 9) |
| `explicitCues` | 5, 10 | 7, 11 |
| `fourTopics` | 7, 12, 18 | 7 (provisional at 4, moved to 7), 13, 19 |
| `singleTopic` | none | none kept (two candidates shown and taken back) |

### Titles and manual edits

`Topic.titleIsProvisional` decides who may write a title:

- The lifecycle only ever writes a title through
  `ConversationStore.applyTopicLabel`, which writes it **only while the title
  is provisional**. A refinement on close makes it final.
- A manual rename (`renameTopic`) makes the title final and saves at once,
  so it is on disk (and queued for CloudKit) before the call returns. A
  manual title is therefore never overwritten, whatever label lands later.
  The summary is still refreshed.
- **Merge with previous** gives the earlier topic the later one's utterances
  and end, deletes the later topic, and refreshes the summary. The earlier
  topic keeps its title unless that title is provisional and the later
  one's is final (refined and manual titles are both final, so a refined
  earlier title wins over a manual later one). Merging away a provisional
  topic also ignores the segmenter's later confirmation of that boundary.
- **Renaming a provisional topic** accepts its break: if the segmenter
  later takes the candidate back, the named topic is kept rather than
  merged away, and the topic before it is closed and refined.
- **Split here** starts a new topic at an utterance (not the first). Both
  parts are labeled again; a manual title on the first part stays.

Topic order is `ordinal` (renumbered 0, 1, 2... on every split and merge).
Each closed topic's final title and summary are stored on the `Topic`, and
`TopicLifecycle.events()` reports them for session continuity (#39) and
memory (M3):

| Event | When |
| ----- | ---- |
| `.opened` | A topic opened: the first topic, a provisional break, or the second part of a split |
| `.updated` | A title, summary or span changed. A merge or split that revises a topic which had already closed reports its new final label here |
| `.closed` | A topic closed and was refined. Sent once per topic, when it closes (a confirmed boundary, the end of the conversation, or splitting the open topic) |
| `.removed` | A provisional break taken back, a topic merged into the one before it, or an empty last topic |

Session continuity reads the current topic straight from the store: the
realtime reseed (#39) gets `reseedContext: transcript`, the same
`PersistenceTranscriptRecorder` (and so the same `ConversationStore`) the
lifecycle writes titles and summaries to. The recorder opens one store per
container and makes every caller wait for it, so the transcript and the
lifecycle never write through two stores after an iCloud account change.

Until the timeline (#56) exists, DEBUG builds show recent conversations'
topics with the edit menu in **Debug → Topics** (`TopicsDebugView`).

### Not covered yet

- A title refined on close and a manual title are both "final"
  (`titleIsProvisional == false`); the schema can't tell them apart. Offline
  re-segmentation (#55) must not re-title user-edited topics, so it will need
  a way to tell them apart, such as a `titleSource` field in a schema v3.
- Two devices editing the same conversation at once resolve through
  CloudKit's last-writer-wins per field.
