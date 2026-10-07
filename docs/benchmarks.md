# On-device model benchmarks

Research spike #22 (epic #11). Several numbers the architecture in issue #1
depends on are not published for iPhone: streaming ASR latency per chunk
size, second-pass load and speed, speaker-embedding latency, text-embedding
latency, Foundation Models label latency, and what iOS 27 does to Neural
Engine work when the screen is locked. This document describes the harness
that measures them, the results so far, and the decisions that hang on them.

**Status (2026-10-07):** the harness is complete and validated end to end
against the real FluidAudio models on a Mac. **The iPhone results are still
pending**: they need physical A17 Pro / A18 / A19 iPhones, which the
harness's author did not have. The two decisions below are written as
rules with a provisional outcome, so whoever runs the benchmarks can settle
them by filling in the tables.

## What is measured

| Case id | Model | Numbers | Why |
| --- | --- | --- | --- |
| `asr.eou.160ms`, `asr.eou.320ms`, `asr.eou.1280ms` | Parakeet realtime EOU 120M (FluidAudio `StreamingEouAsrManager`) | `load`, `rtfx`, `window` and `window.burst` latency, `window.p95OfHop`, `finish` latency, memory | Pick the default chunk size (#29) |
| `asr.tdt.v3` | Parakeet TDT 0.6B v3 (FluidAudio `AsrManager`) | `load.cold`, `load.warm`, `rtfx` on 60 s, `utterance.5s` latency, memory | Second pass (#30): first-launch cost and per-utterance latency |
| `voiceid.wespeaker` | WeSpeaker ResNet34-LM (FluidAudio `wespeaker_v2`, 256-d) | `load`, `embed.1.5s`, `embed.3s`, `cosine.sameSpeaker`, memory | Voice ID gate (#45, #47) |
| `voiceid.campplus` | CAM++ (FluidAudio, beta, 192-d) | same as above | The challenger named in #1 |
| `memory.embeddinggemma` | EmbeddingGemma-300M as Core ML, truncated to 256-d and quantized to int8 | `load`, `embed.64tok`, `embed.128tok`, `embed.256tok`, memory | Memory index (#59, #60) |
| `memory.embed.batch32` | The shared text embedding service (#60) on an installed hosting folder: prompt, Swift tokenizer, token table, Core ML, 256-d int8 | `load`, `embed.batch32` and `embed.batch32.chunk` latency, `tokens.mean`, `budget.batch32`, a within/over-budget note, memory | #60's acceptance criterion: a batch of 32 chunks within #59's budget |
| `memory.index.search50k` | The memory index (#62): 50k exchange-like chunks with 256-d int8 vectors in an on-disk SQLite/FTS5 index (no model needed) | `build`, `load` (every vector into the matrix, the launch cost), `search.vector`, `search.keyword` and `search.hybrid` latency, `budget.search`, `index.fileSize`, a within/over-budget note, memory | #62's acceptance criterion: a search over 50k chunks within 20 ms p95 on an A17 |
| `topics.label.foundationModels` | On-device Foundation Models through Blau's production `FoundationModelsTopicLabeler` (#53) | `label.cold`, `label`, `label.prewarmed`, `titles.withinWordLimit` | Topic confirmation and titles (#53) |
| Background probe | Parakeet EOU 320 ms on the Neural Engine, with a CPU-only baseline | Per-window latency by app phase, errors, Neural Engine availability, verdict, mitigation | iOS 27 background Neural Engine restrictions (#26) |

Every latency is reported as a distribution (p50, p95, p99, min, max, mean,
standard deviation, count); the tables show p50 and p95.

## Running the benchmarks

### On an iPhone: the results table

```sh
xcrun devicectl list devices          # find the iPhone's identifier
make bench DEVICE=<identifier>        # Release build, about 20 minutes
```

`make bench` runs the `BlauBenchmarks` XCTest target through the
`Blau-Benchmarks` scheme in the **Release** configuration (the shipping
optimization level; FluidAudio's decoders are Swift code and are several
times slower unoptimized). It sets `TEST_RUNNER_BLAU_DEVICE_TESTS=1`;
without it every benchmark skips, so `make test` and CI never run them.
Signing must be set up for a device build (Xcode > Settings > Accounts, and
a development team on the `BlauBenchmarks` target), and the device needs
network access the first time: models download from Hugging Face
(about 1 GB in total) into the test runner's container.

Each test attaches its result, the cumulative report for the device
(`<date>-<model id>.json`) and a Markdown summary to the result bundle in
`.build/Benchmarks/`. Extract them with:

```sh
xcrun xcresulttool export attachments --path .build/Benchmarks/<run>.xcresult --output-path /tmp/bench
```

Before a run: charge above 50%, unplugged or plugged in consistently (note
which), Low Power Mode off, the device at room temperature and idle for a
few minutes. Every result records the thermal state at start and end; runs
that reach `serious` are marked `ok (throttled)` and don't count toward the
go/no-go.

### The debug benchmark screen

Debug builds of the app have a gauge button in the top-right corner (or
launch with `-BlauBenchmarks`) that opens **Benchmarks**: the same cases with
progress, results, and JSON/Markdown reports you can share, saved under
`Documents/Benchmarks/Reports/`. A Debug build runs Swift code unoptimized,
so its ASR numbers are pessimistic and stay out of the table; the screen
says so. Build the app in Release with the `BLAU_BENCHMARKS` compilation
condition to get the screen with optimized code:

```sh
xcodebuild build -scheme Blau -configuration Release -destination 'id=<identifier>' \
  -derivedDataPath .build/DerivedData -allowProvisioningUpdates \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=BLAU_BENCHMARKS XAI_DEV_API_KEY=
```

The screen exists mainly for the background probe, which needs a person to
lock the device.

### The background Neural Engine probe

On the benchmark screen, under **Background Neural Engine probe**:

1. Set a duration (10 minutes is a good default) and tap **Start probe**.
   Blau asks for the microphone: the probe keeps an audio session recording,
   exactly like a conversation, which is what keeps the app running off
   screen (the `audio` background mode).
2. The probe first times 40 windows of the same model on the CPU only (the
   baseline), then loads the Neural Engine model and starts the live run.
3. When the status says *Running*, stay in Blau for about a minute (the
   foreground sample), then press the side button to lock the device. The
   device must have a passcode: "locked" is detected as protected data
   becoming unavailable, about 10 seconds after locking.
4. Leave it locked for most of the run, then unlock and return to Blau. The
   verdict, the recommended mitigation and a JSON report with every sample
   appear when the run ends (or tap **Stop and analyse**).

Run it on iOS 27 (the restriction is new there) and, for comparison, on
iOS 26.

### On this Mac: reference numbers

```sh
make bench-kit       # BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModel
```

Runs the same cases (except EmbeddingGemma) against the real models on the
Mac. Set `BLAU_BENCH_OUTPUT=<dir>` to keep the JSON reports and
`BLAU_BENCH_AUDIO=<file>` to use a recording. Mac numbers say nothing about
an iPhone; they validate the harness and catch gross regressions.

### Optional inputs

- **Speech.** By default the benchmarks synthesize about 70 seconds of
  conversational English on the device with `AVSpeechSynthesizer`
  (`AudioFixture.benchmarkPassage`), so nothing is downloaded or committed.
  To use a recording instead, put `benchmark-speech.wav` in
  `BlauBenchmarks/Assets/` (XCTest) or `Documents/Benchmarks/` (app). If
  synthesis fails, a deterministic speech-shaped signal is used and the
  report says so; it underestimates the ASR decoder's cost because it
  decodes few tokens.
- **EmbeddingGemma.** No Swift package ships EmbeddingGemma-300M for Core ML,
  so the case is skipped until a model is supplied. Convert it with
  `scripts/embeddings/convert_coreml.py --model embeddinggemma-300m` (see
  [Text embedding model](#text-embedding-model-59)): that writes
  `EmbeddingGemma300M.mlpackage` and its token table
  `EmbeddingGemma300M.token-embeddings.f16`. Put **both** in
  `BlauBenchmarks/Assets/` (XCTest; gitignored) or copy them to the app's
  `Documents/Benchmarks/Models/` with `xcrun devicectl device copy to`. A
  `.mlpackage` is compiled on the device and the compile counts toward
  `load`. The same case measures any other converted candidate: name it
  `EmbeddingGemma*` or pass its URL to `CoreMLTokenEmbeddingModel`.
- **Shared embedding service** (`memory.embed.batch32`). Copy the whole
  `hosting/` folder `convert_coreml.py` writes (the one `ModelManager`
  would download: `blau-embedding.json`, the compiled model, its token
  table and `tokenizer.json`) into `BlauBenchmarks/Assets/` or the app's
  `Documents/Benchmarks/Models/`, directly or as a subfolder. Skipped
  without one.

## Methodology

- **Timing** uses a monotonic clock (`BlauClock.uptime`, `ContinuousClock`
  in production) around each call. Each measured step is wrapped in its
  canonical signpost (`asr.chunk`, `voiceid.embed`, `memory.embed`,
  `topics.label`), so an Instruments trace of a run lines up with
  [docs/performance.md](performance.md).
- **Warm-up.** The first windows or iterations of every pass are excluded
  (4 ASR windows, 3 embeddings, 1 transcription).
- **Streaming ASR** is fed one hop at a time with 16 kHz mono float buffers
  (FluidAudio's no-resampling fast path). The harness mirrors FluidAudio's
  windowing to know how many encoder windows each call ran, and divides the
  call's time by them. Two passes: *burst* (back to back, 60 s of audio)
  gives `rtfx` (audio seconds per compute second, including utterance
  finishes) and `window.burst`; *paced* (one hop per hop duration, 30 s of
  audio, like live capture) gives `window`, the latency the user feels.
  Paced latency can be worse than burst latency because the Neural Engine
  clocks down between bursts. Every 10 s of audio the utterance is finished
  (`finish`), as the pipeline does at each end of utterance. Note the
  window is not the hop: at 320 ms, FluidAudio's encoder sees 630 ms of
  audio (64 mel frames) and advances 320 ms.
- **Load** is the time to load compiled models from disk. On a device the
  first load after install also specializes the model for the Neural
  Engine; the OS caches that per model location. For TDT v3, `load.cold`
  copies the model folder to a fresh path first (a cache miss, like a fresh
  install) and `load.warm` loads the same copy again (median of three).
  Downloads are never timed.
- **Memory** is the process's physical footprint (`task_vm_info
  .phys_footprint`, what jetsam and Xcode's gauge use): `memory.footprint`
  at the end, `memory.footprintGrowth` the highest sampled value above the
  baseline taken before loading. `memory.neuralGrowth` is the kernel's
  neural (Neural Engine) ledger for the process. Compiled Neural Engine
  programs live partly in the ANE daemon, so the footprint undercounts
  Neural Engine models; the neural ledger covers what the kernel attributes
  to Blau.
- **Speaker embeddings** are timed on windows taken from different places in
  the speech. `cosine.sameSpeaker` compares two windows of the same speaker,
  a sanity check, not a calibration (#48).
- **Text embeddings** use synthetic token IDs (latency depends on sequence
  length, not content) and include Matryoshka truncation to 256-d,
  L2 normalization and int8 quantization (`MatryoshkaEmbedding`).
- **Topic labels** time the labeler Blau ships, `FoundationModelsTopicLabeler`
  (#53), through `FoundationModelsLabelBenchmarkGenerator`: the same
  instructions and prompt (`TopicLabelPrompt`), token budget and
  `TopicLabelPrompt.fit`, greedy sampling, and retries (a smaller prompt, or
  plain text after a refusal). The fixtures (`TopicLabelRequest.benchmarkRequests`)
  are boundary requests shaped like the segmenter's: three exchanges, user
  turn and assistant reply, either side of the boundary, plus the previous
  title. `label.cold` is the first request in the process, session creation
  included. For `label` and `label.prewarmed` the labeler's first guided
  session is made outside the timed region through its prewarming seam
  (`prepareSession(for:prewarm:)`; for `label.prewarmed`, `prewarm()` is
  called on it), then both wait the same lead (`prewarmLead`, 1.5 s by
  default, about how early the segmenter knows a boundary is coming) and
  only the labeler's `label` is timed: token counting, fitting, generation
  and any retry. `prewarm()` returns at once and loads in the background, so
  it needs that lead to have any effect. `titles.withinWordLimit` counts
  the model's raw titles, before `TopicTitleFormatter` enforces the limit.
  Titles are never logged.
- **Device and conditions.** Every report records the model identifier,
  chip, OS build, memory, build configuration, and thermal state at the
  start and end of each case.

The measuring logic lives in BlauKit next to each model (`BlauTelemetry`
for the runner, statistics, reports and the background analysis;
`BlauTranscription`, `BlauVoiceID`, `BlauMemory`, `BlauTopics` for the cases)
behind protocols, and is unit tested on the Mac with fakes on a virtual
clock. The app and the XCTest target only compose the cases.

## Results

### iPhones (pending)

Fill this table from the reports (`BenchmarkReport.comparisonTable` renders
it from the JSON). Release builds only. Rows marked *budget* feed the
go/no-go below.

| Case | Metric | iPhone 15 Pro (A17 Pro) | iPhone 16 / 16 Pro (A18 / A18 Pro) | iPhone 17 / 17 Pro (A19 / A19 Pro) |
| --- | --- | --- | --- | --- |
| EOU 160 ms | `window` p50 / p95 | pending | pending | pending |
| | `rtfx` | pending | pending | pending |
| | `memory.footprintGrowth` | pending | pending | pending |
| EOU 320 ms | `window` p50 / p95 | pending | pending | pending |
| | `window.p95OfHop` (budget ≤ 50%) | pending | pending | pending |
| | `rtfx` (budget ≥ 4×) | pending | pending | pending |
| | `finish` p95 | pending | pending | pending |
| | `memory.footprintGrowth` (budget ≤ 300 MB) | pending | pending | pending |
| EOU 1280 ms | `window` p50 / p95 | pending | pending | pending |
| | `rtfx` | pending | pending | pending |
| TDT v3 | `load.cold` / `load.warm` | pending | pending | pending |
| | `rtfx` (60 s) | pending | pending | pending |
| | `utterance.5s` p50 / p95 | pending | pending | pending |
| | `memory.footprintGrowth` | pending | pending | pending |
| WeSpeaker ResNet34-LM | `embed.1.5s` p50 / p95 | pending | pending | pending |
| | `embed.3s` p50 / p95 | pending | pending | pending |
| CAM++ | `embed.1.5s` / `embed.3s` p50 | pending | pending | pending |
| EmbeddingGemma 256-d int8 | `embed.128tok` p50 / p95 | pending (needs model) | pending (needs model) | pending (needs model) |
| Shared service, EmbeddingGemma (#60) | `embed.batch32` p50 / p95 (budget 1,600 ms) | pending (needs model) | pending (needs model) | pending (needs model) |
| | `memory.footprintGrowth` | pending | pending | pending |
| Qwen3-Embedding-0.6B 256-d int8 (fallback, #59) | `embed.128tok` p50 / p95 | pending | pending | pending |
| | `memory.neuralGrowth` | pending | pending | pending |
| Memory index, 50k chunks (#62) | `search.hybrid` p50 / p95 (budget 20 ms) | pending | pending | pending |
| | `search.vector` / `search.keyword` p95 | pending | pending | pending |
| | `load` (50k vectors at launch) | pending | pending | pending |
| Foundation Models | `label.cold` | pending | pending | pending |
| | `label` / `label.prewarmed` p50 | pending | pending | pending |
| Background probe (iOS 27) | verdict / mitigation | pending | pending | pending |

### Mac reference (harness validation)

Measured with `make bench-kit` (Release) on an Apple M3 Max (Mac15,8,
128 GB), macOS 27.2, on 2026-10-07, with synthesized speech. **The machine
was heavily loaded by other builds during the run (load average around
600)**, so these numbers are noisy upper bounds. They show that every case
runs end to end against the real models, and the relative costs.

| Case | Metric | M3 Max (loaded) |
| --- | --- | --- |
| EOU 160 ms | `load` (first load, includes compile) | 67.0 s |
| | `window.burst` p50 / p95 | 37.7 / 313.5 ms |
| | `window` (paced) p50 / p95 | 35.6 / 146.9 ms |
| | `rtfx` | 1.03× |
| EOU 320 ms | `load` (first load, includes compile) | 96.2 s |
| | `window.burst` p50 / p95 | 38.5 / 49.1 ms |
| | `window` (paced) p50 / p95 | 69.5 / 173.9 ms |
| | `window.p95OfHop` | 54% |
| | `finish` p50 / p95 | 37.4 / 44.1 ms |
| | `rtfx` | 8.08× |
| | `memory.footprintGrowth` | 70 MB |
| EOU 1280 ms | `load` (first load, includes compile) | 168.5 s |
| | `window.burst` p50 / p95 | 49.4 / 60.8 ms |
| | `rtfx` | 25.9× |
| TDT v3 | `load.cold` / `load.warm` | 126.7 s / 1.16 s |
| | `rtfx` (60 s) | 22.0× |
| | `utterance.5s` p50 / p95 | 294.5 / 666.8 ms |
| | `memory.footprintGrowth` / `memory.neuralGrowth` | 34 MB / 468 MB |
| WeSpeaker ResNet34-LM | `load` | 687 ms |
| | `embed.1.5s` p50 / p95 | 135.8 / 305.3 ms |
| | `embed.3s` p50 / p95 | 125.5 / 220.3 ms |
| | `cosine.sameSpeaker` | 0.83 |
| CAM++ | `embed.1.5s` p50 / p95 | 1,632 / 3,317 ms |
| | `embed.3s` p50 / p95 | 916 / 1,322 ms |
| | `cosine.sameSpeaker` | 0.91 |
| Foundation Models | `label.cold` | 3,136 ms |
| | `label` p50 / p95 | 2,107 / 2,456 ms |
| | `label.prewarmed` p50 / p95 | 2,063 / 2,394 ms |
| | `titles.withinWordLimit` | 100% |

The Foundation Models rows time the production labeler (#53) and were
measured on 2026-10-07 (`BLAU_DEVICE_TESTS=1 swift test -c release --filter
RealModelTopicLabelBenchmarkTests`, same Mac, load average 260 to 450). A
second run gave `label` p50 2,649 ms and `label.prewarmed` p50 2,816 ms
(cold 3,213 ms), but a device test shared the model for its first 5 s.
These agree with the 2.26 to 2.70 s p50 that docs/topics.md reports for the
labeler. Earlier rows in this PR (`label` p50 783 to 865 ms) timed a
benchmark-only copy of the labeler with a shorter prompt and no token
counting, and are superseded.

What the Mac run already shows, independent of the device:

- **EOU 160 ms costs about the same per window as 320 ms** (≈ 38 ms burst
  p50 each), but FluidAudio's 160 ms variant advances by 80 ms (50%
  overlap), so it runs four windows for every one at 320 ms. On the loaded
  M3 Max it barely kept up (1.03×). Unless an iPhone shows otherwise, 160 ms
  is too expensive to be the default on a phone that also runs VAD, voice
  ID and playback.
- **Paced latency is worse than burst latency** (EOU 320: p50 69.5 ms paced
  against 38.5 ms burst). Budgets must be judged on the paced `window`
  numbers, which is what the go/no-go uses.
- **First loads are long.** Each EOU variant took one to three minutes to
  load the first time (Neural Engine compilation, inflated by the load on
  the machine). The model manager (#27) must load models ahead of the
  first conversation, behind onboarding's download step (#44), and never on
  the record button's critical path.
- **Cold load is a first-launch problem, warm load is not.** TDT v3 took
  127 s to load from a fresh location (the on-device compile) and 1.2 s
  once the OS had cached it: the copy-to-a-new-path method does force the
  compile. The footprint barely moved (34 MB) while the kernel's neural
  ledger grew 468 MB, which is why both are recorded.
- **Foundation Models labels take about two seconds** with the production
  labeler (p50 2.1 to 2.6 s, cold 3.1 s on the loaded Mac). That is fine off
  the critical path (#53 labels after a boundary is detected), but too slow
  to run per exchange. With a 1.5 s lead outside the timed region,
  prewarming made no consistent difference (±170 ms either way across the
  two runs). The method can only show this for a model that is already
  resident: each plain request follows the previous prewarmed one by about
  1.5 s, so the plain row is warm too. So the Mac shows no benefit when the
  model is already loaded, and says nothing about a prewarm after the model
  was evicted; the iPhone runs decide whether #52/#53 should prewarm.
- **WeSpeaker costs the same for 1.5 s and 3 s windows.** FluidAudio's
  export takes a fixed 10 s input and repeat-pads shorter audio (verified
  in `EmbeddingExtractor.fillWaveformBuffer`), so the "score at 1.5 s,
  re-score at 3 s" plan in #1 costs two full inferences. #45 should either
  accept that or export a variable-length (or 3 s) model.
- **CAM++ is not a drop-in challenger on iOS.** FluidAudio loads it with
  `.cpuAndGPU` because its dynamic time axis is rejected by the Neural
  Engine compiler, and iOS doesn't allow GPU work in the background; it was
  also an order of magnitude slower here.

## EOU-320 go/no-go

**Rule.** Parakeet EOU at 320 ms is the default chunk size (#1, #29) if, on
**at least two physical iPhones**, in Release runs that stayed below the
`serious` thermal state:

| Criterion | Budget | Why |
| --- | --- | --- |
| Paced `window` p95 | ≤ 50% of the 320 ms hop (≤ 160 ms) | VAD, voice ID and playback share the hop |
| Burst `rtfx` | ≥ 4× | The model is busy at most a quarter of the time, so a one-hour session stays cool |
| `memory.footprintGrowth` | ≤ 300 MB | Leaves room for TDT, WeSpeaker and the embedding model |

A miss on any device is a **no-go** for that device class. The rule is
code: `EouChunkSizeDecision.evaluate(reports:)` in BlauTranscription
returns `.go`, `.noGo(reasons:)` or `.pending`, and
`AsrBenchmarks.testParakeetEou320ms` fails on a device that misses the
latency budget.

**If no-go:** use 1280 ms on the failing device class (one window per
1.28 s; the Mac run shows a 26× real-time factor) and accept the slower
partials, since end of utterance, not partial text, gates the turn. 160 ms
is not a fallback (see above).

**Verdict: pending.** No iPhone has reported yet (`.pending("0 of 2 iPhones
reported qualifying results")`). Provisionally EOU-320 stays the default:
FluidAudio documents 14× RTFx for it on LibriSpeech (source comment on
`StreamingChunkSize.ms320`), and on the loaded Mac its burst p95 used 15% of
the hop and its paced p95 54%, a load-induced miss that has to be checked
on an idle iPhone.

## Background Neural Engine behaviour

### What the SDK says (verified against the iOS 27.2 SDK in Xcode 27.2)

- **There is no `continued-processing.inference` entitlement.**
  `BGContinuedProcessingTaskRequest.Resources` has exactly one resource
  besides the default: `.gpu`, which needs
  `com.apple.developer.background-tasks.continued-processing.gpu`
  (`BackgroundTasks/BGTaskRequest.h`). Nothing in BackgroundTasks or Core ML
  mentions the Neural Engine or background inference. The entitlement named
  in #1 does not exist in this SDK.
- `BGContinuedProcessingTask` is the wrong tool anyway: it is a
  user-initiated job with system progress UI that the system may queue or
  refuse, not a way to keep a conversation running.
- Core ML has no background-specific API or error code. The only runtime
  signal is `MLModel.availableComputeDevices`, which the probe records each
  window.
- FluidAudio pins Parakeet to `.cpuAndNeuralEngine` and never uses the GPU
  "which keeps background execution permitted on iOS" (`AsrModels.load`);
  its diarizer (WeSpeaker) defaults to `.all`, which may use the GPU, so
  `WeSpeakerExtractor` passes `.cpuAndNeuralEngine` explicitly.

### Decision

Before the probe has run on a device:

1. **No entitlement is requested.** The inference entitlement doesn't exist
   and Blau doesn't need the GPU.
2. **Every model loads with `.cpuAndNeuralEngine` or `.cpuOnly`, never
   `.all` or `.cpuAndGPU`** (GPU work is refused in the background). This
   rules out CAM++ as FluidAudio ships it.
3. **The audio session stays active and recording for the whole
   conversation** (`audio` background mode), which keeps the process
   running when the screen locks (#23, #26).
4. **#26 adds a runtime monitor** that watches per-window latency and Core
   ML errors while off screen and applies the mitigation the probe
   recommends (`BackgroundInferenceMonitor`, see
   [background.md](background.md); it ships with
   `BackgroundInferenceMitigation.shipping = .keepNeuralEngine` until the
   verdict below is in). `BackgroundInferenceMitigation.recommended(for:hop:)`
   encodes the table:

| Probe verdict | Meaning | Mitigation |
| --- | --- | --- |
| `works` (off-screen p50 ≤ 1.5× foreground) | The Neural Engine keeps working | `keepNeuralEngine`: nothing to do |
| `degraded` or `cpuFallback`, off-screen p95 ≤ 80% of the hop | Slower (or silently on the CPU) but keeps up | `acceptCPUFallback`: keep going, monitor latency |
| `degraded` or `cpuFallback`, off-screen p95 > 80% of the hop | Can't keep up | `switchToSystemTranscriber`: hand ASR to `SpeechTranscriber` (#31) while backgrounded |
| `errors`, CPU-only p95 ≤ 80% of the hop | Core ML throws off screen | `reloadOnCPUWhenBackgrounded`: reload ASR with `.cpuOnly` on `didEnterBackground`, back to the Neural Engine on return |
| `errors`, CPU too slow | | `switchToSystemTranscriber` |
| `suspended` (< 50% of expected windows ran) | The app stopped getting time | `fixBackgroundExecution`: the audio session isn't keeping the app alive; fix that first |

A silent CPU fallback is told apart from ordinary slowdown by comparing
off-screen latency with the CPU-only baseline of the same model: if it is
closer (on a log scale) to the CPU baseline than to the foreground latency,
the work moved to the CPU.

Coverage counts each off-screen window as owning the time until the next
window, and the last one as owning the time until the run ended. A
suspension that lasts past the end of the run (the tester unlocks late)
therefore still reads as `suspended`, even though the window after resuming
is a warm-up and records no sample.

**Empirical result: pending** (needs an iPhone on iOS 27; see the probe
procedure above). The probe's JSON report goes next to the device's
benchmark report.

## Voice ID: speaker embeddings (#45)

`WeSpeakerEmbedder` (BlauVoiceID) on FluidAudio's WeSpeaker ResNet34-LM
conversion, `wespeaker_v2.mlmodelc` at revision `df2625ac` (8-bit
palettized weights, Float32 compute). See [voice-id.md](voice-id.md).

Target from #45: **under 15 ms per embedding on the Neural Engine.**

### Latency

Each scenario embeds one segment: the gate's 1.5 s first score, its 3 s
re-score, and a 6 s enrollment clip. "Embedder" is the full
`WeSpeakerEmbedder.embed` call (validation, padding, Core ML, normalization);
"model" is `CoreMLSpeakerEmbeddingNetwork.embed` alone (padding and Core ML
prediction). 100 timed runs after 10 warm-up runs, deterministic
speech-like audio (`SpeakerEmbeddingBenchmark.syntheticSpeech`).

The model always processes a fixed 10 s window (shorter speech is repeated
to fill it), so latency barely depends on the segment's length.

#### iPhone (production target)

| Device | Compute units | Scenario | Embedder p50 / p90 (ms) | Model p50 / p90 (ms) | Result |
| --- | --- | --- | --- | --- | --- |
| iPhone (A17 Pro or later) | `cpuAndNeuralEngine` | 1.5 s window | Pending | Pending | Pending |
| iPhone (A17 Pro or later) | `cpuAndNeuralEngine` | 3 s window | Pending | Pending | Pending |
| iPhone (A17 Pro or later) | `cpuOnly` | 3 s window | Pending | Pending | Pending |

How to run: launch Blau on the iPhone and let model setup finish, then run
`SpeakerEmbeddingDeviceBenchmarkTests` (in `BlauTests`) on the device with
`BLAU_DEVICE_TESTS=1` set in the scheme's test environment. It reads the
installed model from the app's store and prints the tables to the test log.
Run with the phone plugged in, unlocked and cool.

#### Mac host (Apple M3 Max, macOS 27.2, Xcode 27.2 debug test build)

Recorded 2026-10-07 with
`BLAU_SPEAKER_BENCHMARK=1 BLAU_SPEAKER_MODEL_DIR=<model dir> swift test --filter SpeakerEmbeddingModelTests`.

> The host was heavily loaded while these ran (load average about 300 on 16
> cores from parallel builds), and Core ML puts nearly all of this model on
> the CPU (see below), so treat these as upper bounds. Repeated runs varied
> by up to 2×.

| Compute units | Scenario | Embedder p50 / p90 (ms) | Model p50 / p90 (ms) |
| --- | --- | --- | --- |
| `cpuAndNeuralEngine` (production) | 1.5 s window | 31.49 / 45.10 | 29.83 / 30.41 |
| `cpuAndNeuralEngine` (production) | 3 s window | 32.88 / 33.09 | 29.90 / 30.90 |
| `cpuAndNeuralEngine` (production) | 6 s clip | 35.92 / 36.53 | 29.84 / 30.40 |
| `cpuOnly` | 1.5 s window | 65.20 / 69.74 | 59.32 / 66.07 |
| `cpuOnly` | 3 s window | 68.28 / 73.21 | 46.36 / 48.81 |
| `cpuAndGPU` | 3 s window | 41.01 / 48.18 | 20.25 / 22.04 |
| `all` | 1.5 s window | 21.40 / 22.02 | 27.79 / 40.93 |
| `all` | 3 s window | 23.76 / 27.70 | 22.86 / 24.41 |

An earlier run under similar load measured `cpuOnly` at 31.90 / 33.17 ms and
`cpuAndNeuralEngine` at 34.72 / 41.73 ms (embedder, 1.5 s window).

**Result: the 15 ms target is not met on this Mac.** The embedder's own work
(validation, copying, normalization) adds about 2 to 6 ms in a debug build,
growing with the segment's length; the rest is the model.

### Why: where Core ML runs the model

`MLComputePlan` for `wespeaker_v2.mlmodelc` with `cpuAndNeuralEngine` on the
Mac prefers the **CPU for all 1,149 operations (99.3% of the estimated
cost)**; nothing is placed on the Neural Engine
(`SpeakerEmbeddingModelTests.computePlan`). The conversion computes in
Float32, builds its filterbank from about 1,000 `slice_by_index` operations
over a fixed 10 s waveform, and pads every input to 10 s, so a 1.5 s segment
costs as much as a 10 s one.

For comparison, a model-only measurement (not shipped, recorded to inform a
follow-up) of the other conversion #45 names,
[`aufklarer/WeSpeaker-ResNet34-LM-CoreML`](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-CoreML)
at `b358f33f` (MIT; Float16; takes an 80-bin log-mel input with enumerated
lengths of 20 to 2,000 frames), on the same loaded Mac with random input:

| Input | `cpuOnly` p50 / p90 (ms) | `cpuAndNeuralEngine` p50 / p90 (ms) | `all` p50 / p90 (ms) |
| --- | --- | --- | --- |
| 300 frames (3 s) | 8.37 / 10.31 | 14.69 / 16.86 | 3.60 / 4.56 |
| 200 frames (2 s) | 6.79 / 7.16 | 8.85 / 9.14 | 1.74 / 2.23 |

That model excludes the filterbank (Blau would compute Kaldi-compatible
fbank features in Swift) and isn't in the pinned model manifest, so
switching is a separate change. `SpeakerEmbeddingNetwork` is the seam: an
fbank front end plus a network for that model would drop in behind
`WeSpeakerEmbedder` unchanged, and `matchesFluidAudiosEmbeddingExtractor`-
style tests against the current model (same pyannote weights) can verify the
front end. Decide after the iPhone numbers above are in.

### Discrimination on the fixture set

The 12 CMU ARCTIC clips in `Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures`
(4 speakers × 3 sentences, every speaker reading the same sentences): 12
same-speaker pairs and 54 different-speaker pairs, scored with cosine
similarity. From `SpeakerEmbeddingModelTests.sameSpeakerScoresAboveDifferentSpeakers`
on the Mac (`cpuAndNeuralEngine`), 2026-10-07:

| Window | Same speaker min / mean | Different speaker max / mean | Margin (min same − max different) |
| --- | --- | --- | --- |
| 1.5 s | 0.574 / 0.669 | 0.372 / 0.078 | 0.203 |
| 3 s | 0.683 / 0.764 | 0.368 / 0.073 | 0.315 |
| Whole clip (2.9–3.5 s) | 0.681 / 0.768 | 0.371 / 0.072 | 0.310 |

Every same-speaker pair scores above every different-speaker pair at all
three windows. The hardest different-speaker pairs are the two female
speakers (`clb`/`slt`). The gate's thresholds are calibrated on a larger,
cross-session set with simulated rooms and noise in
[voice-id-eval.md](voice-id-eval.md) (#48).

## Text embedding model (#59)

Which model embeds text for memory search (#60, #62) and topic
segmentation (#52). Candidates from #59: EmbeddingGemma-300M (the
architecture's default in #1), Qwen3-Embedding-0.6B, Model2Vec
potion-retrieval-32M (fallback) and Apple's `NLContextualEmbedding`
(baseline).

**Status (2026-10-07).** Measured on this Mac: retrieval quality of every
candidate except EmbeddingGemma, and a full Core ML conversion of
Qwen3-Embedding-0.6B (numerics, Neural Engine placement, latency, size,
retrieval through Blau's Swift path). **EmbeddingGemma's own numbers are
pending**: `google/embeddinggemma-300m` is gated behind the Gemma Terms of
Use, which the repository owner has to accept on Hugging Face (an agent
must not accept a license on someone's behalf). Its conversion path is
built and tested on a randomly initialized model with the same layout, so
finishing is two commands (below). **No model is hosted yet** (see
[Hosting](#hosting-the-model)). iPhone latencies are pending, as for #22.

### Decision

1. **Model: EmbeddingGemma-300M stays the provisional choice**, at 256-d
   Matryoshka, int8 (`TextEmbeddingModelSpec.chosen`), pending its own
   numbers. The rule that confirms or overturns it is code,
   `EmbeddingModelSelection` in BlauMemory: a candidate qualifies with **no
   non-finite vectors on the Neural Engine, an iPhone `embed.128tok` p95 ≤
   50 ms and a download ≤ 400 MB**; among qualifying candidates the
   smallest download within **0.03 Recall@5** of the best wins. Only
   memory candidates (EmbeddingGemma, Qwen3) take part: each measurement
   carries a `role`, and `NLContextualEmbedding` (`.baseline`) and
   potion-retrieval-32M (`.cpuFallback`) are never selected and never hold
   the verdict at pending. Over what was measured
   (`EmbeddingModelSelection.measured`) it returns
   `.pending(provisional: "embeddinggemma-300m", ...)`, missing only
   EmbeddingGemma's numbers; once they pass, it returns
   `.chosen("embeddinggemma-300m", ...)`.
2. **Fallback: Qwen3-Embedding-0.6B**, if EmbeddingGemma's Neural Engine
   vectors aren't finite. It
   is the strongest model measured here (Recall@5 0.809 at 256-d int8),
   converts cleanly to fp16 with no NaN on the Neural Engine, and runs a
   128-token chunk in 12 ms on the M3 Max's Neural Engine. Its cost is
   size: twice EmbeddingGemma's parameters, so even with int8 weights
   (442 MB, Recall@5 0.797) and an int8 token table (155 MB) it is about
   600 MB, over the 400 MB budget; int4 weights didn't stay on the Neural
   Engine (below). Falling back to it means raising the budget, which is
   the owner's call. The rule makes this explicit
   (`EmbeddingModelSelection.fallback`): when no memory candidate
   qualifies **because EmbeddingGemma's vectors aren't finite**, it returns
   `.fallback("qwen3-embedding-0.6b", reasons:, missing:)` as long as
   Qwen3's vectors are finite. `reasons` lists the budgets Qwen3 breaks
   (today `download 753 MB > 400 MB`), `missing` its numbers still to
   measure (its iPhone latency). With `maximumDownloadBytes` raised past
   its size, Qwen3 qualifies and the rule returns
   `.chosen("qwen3-embedding-0.6b", ...)`. Qwen3 can't rescue a latency or
   download failure (it is about twice as slow and larger), so if
   EmbeddingGemma's vectors are finite but it misses the latency or
   download budget, the rule returns `.overBudget("embeddinggemma-300m",
   reasons:, missing:)` instead: the owner either raises that budget for
   EmbeddingGemma or keeps looking. Only when nothing is usable is the
   verdict `.noneQualifies`. It never falls back to potion-retrieval-32M
   (decision 4). EmbeddingGemma is about 100M
   transformer parameters plus a 201M-parameter table, roughly 300 MB at
   int8 for both.
3. **Not Apple's `NLContextualEmbedding`** for memory: Recall@5 0.325, below
   plain BM25 (0.517). It is not trained for retrieval. (It stays the topic
   segmenter's embedder until #60 lands.)
4. **potion-retrieval-32M only as a CPU fallback**: 0.620 Recall@5 is far
   behind the transformers, but it needs no Core ML model, costs
   microseconds on the CPU and is an option for #26 if the Neural Engine is
   unavailable off screen. It is not a memory model, so the selection rule
   never picks it (`role: .cpuFallback`).
5. **Ship the transformer as a split Core ML model**: `inputs_embeds` plus
   a memory-mapped token table, not token IDs (next section). This is what
   puts the model on the Neural Engine at all, and it applies to
   EmbeddingGemma's 262k-row table even more than to Qwen3's.

Also for the follow-ups:

- **256-d costs 4 points of Recall@5 against 512-d** for Qwen3 (0.809 vs
  0.851; 128-d: 0.770). #1 fixes 256-d; at personal scale (~100k chunks)
  512-d int8 is 51 MB, so #62 may want to revisit. int8 storage itself is
  free (identical metrics to float32 at every width).
- **Equal-weight RRF with BM25 hurts a strong dense model on this set**
  (Qwen3 256-d: Recall@5 0.809 alone, 0.704 fused). BM25 wins every
  `keyword` query (names, numbers) and loses most paraphrases. #64 should
  weight the two rankings (or gate BM25 by query type) and tune it on this
  eval set rather than use plain RRF.
- **Chunk length.** The longest eval text is 72 tokens with Qwen3's
  tokenizer (prompt included), so the fixed 128-token model fits it. Long
  exchanges will need 256 (a second fixed-length model, or truncation);
  #60 decides.

### The eval set

`Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/RetrievalEval/`: **200
queries over 216 documents** about one fictional user (Jordan Hale, founder
of a restaurant-software startup, "Larderly"), one JSON file per
category:

| Category | Queries | Documents | What it stores |
| --- | --- | --- | --- |
| `company` | 55 | 55 company facts | Metrics by month, team, pricing, fundraising, policies (#65's company knowledge) |
| `yc` | 45 | 45 collection items | YC interview questions with the user's prepared answers (#65, #69) |
| `conversation` | 65 | 76 exchanges | Past voice conversations as exchange-level chunks, `User: … Blau: …` (#62) |
| `profile` | 35 | 40 facts and notes | Extracted facts and notes about the user's life (#66) |

Queries are phrased the way the user (or Grok, through `search_memory`)
would ask, mostly paraphrases with little word overlap (191 `paraphrase`,
9 `keyword`). Distractors are deliberate: MRR for three different months,
several running or apartment exchanges, YC answers that restate company
facts. Where a fact appears both as a company fact and as a YC answer,
both are relevant. Metrics: **Recall@5** (share of relevant documents in
the top 5), **Hit@5** (any relevant in the top 5), **MRR@10**, nDCG@10;
`RetrievalMetrics` (Swift) and `evalset.py` (Python) implement the same
definitions. Prompts are each model card's (`TextEmbeddingModelSpec`,
`candidates.py`); Qwen3's query instruction is Blau's own ("Given a
question about the user's life, work or past conversations, retrieve the
memory that answers it").

### Retrieval quality

Reference models (PyTorch fp32, sentence-transformers / model2vec), int8
vectors ranked by cosine, as the index stores them. 2026-10-07,
`eval_retrieval.py`.

| Model | Width | Recall@5 | Hit@5 | Hit@1 | MRR@10 | + BM25 (RRF) Recall@5 |
| --- | --- | --- | --- | --- | --- | --- |
| BM25 alone (k1 1.2, b 0.75) | n/a | 0.517 | 0.570 | 0.355 | 0.443 | n/a |
| Apple `NLContextualEmbedding`, mean-pooled (Swift, OS model) | 512 | 0.325 | 0.350 | 0.175 | 0.255 | n/a |
| potion-retrieval-32M | 512 | 0.645 | 0.670 | 0.420 | 0.525 | 0.582 |
| potion-retrieval-32M | **256** | 0.620 | 0.650 | 0.400 | 0.502 | 0.589 |
| Qwen3-Embedding-0.6B | 1024 | 0.843 | 0.880 | 0.680 | 0.770 | 0.704 |
| Qwen3-Embedding-0.6B | 512 | 0.851 | 0.885 | 0.670 | 0.760 | 0.702 |
| Qwen3-Embedding-0.6B | **256** | 0.809 | 0.845 | 0.610 | 0.714 | 0.704 |
| Qwen3-Embedding-0.6B | 128 | 0.770 | 0.795 | 0.590 | 0.680 | 0.694 |
| EmbeddingGemma-300M | 768 / 256 / 128 | pending (gated) | | | | |

By category, Recall@5 at 256-d int8:

| Model | company | yc | conversation | profile |
| --- | --- | --- | --- | --- |
| BM25 | 0.491 | 0.496 | 0.638 | 0.357 |
| NLContextualEmbedding | 0.209 | 0.178 | 0.615 | 0.157 |
| potion-retrieval-32M | 0.673 | 0.311 | 0.808 | 0.586 |
| Qwen3-Embedding-0.6B | 0.809 | 0.552 | 0.900 | 0.971 |

YC answers are the hardest slice for every model: interview questions
("what's your secret insight about this market") share little with the
stored answer, and many answers restate each other. #69's practice mode
should match on the stored *question* as well as the answer.

### Core ML conversion and the Neural Engine

`scripts/embeddings/convert_coreml.py` converts a candidate and verifies
it against the PyTorch reference on every eval text. What it found on
Qwen3-Embedding-0.6B (EmbeddingGemma shares every issue but the last):

- **The token-embedding lookup keeps the whole model off the Neural
  Engine.** Converted as usual (token IDs in), Core ML's compute plan put
  all 1,914 operations on the CPU, with enumerated or fixed shapes. The
  same 28 layers fed `inputs_embeds` were planned 100% on the Neural
  Engine; the gather over the 151,669 × 1,024 table is what blocks it
  (bisected: `ids + bias` → 0% Neural Engine, `embeds + bias` → 100%).
  EmbeddingGemma's table is 262,144 × 768. So the converted model starts
  at `inputs_embeds`, and the table ships beside it as raw float16
  (`<name>.token-embeddings.f16`) that the app memory-maps
  (`TokenEmbeddingTable`); `CoreMLTokenEmbeddingModel` fills
  `inputs_embeds` from it. Only the rows of tokens actually used become
  resident.
- **Masks and pooling are float arithmetic.** transformers builds its
  attention masks with `vmap`, which `torch.jit.trace` can't record, and
  coremltools mis-converted a first attempt built from `torch.where` and a
  `gather` (float index). The wrapper builds the additive masks (causal for Qwen3;
  bidirectional with a sliding window for Gemma3) and the pooling
  (masked mean; one-hot last token) from float ops only, using −1e4 rather
  than −inf so fp16 never produces an all-−inf softmax row. It is checked
  against sentence-transformers before every conversion (min cosine
  1.000000, padded and unpadded).
- **A fixed sequence length** (128 by default) makes the graph fully
  static, which the Neural Engine compiler wants.
- **fp16 numerics: stable for Qwen3** (no NaN or infinity on any of the 416
  eval texts, on CPU or Neural Engine). The EmbeddingGemma model card warns
  that its activations don't support float16, so this is the first thing
  to check for it: `nonFiniteOutputs` in the verification report, and
  `--precision fp32` (CPU/GPU only) as the comparison.

Qwen3-Embedding-0.6B, fixed 128 tokens, M3 Max (macOS 27.2, Xcode 27.2),
`coremltools` predictions; Recall@5 at 256-d int8 from the Core ML outputs
(reference: 0.809). The machine was shared with other builds (load average
25 to 130), so latencies are upper bounds.

| Variant | Neural Engine ops (plan) | Non-finite | Min cosine to fp32 (256-d) | Recall@5 (ANE) | `cpuAndNeuralEngine` p50 / p95 | `cpuOnly` p50 | Model + table |
| --- | --- | --- | --- | --- | --- | --- | --- |
| IDs in, table inside (fp16, enumerated 64/128/256) | 0% | 0 | 0.99967 | 0.809 (ran on CPU) | 342 / 374 ms | 227 ms | 1,192 MB |
| **Split, fp16 weights** | **100%** | 0 | 0.99967 | **0.809** | **11.9 / 12.0 ms** | 54.7 ms | 882 + 311 MB |
| Split, int8 weights (per channel) | 100% | 0 | 0.99678 | 0.797 | 16.9 / 17.0 ms | 191 ms | 442 + 311 MB |
| Split, int4 weights (block 32) | 45% of ops, 2% of estimated cost | 0 | 0.85285 | 0.804 | 44.6 / 47.5 ms | 45.0 ms | 249 + 311 MB |

Neural Engine share counts compute operations only (constants and the
`constexpr` weight decompression are excluded). int8 weights halve the
model for 0.012 Recall@5 and stay on the Neural Engine. Block-wise int4
does not on this M3 Max: Core ML planned 96% of the cost on the CPU, so
it ran no faster than `cpuOnly`, and individual vectors drifted badly (min
cosine 0.85, although Recall@5 held at 0.804). Newer Neural Engines (A17
Pro, M4) are documented to accelerate block-wise int4; that and 4-bit
palettization are for #60 to measure on an iPhone, not assumed here.

Through Blau's Swift path (`CoreMLTokenEmbeddingModel` with the token
table, `PretokenizedTextEmbedder`, `EmbeddingRetrievalEvaluator`; debug
build, `cpuAndNeuralEngine`): Recall@5 **0.809**, MRR@10 0.713, zero
non-finite vectors, `embed.128tok` p50 / p95 16.2 / 25.5 ms including the
table lookup, Matryoshka truncation and int8 quantization; first load
(compile included) 15.7 s, `memory.neuralGrowth` 846 MB for the fp16
weights.

The token table is the larger download once the weights are compressed.
Stored as int8 with a scale per row it would halve (Qwen3: 155 MB;
EmbeddingGemma: about 200 MB); #60 should do that and dequantize rows into
`inputs_embeds` as it copies them.

### Finishing EmbeddingGemma

After accepting the Gemma Terms of Use at
[huggingface.co/google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
with the account in `hf auth login`:

```sh
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r scripts/embeddings/requirements.txt
.venv/bin/python scripts/embeddings/eval_retrieval.py --only embeddinggemma-300m --output .build/eval.json
.venv/bin/python scripts/embeddings/convert_coreml.py --model embeddinggemma-300m            # fp16, split, 128
.venv/bin/python scripts/embeddings/convert_coreml.py --model embeddinggemma-300m --weights int8
```

(`convert_coreml.py` writes the int8 token table by default since #60;
`--table float16` gives #59's format.) Then pin `revision` in
`candidates.py` to the commit you evaluated, fill
the EmbeddingGemma rows above, run `make bench` with
`EmbeddingGemma300M.mlpackage` and its `.token-embeddings.f16` in
`BlauBenchmarks/Assets/` on two iPhones, and feed the numbers to
`EmbeddingModelSelection().evaluate(_:)` (update the EmbeddingGemma entry of
`EmbeddingModelSelection.measured`; the baselines need no iPhone latency).
If fp16 produces non-finite vectors, compare `--precision fp32` (it can't
use the Neural Engine) and record both; the rule then returns
`.fallback("qwen3-embedding-0.6b", ...)`, which lists the 400 MB download
budget Qwen3 breaks. Adopting it means the owner raises
`maximumDownloadBytes` (and Qwen3's iPhone latency lands), after which the
rule returns `.chosen("qwen3-embedding-0.6b", ...)`. If EmbeddingGemma's
vectors are finite but it misses the 50 ms latency or 400 MB download
budget, the rule returns `.overBudget("embeddinggemma-300m", ...)` rather
than switching to the larger, slower Qwen3; raising that budget then makes
it `.chosen("embeddinggemma-300m", ...)`.

### Hosting the model

Not done: hosting publishes model weights under an account (the Gemma
terms require passing their notice along; Qwen3 is Apache-2.0), which is
the owner's call. `convert_coreml.py` prepares everything: a `hosting/`
folder with the compiled `.mlmodelc`, the token table, the tokenizer files,
`blau-embedding.json` (prompts, widths, sequence length, source revision)
and the license notice, plus `<name>.hosting-manifest.json` with every
file's size and SHA-256. To publish:

```sh
hf repo create <owner>/blau-embeddinggemma-300m-coreml --type model
hf upload <owner>/blau-embeddinggemma-300m-coreml .build/Embeddings/EmbeddingGemma300M-fp16-wint8/hosting .
```

then pin the resulting commit SHA like every other model: uncomment the
`textEmbedding` entry in `scripts/update-model-manifest.py` with the new
repository and commit and run it ([models.md](models.md)). #60 added
`ModelID.textEmbedding` and the service that loads it, so that is all it
takes for `ModelManager` to download the model and for memory and topics
to use it.

### Reproducing

| What | Command |
| --- | --- |
| Python environment | `uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r scripts/embeddings/requirements.txt` |
| Reference retrieval eval (all candidates, BM25, hybrid) | `.venv/bin/python scripts/embeddings/eval_retrieval.py --output .build/eval.json` |
| Convert and verify | `.venv/bin/python scripts/embeddings/convert_coreml.py --model qwen3-embedding-0.6b [--weights int8\|int4] [--lengths 256] [--no-split]` |
| Script tests (tiny random Gemma3 and Qwen3 models through the real conversion) | `.venv/bin/python scripts/embeddings/test_embeddings.py` |
| `NLContextualEmbedding` baseline (Swift) | `BLAU_DEVICE_TESTS=1 swift test --filter RealModelEmbeddingEvalTests` in `Packages/BlauKit` |
| A converted model through the Swift path | add `BLAU_EMBEDDING_MODEL=<dir>/<name>.mlpackage BLAU_EMBEDDING_TOKENS=<dir>/<name>.eval-tokens.json BLAU_EMBEDDING_SPEC=<spec id>` (and optionally `BLAU_EMBEDDING_COMPUTE_UNITS=cpuOnly`) |

## Shared embedding service (#60)

#60 built the service on #59's choice ([embeddings.md](embeddings.md)). Its
acceptance criterion, **a batch of 32 chunks embeds within the budget from
the spike**, reads #59's budget (an iPhone `embed.128tok` p95 of at most
50 ms per chunk, `EmbeddingModelSelection.maximumDeviceP95Milliseconds`)
as at most **1.6 s per batch of 32**, measured through the whole service:
prompt, Swift tokenizer, token table, Core ML, Matryoshka 256-d and int8.
`memory.embed.batch32` fills each of the 32 chunks to about 90% of the
128-token sequence (124 tokens on average), the case the budget is
defined for.

**Mac reference** (M3 Max, macOS 27.2, `cpuAndNeuralEngine`, optimized
build, `RealTextEmbeddingModelTests`). EmbeddingGemma's weights are gated,
so these use Qwen3-Embedding-0.6B (#59's fallback, int8 weights), which is
twice EmbeddingGemma's size. The machine was shared with other builds (load
average 250 to 370), so latencies are upper bounds and the two table
formats are within noise of each other:

| Table | Retrieval through Swift (Recall@5 / Hit@5 / MRR@10) | `embed.batch32`, 124-token chunks, p50 / p95 | Per chunk p50 | Eval chunks (42–72 tokens), p50 / p95 |
| --- | --- | --- | --- | --- |
| float16 | 0.797 / 0.830 / 0.708 | 633 / 688 ms | 12–20 ms | 372 / 374 ms |
| int8 (#60 default) | 0.797 / 0.830 / 0.711 | 681 / 714 ms | 12–21 ms | 473 / 538 ms |

Both are well inside 1.6 s, and the retrieval numbers equal the Python
reference conversion's (0.797 / 0.830 / 0.708), which checks the Swift
tokenizer and the int8 table end to end. Tokenizer load (optimized): 0.43 s
for Gemma's 32 MB `tokenizer.json`, 0.10 s for Qwen's; encoding about
1.2 µs per token. Model load with Core ML's cache warm: 0.1 to 0.3 s.

**iPhone: pending.** It needs a device and the hosted EmbeddingGemma
model. To measure: finish EmbeddingGemma (above), then `make bench` with
its `hosting/` folder in `BlauBenchmarks/Assets/`, and fill the
`Shared service` row of the results table.

## Memory index (#62)

#62's acceptance criterion is **a search over 50k chunks within 20 ms p95
on an A17**. `memory.index.search50k` writes 50,000 synthetic exchange-like
chunks (Zipf-distributed words, so BM25 sees realistic posting lists) with
random 256-d int8 vectors (which cost the brute-force scan exactly what real
ones do, so no model is needed) into an on-disk index, reopens it as at
launch, and runs 200 queries three ways: the vector scan alone, BM25 alone,
and both at once (`search.hybrid`, how #64 runs them). The budget applies
to `search.hybrid`. See [memory-index.md](memory-index.md).

**Mac reference** (M3 Max, macOS 27.2, optimized build, shared with other
builds; `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O --scratch-path
.build/optimized --filter MemoryIndexSearchBenchmarkTests`, 2026-10-07):

| Metric | M3 Max (loaded) |
| --- | --- |
| `search.hybrid` p50 / p95 | 2.6 / 5.0 ms |
| `search.vector` p50 / p95 | 2.4 / 3.6 ms |
| `search.keyword` p50 / p95 | 1.5 / 3.7 ms |
| `load` (50k vectors into the matrix) | 422 ms |
| `build` (writing 50k chunks with FTS5 and vectors) | 20.5 s |

Before the common-word cutoff (`MemoryIndex.commonTermDocuments`),
`search.keyword` was 12.9 / 36.9 ms p50 / p95 on the same data: FTS5 scores
every matching row with `bm25()`, and an OR query over a word found in
thousands of chunks matched up to 9,400 of them. The vector scan alone
measured 1.5 ms per query for 50k × 256 in a standalone loop.

The XCTest wiring was checked end to end on a temporary iPhone 15 Pro
simulator (iOS 26.5, Release, `BLAU_DEVICE_TESTS=1
BLAU_BENCH_ALLOW_SIMULATOR=1`, `-only-testing:BlauBenchmarks/MemoryIndexBenchmarks`):
`search.hybrid` p50 / p95 6.75 / 21.7 ms, `search.vector` 5.64 / 21.2 ms,
`search.keyword` 2.84 / 8.52 ms, `load` 111 ms, a 97 MB index file. The
simulator runs on the Mac's CPU, which was under a load average of 550 to
950 at the time, so this validates the harness, not the A17 number.

**iPhone: pending.** It needs an A17 device: `make bench` runs
`MemoryIndexBenchmarks.testSearch50k`, or run "Memory index search, 50k
chunks" on the debug benchmark screen, and fill the `Memory index` rows of
the results table.

## After the numbers land

1. Paste the comparison table (`BenchmarkReport.comparisonTable`) and the
   probe verdicts into the tables above.
2. Run `EouChunkSizeDecision.evaluate` over the reports and record the
   verdict.
3. Update the ASR, Voice ID and Perf rows of "Key decisions" in #1, and the
   Parakeet research brief's background note, with the verdicts.
