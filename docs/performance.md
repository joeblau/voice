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
| `realtime.firstAudio` in `signpostMetrics`         | Pending (needs #36) |
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
`reduced` instead of flipping the pipeline every few seconds. The
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
views (`PerformanceStatus`). The live transcriber, topic pipeline and
indexer are still `UnavailableService` in `AppEnvironment.live()`; the issues
that compose them pass `environment.performance` where the table above
says:

```swift
let streaming = ParakeetStreamingTranscriber(
    recognizer: recognizer, audio: hub, voiceActivity: vad,
    chunkSizePolicy: PerformanceASRChunkSizePolicy(environment.performance),
    recognizerProvider: ParakeetEouRecognizer.provider(modelManager: environment.speechModels))
let transcriber = SecondPassTranscriber(
    wrapping: streaming, audio: hub, recognizer: ParakeetTdtRecognizer.provider(modelManager: models),
    flags: environment.flags, performance: environment.performance)
let labeling = TopicLabelingService.standard(textGenerator: xai, performance: environment.performance)
let gate = IndexingGate(performance: environment.performance)   // await gate.waitUntilAllowed() per batch
```

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
| `BlauTelemetryTests/Performance/PerformanceLevelTrackerTests.swift` | The decision table (thermal, Low Power Mode, battery on and off charge, hysteresis margins, strictest cause first), immediate escalation, the recovery delay, one level at a time, flapping, overrides |
| `BlauTelemetryTests/Performance/PerformancePolicyTests.swift` | Following a source, snapshot and level streams, the recovery timer on a `ManualClock`, `perf.degraded` and `perf.levelChange` signposts, statistics, the system source on the Mac |
| `BlauTelemetryTests/Performance/PerformanceStatisticsTests.swift` | Time per level and thermal state, heat at `normal`, battery drain, transitions, JSON |
| `BlauTranscriptionTests/ASR/ParakeetStreamingTranscriberTests.swift` | The chunk size following the level both ways, between utterances |
| `BlauTranscriptionTests/SecondPass/SecondPassTranscriberTests.swift` | The second pass skipped below `normal`, resumed at `normal`, and skipped for a waiting utterance when the level drops |
| `BlauTranscriptionTests/Background/PerformanceLevelInferenceTests.swift` | `minimal` moving ASR to `SpeechTranscriber` through the monitor |
| `BlauTranscriptionTests/Models/ModelManifestTests.swift` | The 1280 ms export pinned from the same revision as the 320 ms one |
| `BlauTopicsTests/Labeling/TopicPerformanceLevelTests.swift` | Level modes, strong candidates, the pipeline sending exactly the strong candidates at `reduced` and none at `minimal` |
| `BlauMemoryTests/IndexingGateTests.swift` | Immediate, deferred and suspended indexing on a `ManualClock` |
| `BlauTests/PerformanceIndicatorTests.swift`, `BlauUITests/PerformanceIndicatorUITests.swift` | The indicator's text per cause, the status following the policy, the environment feeding the monitor; the capsule hidden at `normal`, shown with `-BlauPerformanceLevel reduced` and after a debug-menu override |

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

## What comes next

The rest of the performance epic (#11) builds on these names: the XCTest
performance suite with `XCTOSSignpostMetric` baselines (#73), the end-to-end
latency budget (#74), the soak test (#76) and the debug HUD (#71). Thermal
and power adaptation (#75) is described above.
