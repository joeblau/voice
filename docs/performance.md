# Performance and telemetry

Blau measures itself from the first commit. Every subsystem logs through one
set of `Logger` categories and marks its pipeline stages with `OSSignposter`
intervals, all from the `BlauTelemetry` module. Instruments, the XCTest
performance suite (#73), the latency budget (#74) and the debug HUD (#71)
all build on the names defined here.

This document is the naming reference. A unit test
(`PipelineIntervalTests.performanceDocListsEveryInterval`) fails if the
**Canonical intervals** table below and `PipelineInterval` drift apart, so
change both together.

## Logging

Every logger uses the subsystem **`com.joeblau.blau`** and one category per
area. Use the static loggers on `Log`; don't create your own `Logger` or
call `print`.

| Category   | Logger         | Signposter           | Owner                                                     |
| ---------- | -------------- | -------------------- | --------------------------------------------------------- |
| `audio`    | `Log.audio`    | `Signposts.audio`    | `BlauAudio`: session, capture, fan-out, playback          |
| `asr`      | `Log.asr`      | `Signposts.asr`      | `BlauTranscription`: VAD, streaming ASR, second pass      |
| `voiceid`  | `Log.voiceID`  | `Signposts.voiceID`  | `BlauVoiceID`: embeddings, enrollment, verification gate  |
| `realtime` | `Log.realtime` | `Signposts.realtime` | `BlauRealtime`: xAI WebSocket, sessions, turns, tools     |
| `topics`   | `Log.topics`   | `Signposts.topics`   | `BlauTopics`: segmentation and labeling                   |
| `memory`   | `Log.memory`   | `Signposts.memory`   | `BlauMemory`: embeddings, index, retrieval                |
| `data`     | `Log.data`     | `Signposts.data`     | `BlauPersistence`: SwiftData, CloudKit sync               |
| `ui`       | `Log.ui`       | `Signposts.ui`       | App target: views and composition root                    |
| `perf`     | `Log.performance` | `Signposts.performance` | `BlauTelemetry`: the thermal and power policy (#75)  |

```swift
import BlauTelemetry

Log.audio.notice("Engine started at \(sampleRate, privacy: .public) Hz")
Log.asr.info("Committed utterance: \(text, privacy: .private)")
Log.realtime.error("Socket closed: \(code, privacy: .public)")
```

Levels: `debug` for high-frequency detail (not persisted by default),
`info` for useful state, `notice` for lifecycle events worth keeping,
`error` for recoverable failures, `fault` for bugs.

### Privacy

- **Anything the user said or wrote is private.** Transcripts, partial ASR
  text, Grok's replies, memory facts, topic titles, knowledge-base text and
  search queries are always interpolated with `privacy: .private`, or
  `.private(mask: .hash)` when you need to correlate lines without seeing the
  text. Dynamic strings already default to private, but spell it out so the
  intent is visible in review and survives copy and paste.
- **Metadata is public.** Counts, durations, sample rates, states, error
  codes and identifiers Blau generates (conversation and utterance UUIDs) are
  `privacy: .public`, so they show up in sysdiagnoses.
- **Never log secrets**, even as private: no xAI API keys, no realtime
  client secrets, no Keychain contents.

The `os` module only accepts log messages built at the call site, so
BlauKit can't wrap `Logger` in its own function or add a custom
`\(transcript:)` interpolation (the compiler rejects extensions of
`OSLogInterpolation`). The rule above is enforced by review.

## Signposts

`Signposts` holds one `OSSignposter` per category, wrapped in a
`Signposter` that adds three helpers:

```swift
// Around synchronous work. Returns the body's value and rethrows its error.
let frame = Signposts.audio.withInterval(.captureFrame) { converter.convert(buffer) }

// Around async work. The interval spans every suspension, and the body runs
// on the caller's actor, so it can use the caller's state.
let result = try await Signposts.asr.withInterval(.asrChunk) { try await asr.process(chunk) }

// Canonical intervals know their category, so this is the same as the line above.
let same = try await Signposts.withInterval(.asrChunk) { try await asr.process(chunk) }

// A point-in-time event.
Signposts.realtime.event("realtime.bargeIn")

// A span that starts and ends in different callbacks.
let firstAudio = Signposts.beginInterval(.realtimeFirstAudio)
// ... when the first response.output_audio.delta arrives:
firstAudio.end()
```

Behaviour you can rely on:

- **Disabled is free and safe.** When nothing is recording (or the
  signposter is `.disabled`), the helpers just run the body. Results and
  errors pass through unchanged.
- **Intervals always end**, including when the body throws or the task is
  cancelled. A manual `SignpostInterval` ends exactly once; later `end()`
  calls do nothing, from any thread.
- **Overlapping intervals pair correctly.** Each interval gets its own
  signpost ID, so two `asr.chunk` intervals on different tasks, or an
  interval that begins on one thread and ends on another, are matched
  properly in Instruments.
- **End messages.** A manual interval can end with a public message that
  Instruments shows next to it: `interval.end(message: event.type)`.
  `realtime.event` uses it for the event type. The message is only built
  when signposting is on. Never pass user content or secrets.
- **Metadata.** The helpers take names only. For an interval that needs a
  begin message (for example a chunk index), use the underlying signposter:
  `OSSignpostBackend(category: .asr).signposter.beginInterval("asr.chunk", id: id, "\(index)")`.
  Keep transcript text out of signpost metadata.

### Testing instrumentation

A component whose instrumentation matters takes a `Signposter` in its
initializer, defaulting to its category's static:

```swift
init(signposter: Signposter = Signposts.asr) { ... }
```

Tests pass `Signposter(category: .asr, backend: RecordingSignpostBackend())`
and check `completedIntervals`, `openIntervals` and `events`. Use
`Signposter.disabled(.asr)` when a test doesn't care.

## Canonical intervals

Use these names for pipeline stages; they are the `PipelineInterval` cases.
The format is `<stage>.<step>`: a lowercase stage, a dot and a lower camel
case step.

| Interval              | Category   | Case                  | Begins                                              | Ends                                            |
| --------------------- | ---------- | --------------------- | --------------------------------------------------- | ----------------------------------------------- |
| `capture.frame`       | `audio`    | `.captureFrame`       | The capture thread takes a hardware buffer off the real-time ring | Its 16 kHz audio is in the hub and fanned out to subscribers |
| `vad.chunk`           | `asr`      | `.vadChunk`           | A chunk is handed to Silero VAD                     | Speech probability and start/end events are out |
| `asr.chunk`           | `asr`      | `.asrChunk`           | A 320 ms chunk is handed to streaming Parakeet      | The partial transcript for that chunk is out    |
| `asr.eou`             | `asr`      | `.asrEndOfUtterance`  | VAD reports end of speech                           | The end-of-utterance decision fires (or speech resumes) |
| `asr.secondPass`      | `asr`      | `.asrSecondPass`      | The second pass starts re-transcribing a committed utterance with Parakeet TDT v3 | The refined text is out (or the pass failed); the end message is the outcome |
| `model.download`      | `asr`      | `.modelDownload`      | `ModelManager` starts downloading a model           | Every file is on disk and checksum-verified (or the download fails, pauses or is cancelled) |
| `model.warmUp`        | `asr`      | `.modelWarmUp`        | `ModelManager` loads an installed model for the first time on this OS | Core ML finished loading (and compiling) every bundle |
| `voiceid.embed`       | `voiceid`  | `.voiceIDEmbed`       | A speech segment is handed to the embedding model   | The 256-d embedding is out                      |
| `voiceid.verify`      | `voiceid`  | `.voiceIDVerify`      | Scoring of a segment against the voiceprint starts  | Accept / reject / uncertain is decided          |
| `realtime.turn`       | `realtime` | `.realtimeTurn`       | A verified utterance's text is committed to Grok    | `response.done`, or the response is cancelled by barge-in |
| `realtime.firstAudio` | `realtime` | `.realtimeFirstAudio` | Same commit as `realtime.turn`                      | The first `response.output_audio.delta` arrives |
| `realtime.connect`    | `realtime` | `.realtimeConnect`    | `RealtimeClient` starts a connection attempt (token, then WebSocket upgrade) | The socket is open, or the attempt failed |
| `realtime.event`      | `realtime` | `.realtimeEvent`      | A frame arrives on the realtime WebSocket            | It is decoded and yielded to `RealtimeClient.events`; the end message is the event type |
| `playback.firstBuffer` | `audio`   | `.playbackFirstBuffer` | The first audio delta of a response item is enqueued in the player | The item's first frame is rendered (the jitter buffer is primed) |
| `topics.segment`      | `topics`   | `.topicsSegment`      | A new exchange is scored for a topic boundary       | The depth score and hysteresis decision are out |
| `topics.label`        | `topics`   | `.topicsLabel`        | A candidate boundary goes to Foundation Models      | The boundary is confirmed or rejected and titled |
| `memory.embed`        | `memory`   | `.memoryEmbed`        | A batch of up to 32 texts is handed to the shared embedding service (#60) | Every text's 256-d int8 vector is out; the end message is the text and token count |
| `memory.search`       | `memory`   | `.memorySearch`       | A memory search starts (BM25 + vector)              | Fused, ranked results are out                   |
| `memory.extract`      | `memory`   | `.memoryExtract`      | Fact extraction starts on a closed topic (#66)      | Its facts and entities are written (or it failed); the end message is the outcome |
| `db.save`             | `data`     | `.dbSave`             | `ModelContext.save()` is called                     | It returns                                      |

### Adding an interval

1. Add a case to `PipelineInterval` with its `name` and `category`.
2. Add a row to the table above (the doc test checks the name and category).
3. Name it `<stage>.<step>` after the stage it measures, not the type that
   emits it, so the name survives refactors.

Ad-hoc names (`Signposts.asr.withInterval("asr.debugThing") { ... }`) are
fine while investigating, but promote anything worth keeping to a canonical
interval.

## Viewing signposts and logs

### Instruments

Use the **Blau** template (see [Instruments template](#instruments-template)
below): it records the signposts together with audio, hangs, memory, the
on-device models, the network and thermal state.

1. Profile the app with **Product > Profile** (a Release build) and pick
   **Blau** under Custom. Without the template, any template plus the
   **os_signpost** instrument shows the intervals too.
2. Record a conversation, then select the os_signpost track and filter by
   subsystem `com.joeblau.blau`. Intervals are grouped by category
   (`audio`, `asr`, ...) and named as in the table above. The summary view
   gives count, min, max and average duration per interval name.

From the command line:

```sh
make trace TRACE_DEVICE=<device name or UDID>
# which runs:
xcrun xctrace record --template Tools/Instruments/Blau.tracetemplate \
    --device <device> --attach Blau --output .build/traces/
```

### Checking the pipeline from the Mac

`scripts/verify-signposts.sh` proves the signpost path end to end without a
device. It records an os_signpost trace on the Mac while the opt-in
`SignpostSmokeTests` suite (`BLAU_SIGNPOST_SMOKE=1`) emits every canonical
interval through the real `OSSignposter`, exports the paired-intervals table
Instruments shows, and fails unless every interval above appears under
`com.joeblau.blau` with its documented category. It also checks that
exactly the intervals in "Intervals reported to MetricKit" below are emitted
with `mxSignpost` (under MetricKit's `com.apple.metrickit.log` subsystem).
Pass `--keep` to keep the trace and open it in Instruments.

### Console and the log command

In Console.app, filter on `subsystem:com.joeblau.blau` and optionally
`category:asr`. Debug messages only appear with **Action > Include Debug
Messages**. From a Mac:

```sh
log stream --level debug --predicate 'subsystem == "com.joeblau.blau"'
log stream --predicate 'subsystem == "com.joeblau.blau" && category == "realtime"'
```

Private values show as `<private>` unless the device has a logging profile
that reveals them; that is intended.

## Instruments template

[`Tools/Instruments/Blau.tracetemplate`](../Tools/Instruments/Blau.tracetemplate)
is a one-click profiling setup for Blau. It has these instruments, in track
order:

| Instrument          | Why                                                                 |
| ------------------- | ------------------------------------------------------------------- |
| os_signpost         | Every canonical interval and event under `com.joeblau.blau`         |
| os_log              | BlauTelemetry's `Log.*` messages, on the same timeline              |
| Points of Interest  | `.pointsOfInterest` signposts from the app and system frameworks    |
| Audio Client        | Audio System Trace: Blau's I/O cycles, IOProc time and cycle load   |
| Audio Server        | Audio System Trace: the audio HAL's I/O cycles and timestamp jitter |
| Audio Statistics    | Audio System Trace: audio statistics alongside the two above        |
| Hangs               | Main run loop iterations of 100 ms or more (potential hangs)        |
| Allocations         | Heap and VM allocations; growth over a long session                 |
| Core ML             | Model loads and predictions (Silero VAD, Parakeet, WeSpeaker)       |
| Neural Engine       | Neural Engine activity, to see whether those models ran on it (#26) |
| Foundation Models   | On-device topic confirmation and titles (#53)                       |
| HTTP Traffic        | The xAI client-secret request and other URLSession traffic          |
| Network Connections | The connections, including the realtime WebSocket                   |
| Thermal State       | Thermal pressure during long sessions (#75)                         |

The os_signpost instrument also turns on dynamic tracing for
`com.joeblau.blau` (its "Dynamic Subsystems" recording option). Signposts
sent to an `OSLog` in that subsystem whose category is `.dynamicTracing`
(or `.dynamicStackTracing`) are disabled by default and only recorded when
a tool enables them, as this template does. That is the place for any
future per-frame signposts that are too frequent to leave on. The canonical
intervals use ordinary categories and are always recorded.

The Audio System Trace template's kernel instruments (thread states,
system calls, virtual memory) are left out: they need deferred kernel
tracing with high overhead and huge traces over an hour-long conversation.
Use Apple's **Audio System Trace** template when you need thread
scheduling around an audio glitch, and add **Time Profiler** from the
library when a hang needs call stacks.

### Using it

1. Install it once so it shows up in Instruments' template chooser (under
   Custom) and in `xcrun xctrace list templates` (under User Templates):

   ```sh
   make install-instruments-template
   ```

   This copies the template to `~/Library/Application Support/Instruments/Templates/`.
   Run it again after the template changes.
2. In Xcode, **Product > Profile** (⌘I) builds Release and opens
   Instruments. Pick **Blau**, press Record and hold a conversation.
3. Or record from the command line with `make trace TRACE_DEVICE=<device>`
   (the app must be running on the device; see `xcrun xctrace list devices`).
   The trace lands in `.build/traces/`.

Allocations has to attach to the app, so profile a build signed for
development (what Xcode's Profile action does). An App Store or TestFlight
build can't be attached to.

### Changing it

The template is a binary NSKeyedArchiver file that only Instruments
writes, so don't edit it by hand:

1. Edit [`Tools/Instruments/instruments.txt`](../Tools/Instruments/instruments.txt)
   (instrument names as `xcrun xctrace list instruments` prints them) or
   [`recording-options.json`](../Tools/Instruments/recording-options.json)
   (options as `xcrun xctrace record --instrument <name> --show-recording-options`
   prints them).
2. `make instruments-template` runs `scripts/make-instruments-template.sh`.
   It records a two-second trace of a stand-in process on the Mac with those
   instruments and options, takes the template xctrace stores inside the
   trace (`form.template`, the same thing **File > Save as Template**
   writes) and strips the recorded run from it.
3. `make verify-instruments` and `make test-scripts`, then commit the three
   files together.

### Checking it from the Mac

`scripts/verify-instruments-template.sh` (`make verify-instruments`) checks
that the template opens and captures every Blau interval, without a device.
It records a trace with the committed template while `SignpostSmokeTests`
emits every canonical interval, then fails unless:

- the run used every instrument in `instruments.txt` with no run errors,
- os_signpost had dynamic tracing on for `com.joeblau.blau`, and
- every interval in the [canonical table](#canonical-intervals) appears
  under `com.joeblau.blau` with its documented category.

There is no Blau process on the Mac, so the script launches a stand-in
target (`scripts/lib/trace-target.c`, signed with `get-task-allow` so
Allocations can attach) and, for that recording only, sets os_signpost's
"record all processes" option so it also sees the `swift test` process that
emits the intervals. Pass `--keep` to keep the trace. The Xcode 27.2 beta's
xctrace sometimes crashes while saving a recording, whatever the template;
the script retries the recording once when that happens.

`scripts/tests/test-instruments-template.sh` (part of `make test-scripts`)
is the quick, hermetic check: the committed template has exactly the listed
instruments and Blau's os_signpost options, carries no recorded run or local
paths, and loads in xctrace.

## Baselines

### Persistence write path (`ConversationStore`, #21)

`ConversationStoreStressTests` (in `Packages/BlauKit`) commits 10,000
utterances through `ConversationStore` into an on-disk SQLite store, with a
topic change every 100 utterances, and prints a `DBSTRESS` line. The timed
span covers every `startConversation`, `openTopic`, `commitUtterance` and
`endConversation` call, including the saves.

The always-on test (10 conversations of 1,000) fails if it uses more than
**15,000 ms of process CPU time** (override with
`BLAU_DB_STRESS_BUDGET_MS`). It checks CPU time, not wall time, because CI
and dev machines run other work in parallel; the budget is about 7x the
debug baseline so it only trips on a real regression (for example a save
per utterance). The worst case and the save-every-change comparison run
with `BLAU_DB_STRESS=1`:

```sh
cd Packages/BlauKit
swift test --filter ConversationStoreStressTests                          # debug, budget check
BLAU_DB_STRESS=1 swift test -c release --filter ConversationStoreStressTests  # all three, optimized
```

Recorded 2026-10-07 on an Apple M3 Max (Mac15,8), macOS 27.2, Xcode 27.2.
The debug 1 x 10,000 run shared the host with heavy parallel builds, so only
its CPU time is meaningful.

| Run                                   | Build   | Utterances | CPU      | Per utterance | Wall     | Saves |
| ------------------------------------- | ------- | ---------- | -------- | ------------- | -------- | ----- |
| 10 conversations x 1,000, coalesced   | release | 10,000     | 1,628 ms | 163 µs        | 1,615 ms | 40    |
| 1 conversation x 10,000, coalesced    | release | 10,000     | 4,054 ms | 405 µs        | 4,068 ms | 22    |
| 1 conversation x 500, save every change | release | 500      | 907 ms   | 1,813 µs      | 951 ms   | 507   |
| 10 conversations x 1,000, coalesced   | debug   | 10,000     | 2,178 ms | 218 µs        | 1,922 ms | 40    |
| 1 conversation x 10,000, coalesced    | debug   | 10,000     | 9,530 ms | 953 µs        | n/a      | 24    |

Coalescing is about 11x cheaper per utterance than saving every change.
The cost per utterance grows with the conversation's size because SwiftData
updates the inverse `Conversation.utterances` relationship on every link
(see docs/data-model.md).

**On device: pending.** The same numbers on an iPhone, and a check with
Instruments' os_signpost track that `db.save` never appears on the main
thread during a live session, need a physical device:

| Run                                 | Device | CPU     | Wall    | Notes |
| ----------------------------------- | ------ | ------- | ------- | ----- |
| 10 x 1,000, coalesced (release)     | iPhone | pending | pending |       |
| 1 x 10,000, coalesced (release)     | iPhone | pending | pending |       |

## MetricKit and diagnostics

MetricKit is how Blau hears about hangs, crashes, memory and launch time from
real use, TestFlight included. Everything lives in `BlauTelemetry`; the app
only starts it and shows it.

| Piece                    | Where                                  | What it does |
| ------------------------ | -------------------------------------- | ------------ |
| `MetricKitSubscriber`    | `BlauTelemetry/Diagnostics`            | `MXMetricManager` subscriber. Stores every `MXMetricPayload` and `MXDiagnosticPayload`, plus `pastPayloads` it missed |
| `FileDiagnosticsStore`   | `BlauTelemetry/Diagnostics`            | Keeps each payload's JSON verbatim with a summary, de-duplicated by SHA-256, and writes the export |
| `DiagnosticsOverview`    | `BlauTelemetry/Diagnostics`            | Rolls stored payloads up into hangs, memory, stability, launch and signposts |
| `MetricKitSignpostBackend` | `BlauTelemetry/Diagnostics`          | Sends the intervals below to MetricKit with `mxSignpost`, as well as to Instruments |
| `AppDiagnostics`, `DiagnosticsView` | `Blau/Diagnostics`          | Starts the subscriber in `BlauApp.init`; the Developer diagnostics screen and share-sheet export |

### What arrives when

- **Metric payloads** (hang time histogram, peak and suspended memory, CPU,
  disk writes, launch and resume time, exit counts, Blau's signposts) arrive
  about once a day, covering the previous day.
- **Diagnostic payloads** (hang, crash, CPU exception, disk-write exception
  and, on iOS, slow-launch reports, each with a call stack) arrive at the
  next launch after the event.
- Only devices deliver payloads, including TestFlight and App Store installs.
  The Simulator never does. With a device attached, Xcode's **Debug >
  Simulate MetricKit Payloads** delivers a test payload immediately.

### Storage and privacy

Payloads are written to `Application Support/Diagnostics/MetricKit` as
`<kind>/<id>.payload.json` (MetricKit's `jsonRepresentation()`, untouched)
and `<kind>/<id>.record.json` (Blau's summary). They are **local only**: not
in SwiftData, not synced through CloudKit, and the folder is excluded from
backups. The store keeps 90 days and at most 120 payloads of each kind.
Payloads describe the app and device (versions, device model, call stacks),
not what the user said; a crash's Objective-C exception message stays in the
raw payload and only leaves the device in an export the user starts.

### Developer diagnostics screen

`DiagnosticsView` summarizes the stored payloads: payload counts and how
many came from TestFlight, hang reports and the longest hang, hangs in the
daily metrics, peak and suspended memory, memory terminations, crashes by
signal or exception, CPU and disk-write exceptions, time to first draw and
the MetricKit signposts below. Open it from **Settings > Developer >
Diagnostics** (the gear on the main screen). It is in every build,
TestFlight included, since that is where real payloads arrive. Debug builds
add **Add Sample Payloads**, which stores made-up payloads
(`DiagnosticsSamples`, marked `"blauSample": true`) so the screen and the
export can be tried in the Simulator.

**Export Diagnostics** opens the share sheet with one JSON file,
`Blau-Diagnostics-<yyyyMMdd-HHmmss>.json` (UTC):

```json
{
  "format": "com.joeblau.blau.diagnostics.v1",
  "exportedAt": "2026-10-07T12:00:00Z",
  "context": { "appVersion": "0.1.0", "appBuild": "1", "bundleIdentifier": "com.joeblau.blau",
               "osVersion": "Version 26.1 (Build 23B85)", "deviceModel": "iPhone17,1" },
  "overview": { "metricPayloadCount": 12, "hangReportCount": 2, "peakMemoryBytes": 312000000, "...": "..." },
  "payloads": [
    { "id": "…", "kind": "metrics", "receivedAt": "…", "summary": { "...": "..." },
      "payload": { "…": "MetricKit's JSON, as delivered" } }
  ]
}
```

Payloads are oldest first. `jq '.payloads[] | select(.kind == "diagnostics") | .payload'`
pulls out the raw diagnostic payloads, call stacks included.

### Intervals reported to MetricKit

MetricKit only aggregates intervals emitted with `mxSignpost` on a log
handle from `MXMetricManager.makeLogHandle(category:)`, and it keeps a
limited number of them, each with a resource snapshot. So only these
canonical intervals (`PipelineInterval.reportsToMetricKit`) go to MetricKit,
under their usual category; everything else stays Instruments-only. They
show up in `MXMetricPayload.signpostMetrics` with a count, a duration
histogram, CPU time, memory and disk writes. A unit test keeps this table
and the code in sync.

| Interval              | Category   | Why it's reported                                   |
| --------------------- | ---------- | --------------------------------------------------- |
| `asr.eou`             | `asr`      | End-of-utterance delay, part of every turn's latency |
| `voiceid.verify`      | `voiceid`  | Gate decision time, once per speech segment         |
| `realtime.turn`       | `realtime` | Full turn duration                                  |
| `realtime.firstAudio` | `realtime` | The latency the user hears                          |
| `topics.label`        | `topics`   | On-device Foundation Models call, rare but slow     |
| `memory.search`       | `memory`   | Retrieval time behind `search_memory`               |

Per-chunk and per-frame intervals (`capture.frame`, `vad.chunk`,
`asr.chunk`, `realtime.event`) and the frequent `voiceid.embed`,
`topics.segment`, `memory.embed` and `db.save` stay out: they would swamp
MetricKit's signpost budget. `playback.firstBuffer` also stays out: it
starts where `realtime.firstAudio` ends and only times local jitter-buffer
priming, so the `audio` category stays Instruments-only. `realtime.connect`
runs once per session, before any turn, and stays Instruments-only for now.
`asr.secondPass` runs once per utterance off the turn's critical path (it
never delays a turn), so it stays Instruments-only too; compare
`realtime.firstAudio` with the second pass on and off instead (docs/asr.md).
`memory.extract` runs once per closed topic in the background and is
dominated by the xAI request, so it stays Instruments-only as well.
End messages (`realtime.event`'s event type) only reach Instruments:
`mxSignpost` intervals carry none. Use the shared
`Signposts` statics (or `Signposts.defaultBackend(for:)`) to get both;
a `Signposter(category:)` built by hand only emits `os_signpost`.

### iOS 27 `MetricManager`

iOS 27 adds a Swift `MetricManager` with `Codable` `MetricReport` and
`DiagnosticReport` async sequences and marks `MXMetricManager` "to be
deprecated". Blau targets iOS 26, so it uses `MXMetricManager`, which still
works on iOS 27 and builds without warnings. Moving to `MetricManager`
behind `#available(iOS 27, *)` only needs a second adapter that fills the
same `MetricPayloadSummary` / `DiagnosticPayloadSummary`.

### Verifying on a device

The Mac tests cover storage, retention, summaries, the export format and
which intervals reach MetricKit. Delivery itself needs a device:

1. Install a TestFlight build (or run on a device from Xcode) and use the app.
2. In Xcode, **Debug > Simulate MetricKit Payloads**, or wait a day for a
   real payload.
3. Open **Settings > Developer > Diagnostics**: the payload counts go up
   and "From TestFlight" counts TestFlight payloads.
4. Export Diagnostics, save to Files or AirDrop to a Mac, and check the file
   with `jq .overview`.

| Check                                              | Result  |
| -------------------------------------------------- | ------- |
| Simulated payload stored and shown (device, Xcode) | Pending |
| Real metric payload on a TestFlight build          | Pending |
| Real diagnostic payload (hang) on a TestFlight build | Pending |
| `realtime.firstAudio` in `signpostMetrics`         | Pending (needs a device and xAI credentials) |
| Export opens in Files / AirDrop on device          | Pending |

## Thermal and power adaptation

An hour-long conversation must not cook the phone or drain the battery
(#75). `PerformancePolicy` (BlauTelemetry) watches the device and publishes
a `PerformanceLevel`; every stage of the pipeline reads it and sheds work
when it drops.

### Levels

The policy reads `ProcessInfo.thermalState`, `ProcessInfo.isLowPowerModeEnabled`
and, on iOS, `UIDevice.batteryLevel` and `batteryState`
(`SystemDeviceConditionsSource`, updated on their change notifications).
The strictest condition wins (`PerformancePolicyConfiguration`):

| Condition | Level |
| --- | --- |
| Thermal state `nominal` or `fair`, Low Power Mode off, battery fine or charging | `normal` |
| Thermal state `serious` | `reduced` |
| Low Power Mode on | `reduced` |
| On battery at 20% or less (held until 25%, or plugged in) | `reduced` |
| Thermal state `critical` | `minimal` |
| On battery at 10% or less (held until 15%, or plugged in) | `minimal` |

**Hysteresis.** A worse level applies on the reading that calls for it. A
better one waits until conditions have allowed it for `recoveryDelay`
(60 s), then relaxes one level; the next level waits another 60 s. The
policy runs a timer for the delay, so recovery happens even when no new
notification arrives. A device hovering at the `serious` boundary keeps
`reduced` instead of flipping the pipeline every few seconds. The battery
margins (held until 25% or 15%) apply only to a level the battery itself
called for: a device degraded for heat or Low Power Mode at 22% returns to
`normal` once it cools, because the charge never crossed 20%. The
decision logic is the value type `PerformanceLevelTracker`, tested on the
Mac with explicit times.

### What each level changes

| Stage | `normal` | `reduced` | `minimal` | Where |
| --- | --- | --- | --- | --- |
| Streaming ASR | Parakeet, 320 ms chunks | Parakeet, 1280 ms chunks (about a quarter of the model calls; partials slower, end of utterance unchanged) | Apple's `SpeechTranscriber` where the stage offers it, else 1280 ms | `PerformanceASRChunkSizePolicy`, `ParakeetEouRecognizer.provider(modelManager:)`, `BackgroundInferenceMonitor.setPerformanceLevel` ([asr.md](asr.md#chunk-size-and-the-thermal-and-power-policy), [background.md](background.md)) |
| Second pass (Parakeet TDT v3) | On | Off (`SecondPassSkipReason.reducedPerformance`) | Off | `SecondPassTranscriber(performance:)` |
| Topic LLM | Confirms every candidate, titles topics | Confirms strong candidates only (score ≥ 1.5× threshold), titles topics | Titles topics only | `TopicLabelingService(performance:)`, `TopicLabelingPolicy` ([topics.md](topics.md#thermal-policy)) |
| Memory indexing | Immediate | Deferred: up to 5 min, or until `normal` | Suspended until the level improves | `IndexingGate` (BlauMemory), for the incremental indexer (#63) |
| UI | Nothing | A small "Cooling down", "Saving battery" or "Low Power Mode" capsule at the top of the main screen | Same | `PerformanceIndicator` (app) |

Stages switch only where it is safe: ASR between utterances (a
recognizer's state can't change chunk size mid-utterance), the second pass
and topic confirmation per utterance or candidate, model backends through
the inference monitor's load-then-swap. The thermal checks that existed
before (#29, #30, #53: the second pass off and topic confirmation skipped
at `serious`) stay; the stricter of the two applies.

The 1280 ms export is an optional 225 MB model
(`ModelID.parakeetRealtimeEOU1280`, [models.md](models.md)). Without it
ASR stays at 320 ms and only the other stages back off. Apple's
`SpeechTranscriber` arrives with #31; until a stage offers `systemSpeech`,
`minimal` keeps ASR on 1280 ms Parakeet.

### Wiring

`AppEnvironment` owns one policy: the device's readings in the live app,
fixed nominal readings in previews and tests. `start()` starts it, feeds
its levels to the background inference monitor
(`backgroundInference.follow(performance.performanceLevels())`) and to the
views (`PerformanceStatus`).

The live streaming ASR follows it today: `AppEnvironment` hands
`performance` to the `VoiceLoop` (#36), and `LiveVoicePipeline.start`
builds the transcriber with it on every conversation:

```swift
let transcriber = try await ParakeetStreamingTranscriber.load(
    modelDirectory: asrDirectory, audio: hub, voiceActivity: vad,
    chunkSizePolicy: PerformanceASRChunkSizePolicy(performance),
    recognizerProvider: ParakeetEouRecognizer.provider(modelManager: models))
```

`BlauTests/PerformanceIndicatorTests.swift` checks that both the fake and
the live environment pass their policy through. The second pass, the
topic pipeline and the indexer aren't composed in the app yet (the
`transcriber`, `topics` and `memory` slots of `AppEnvironment.live()` are
still `UnavailableService`, and the voice loop runs the streaming
transcriber without a second pass); the issues that compose them pass
`environment.performance` where the table above says:

```swift
let transcriber = SecondPassTranscriber(
    wrapping: streaming, audio: hub, recognizer: ParakeetTdtRecognizer.provider(modelManager: models),
    flags: environment.flags, performance: environment.performance)
let labeling = TopicLabelingService.standard(textGenerator: xai, performance: environment.performance)
let gate = IndexingGate(performance: environment.performance)   // await gate.waitUntilAllowed() per batch
```

The indicator sits in a top safe-area inset of the main screen
(`MainScreenScaffold`), so the conversation scrolls under it. The
performance HUD's Device section shows the same level and its strictest
reason ("Perf level").

The debug menu's **Thermal and power** section shows the readings, the
level and why, and overrides the level (Automatic, Normal, Reduced,
Minimal), which is how to see each level on a cool, plugged-in device or in
the simulator (which always reads `nominal` and reports no battery). UI
tests launch with `-BlauPerformanceLevel reduced`.

### Telemetry

- `Log.performance` (category `perf`) logs every level change with its
  reasons and the readings, e.g. `Performance level normal -> reduced
  (thermal state serious; thermal serious, Low Power Mode false, battery
  64% unplugged)`.
- Each stretch below `normal` is a **`perf.degraded`** interval on
  `Signposts.performance`; its end message is the worst level reached. Every
  change is a **`perf.levelChange`** event. In the Blau Instruments template
  they line up with the Thermal State track.
- `PerformancePolicy.statistics` (`PerformanceStatistics`) keeps time at
  each level and thermal state, the worst of each, level changes, time in
  Low Power Mode and on battery, and battery drain per hour. The long-session
  soak report (#26, the debug menu's **Long session soak test**) records
  them for the run and fails if the device spent more than 10 s at `serious`
  or hotter while the pipeline still ran at `normal`.

### Tests

| Where | What |
| --- | --- |
| `BlauTelemetryTests/Performance/PerformanceLevelTrackerTests.swift` | The decision table (thermal, Low Power Mode, battery on and off charge, hysteresis margins, strictest cause first), the battery margins held only by the battery's own level (not heat or Low Power Mode), immediate escalation, the recovery delay, one level at a time, flapping, overrides |
| `BlauTelemetryTests/Performance/PerformancePolicyTests.swift` | Following a source, snapshot and level streams, the recovery timer on a `ManualClock`, `perf.degraded` and `perf.levelChange` signposts, statistics, the system source on the Mac |
| `BlauTelemetryTests/Performance/PerformanceStatisticsTests.swift` | Time per level and thermal state, heat at `normal`, battery drain, transitions, JSON |
| `BlauTranscriptionTests/ASR/ParakeetStreamingTranscriberTests.swift` | The chunk size following the level both ways, between utterances |
| `BlauTranscriptionTests/SecondPass/SecondPassTranscriberTests.swift` | The second pass skipped below `normal`, resumed at `normal`, and skipped for a waiting utterance when the level drops |
| `BlauTranscriptionTests/Background/PerformanceLevelInferenceTests.swift` | `minimal` moving ASR to `SpeechTranscriber` through the monitor |
| `BlauTranscriptionTests/Models/ModelManifestTests.swift` | The 1280 ms export pinned from the same revision as the 320 ms one |
| `BlauTopicsTests/Labeling/TopicPerformanceLevelTests.swift` | Level modes, strong candidates, the pipeline sending exactly the strong candidates at `reduced` and none at `minimal` |
| `BlauMemoryTests/IndexingGateTests.swift` | Immediate, deferred and suspended indexing on a `ManualClock` |
| `BlauTests/PerformanceIndicatorTests.swift`, `BlauUITests/PerformanceIndicatorUITests.swift` | The indicator's text per cause, the status following the policy, the environment feeding the monitor and passing its policy to the voice loop's ASR; the capsule hidden at `normal`, shown with `-BlauPerformanceLevel reduced` and after a debug-menu override |

### Verifying on a device

The acceptance criterion is a **1-hour soak on an A17 iPhone (iPhone 15 Pro)
that stays at or below `fair` at the `normal` level, or degrades
gracefully**. It needs the hardware:

1. Install a Debug build on the iPhone, unplugged, Low Power Mode off, at
   room temperature, with every model installed (including the optional
   1280 ms export).
2. Debug menu → **Long session soak test** → Start, talk now and then for
   60+ minutes (screen locked most of the time), unlock, Stop and share the
   JSON report.
3. Record Instruments with the Blau template alongside (`make trace`) to see
   `perf.degraded` against the Thermal State track.
4. Pass: the report's verdict passes (no time hot at `normal`), and either
   `performance.worstThermalState` is `fair` or better, or every period at
   `serious` shows a `perf.degraded` interval with 1280 ms chunks, no
   `asr.secondPass` intervals and a return to `normal` after cooling.

| Check | Device | Result |
| --- | --- | --- |
| 1 h soak at `normal`: worst thermal state, time at or below `fair` | iPhone 15 Pro (A17 Pro) | Pending |
| Degrades on `serious`, recovers about 60 s after `fair` | iPhone 15 Pro (A17 Pro) | Pending |
| Battery drain per hour on battery | iPhone 15 Pro (A17 Pro) | Pending |
| Low Power Mode → `reduced`, the indicator shows "Low Power Mode" | Any iPhone | Pending |
| Battery 20% and 10% thresholds on discharge | Any iPhone | Pending |
| 1280 ms export downloads, loads and transcribes (`BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=parakeetRealtimeEOU1280`) | Mac or iPhone | Pending |

## Model benchmarks

The on-device model benchmark harness (#22) measures each model's latency,
real-time factor and memory, and probes background Neural Engine behaviour.
It emits the canonical intervals above around every measured step. Running
it and the results are in [docs/benchmarks.md](benchmarks.md).

## Performance HUD

The debug performance HUD (#71) is a small translucent panel over the app
that shows pipeline health during a real conversation. It is in every build,
TestFlight included.

| Turn it on                          | How                                                          |
| ----------------------------------- | ------------------------------------------------------------ |
| Settings → Developer → Performance HUD | The switch; remembered across launches                    |
| Triple-tap the main screen          | DEBUG builds; shows or hides it                              |
| The `perfHUD` feature flag          | Debug menu, or `-blau.featureFlag.perfHUD YES` for one launch |

Tap the panel to switch between the compact rows and every section; drag it
anywhere. It remembers both. Turning it off from Settings or the triple-tap
also clears a `perfHUD` flag override. Values that deserve attention turn
orange (warning) or red (critical), and so does the panel's border.

### What it shows

| Row              | Source                                                                 | Compact |
| ---------------- | ---------------------------------------------------------------------- | ------- |
| FPS              | `CADisplayLink` callbacks per second on the main thread, the link's target rate and refreshes missed, over one second in every three (see Overhead) | yes |
| CPU              | Process CPU time over wall time since the previous sample (`CLOCK_PROCESS_CPUTIME_ID`); 100% is one core | yes |
| Memory           | Physical footprint (`task_vm_info.phys_footprint`, what jetsam and Instruments use) and `os_proc_available_memory()` | yes |
| Thermal          | `ProcessInfo.thermalState`                                             | yes |
| Perf level       | The thermal and power policy's level, its strictest reason and whether it is recovering (`PerformancePolicy.snapshot`, #75) | |
| HUD cost         | The HUD's own CPU time (sampling, display-link callbacks) as a share of one core over the last 10 s | |
| Capture          | `CaptureHub.statistics`: hardware buffers dropped, subscriber drops, conversion failures | |
| VAD              | Speech or silence, Silero's model time per second of audio, chunks skipped as quiet | |
| ASR chunk        | `asr.chunk` last / p50 / p95 (or the transcriber's mean and slowest chunk before any is timed) | |
| EOU decision     | `asr.eou` last / p50 / p95                                             | |
| Voice score      | The gate's latest score and threshold (`PerformanceGauges`, reported by the verification gate, #47) | |
| Turn, Realtime   | The turn orchestrator's state and the WebSocket connection             | |
| Session          | The realtime session's continuity: phase, age, renewals, resumptions and reseeds (#39) | |
| EOU → audio      | End of utterance → first audio, last / p50 / p95 over the last 200 turns (the `realtime.firstAudio` span) | p50 / p95 |
| Turn time        | End of utterance → `response.done` (the `realtime.turn` span)           | |
| Tokens, Cost     | `response.done` usage; the cost estimate is reply audio minutes × $0.08 plus text inputs × $0.004 (`RealtimePricing.grokVoice`) | |
| Barge-in         | Barge-ins this conversation, and the last one's onset → playback flushed and VAD delay (#37) | |
| Topic depth      | The segmenter's depth score at the newest gap and its threshold (`PerformanceGauges`) | |
| Signposts        | Every canonical interval timed while the HUD shows: last / p50 / p95 and count | |

Rows whose stage isn't running, or isn't built yet, show "–". The voice
score row fills in once the verification gate (#47) reports to
`PerformanceGauges.shared`; the gate should call
`report(.voiceScore, score)` and `report(.voiceThreshold, threshold)` for
every decision.

### How it measures

- **Signposts.** The shared `Signposts` statics go through a
  `TappedSignpostBackend`, which, while `SignpostLatencyTap.shared` is
  active, times every canonical interval next to its `os_signpost` begin
  and end and adds it to a 200-sample window. The HUD therefore reports the
  very spans Instruments shows; no stage has to know about the HUD.
- **Gauges.** Values the HUD can't reach through the composition root (the
  voice ID score, the topic depth score) are published to
  `PerformanceGauges.shared`: one short lock per report, no allocation.
- **Pipeline.** `VoiceLoop.hudReadings()` reads the capture hub's, VAD's
  and transcriber's lock-protected counters and the orchestrator's latest
  `TurnSnapshot`.
- **Sampling.** `PerformanceHUDSampler` reads everything once a second
  (`defaultInterval`), on the main actor, and builds the
  `PerformanceHUDReadout` the panel renders. All of it lives in
  `BlauTelemetry` and `BlauRealtime`, tested on the Mac; the app adds the
  display link, the panel and the controller (`Blau/PerformanceHUD`).

### Overhead

The budget is **under 1% of one core**. Nothing runs while the HUD is hidden:
the tap is off (one relaxed atomic load per interval), there is no display
link and no sampling timer, and the overlay's task only runs while the app is
active. While it shows:

| Piece                            | Cost                                  | Checked by |
| -------------------------------- | ------------------------------------- | ---------- |
| Sampling and building the readout, 1 Hz | ~500 µs per sample in a debug build with all 19 intervals full (~0.05% of a core) | `PerformanceHUDSamplerTests.realSamplingCostsWellUnderOnePercentOfACore` (fails above 0.5%) |
| Signpost tap                     | ~0.6 µs per interval in a debug build; 0.015% of a core at 250 intervals/s | `tappingIntervalsCostsWellUnderOnePercentOfACore` (fails above 0.1%) |
| Display link (60 Hz, one second in three) and SwiftUI updates of the panel | measured with the rest, end to end | `PerformanceHUDOverheadTests` (BlauPerfTests) |

Every display-link callback wakes the main run loop, and that wake-up, not
the callback's own arithmetic, is most of the HUD's cost: about 0.1 ms per
frame in the Simulator, so a link running all the time costs about 0.8% of
a core on its own. The HUD therefore measures the frame rate for one second
in every three (`frameRateDutyCycle`) and keeps the last reading on screen
in between; a hitch while the link sleeps doesn't show in the FPS row (it
does show in Instruments' Hangs and in MetricKit).

The "HUD cost" row shows the sampler's and the display link's CPU time live.
`PerformanceHUDOverheadTests` (`make perf`) measures the whole app's CPU time
over 10 s idle spans with the HUD hidden and shown (`XCTCPUMetric`, three
iterations each). The difference between the two "CPU Time" averages over
10 s is the HUD's share of a core. It includes the SwiftUI updates of the
panel, which the "HUD cost" row doesn't; the render server's compositing is
outside the app either way. XCTest reports metric values only to the log and
the result bundle, so read them there:

```sh
make perf DESTINATION='id=<udid>' 2>&1 | grep "IdleCPUWithTheHUD.*measured \[CPU Time"
```

Read the per-iteration `values`, not only the average: the first one or two
iterations after a launch can still carry launch work (fixture model checks,
store setup) in either phase. Recorded 2026-10-08 in the iOS 26.5 Simulator
(iPhone 17, Release build) on an Apple M3 Max shared with other builds:

| Phase      | CPU time per 10 s idle span, five iterations     | Steady state |
| ---------- | ------------------------------------------------ | ------------ |
| HUD hidden | 0.240, 0.137, 0.000, 0.000, 0.000 s              | 0.000 s      |
| HUD shown  | 0.389, 0.032, 0.040, 0.035, 0.039 s              | 0.032–0.040 s |

So the HUD costs **0.3–0.4% of one core** in the Simulator, everything in
the app process included. Before the display link was duty-cycled it cost
0.9% (0.089–0.095 s per 10 s, with 2 Hz sampling), almost all of it
main-thread wake-ups.

### Checking it against Instruments

`scripts/verify-hud.sh` (`make verify-hud`) starts the opt-in
`PerformanceHUDInstrumentsComparison` suite (`BLAU_HUD_COMPARE=1`), attaches
the os_signpost and Activity Monitor instruments to its process, and lets it
run a known workload with the HUD's sampler and tap active: 450 intervals of
nine canonical names with lengths from 0.2 to 60 ms (on the calling thread,
across suspensions, ended on another task, and overlapping), then 20 s of
steady CPU load with 96 MB of extra memory. `scripts/lib/hud_compare.py`
then checks:

- **Signposts.** Per interval, the HUD's count equals Instruments', at least
  85% of the instances (paired in the order they ended) have the same
  duration within 0.05 ms or 1%. The HUD reads its
  clock right before each `os_signpost` begin and end, so an instance only
  disagrees when its thread was preempted between the two clock reads.
- **CPU.** The HUD's clock is read inside `hud.compare.sample` intervals, so
  its CPU time sits on the trace's timeline next to Activity Monitor's "CPU
  Time" for the same process. Over the load the two CPU percentages must be
  within 2 points or 15%. Activity Monitor's samples land up to about a
  second after the CPU time they report, so shorter windows are printed for
  information only.
- **Memory.** The HUD's footprint is within 3% (or 4 MB) of Activity
  Monitor's "Memory".

Pass `--keep` to keep the trace. Recorded 2026-10-08 on an Apple M3 Max,
macOS 27.2, Xcode 27.2:

| Interval               | Count HUD / Instruments | p50 ms HUD / Instruments | p95 ms HUD / Instruments | Same duration (±0.05 ms or 1%) | Worst pair |
| ---------------------- | ----------------------- | ------------------------ | ------------------------ | ------------------------------ | ---------- |
| `asr.chunk`            | 50 / 50                 | 13.561 / 13.561          | 24.590 / 24.591          | 50 of 50                       | 0.02 ms    |
| `capture.frame`        | 50 / 50                 | 1.033 / 1.033            | 2.199 / 2.202            | 50 of 50                       | 0.04 ms    |
| `db.save`              | 50 / 50                 | 5.641 / 5.645            | 9.780 / 9.786            | 50 of 50                       | 0.01 ms    |
| `playback.firstBuffer` | 50 / 50                 | 5.594 / 5.596            | 10.543 / 10.549          | 50 of 50                       | 0.01 ms    |
| `realtime.firstAudio`  | 50 / 50                 | 23.956 / 23.959          | 40.384 / 40.390          | 50 of 50                       | 0.03 ms    |
| `realtime.turn`        | 50 / 50                 | 42.051 / 42.061          | 59.284 / 59.289          | 50 of 50                       | 0.01 ms    |
| `topics.segment`       | 50 / 50                 | 2.260 / 2.259            | 4.417 / 4.418            | 50 of 50                       | 0.02 ms    |
| `vad.chunk`            | 50 / 50                 | 1.958 / 1.957            | 3.411 / 3.416            | 50 of 50                       | 0.01 ms    |
| `voiceid.verify`       | 50 / 50                 | 8.256 / 8.259            | 14.065 / 14.070          | 50 of 50                       | 0.01 ms    |

| Value                     | HUD      | Instruments (Activity Monitor) |
| ------------------------- | -------- | ------------------------------ |
| CPU over the 20 s load    | 50.3%    | 50.3% (17 samples)             |
| Memory footprint          | 104.4 MB | 104.4 MB                       |

Earlier runs on the same Mac while dozens of other builds and test runs
saturated it (the workload thread got 9–15% of a core) matched every
count and the footprint, but the CPU over an 8 s load differed by up to 2.3
points (Activity Monitor had only three samples in it), and 4–12% of the
instances per interval differed by up to 47 ms: the time their
thread waited between the HUD's clock read and the `os_signpost` record. The
others agreed to within 0.05 ms.

**On device: pending.** The same comparison on an iPhone needs the app
running there:

| Check | How | Result |
| ----- | --- | ------ |
| HUD overhead < 1% CPU | `make perf DESTINATION='id=<udid>'` (`PerformanceHUDOverheadTests`), plus the "HUD cost" row during a 10-minute conversation | pending (needs a device) |
| FPS matches Instruments | Record **Core Animation FPS** (or the Blau template plus Hangs) while scrolling the transcript; compare with the FPS row | pending (needs a device) |
| CPU and memory match | Record the Blau template with **Activity Monitor** added; compare its "% CPU" and "Memory" for Blau with the CPU and Memory rows | pending (needs a device) |
| Latencies match | Record the Blau template during 20 turns; compare the os_signpost summary's average for `asr.chunk`, `realtime.firstAudio` and `realtime.turn` with the HUD's Signposts section | pending (needs a device and xAI credentials) |
| Thermal state | Run a long session until **Thermal State** reports *fair* or *serious*; the Thermal row should change at the same moment | pending (needs a device) |

## What comes next

The rest of the performance epic (#11) builds on these names: the XCTest
performance suite with `XCTOSSignpostMetric` baselines (#73), the end-to-end
latency budget (#74) and the soak test (#76). Thermal and power adaptation
(#75) is described above, and the performance HUD above shows the same
intervals live.
