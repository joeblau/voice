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
- **Metadata.** The helpers take names only. For an interval that needs a
  message (for example a chunk index), use the underlying signposter:
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
| `capture.frame`       | `audio`    | `.captureFrame`       | A capture tap callback receives a hardware buffer   | The 16 kHz mono frame is in the ring buffer and fanned out |
| `vad.chunk`           | `asr`      | `.vadChunk`           | A chunk is handed to Silero VAD                     | Speech probability and start/end events are out |
| `asr.chunk`           | `asr`      | `.asrChunk`           | A 320 ms chunk is handed to streaming Parakeet      | The partial transcript for that chunk is out    |
| `asr.eou`             | `asr`      | `.asrEndOfUtterance`  | VAD reports end of speech                           | The end-of-utterance decision fires (or speech resumes) |
| `voiceid.embed`       | `voiceid`  | `.voiceIDEmbed`       | A speech segment is handed to the embedding model   | The 256-d embedding is out                      |
| `voiceid.verify`      | `voiceid`  | `.voiceIDVerify`      | Scoring of a segment against the voiceprint starts  | Accept / reject / uncertain is decided          |
| `realtime.turn`       | `realtime` | `.realtimeTurn`       | A verified utterance's text is committed to Grok    | `response.done`, or the response is cancelled by barge-in |
| `realtime.firstAudio` | `realtime` | `.realtimeFirstAudio` | Same commit as `realtime.turn`                      | The first `response.output_audio.delta` arrives |
| `topics.segment`      | `topics`   | `.topicsSegment`      | A new exchange is scored for a topic boundary       | The depth score and hysteresis decision are out |
| `topics.label`        | `topics`   | `.topicsLabel`        | A candidate boundary goes to Foundation Models      | The boundary is confirmed or rejected and titled |
| `memory.embed`        | `memory`   | `.memoryEmbed`        | Text is handed to the embedding model               | The int8 vector is out                          |
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

1. Profile the app with **Product > Profile** (a Release build) and pick the
   **Logging** template, or any template plus the **os_signpost**
   instrument.
2. Record a conversation, then select the os_signpost track and filter by
   subsystem `com.joeblau.blau`. Intervals are grouped by category
   (`audio`, `asr`, ...) and named as in the table above. The summary view
   gives count, min, max and average duration per interval name.

From the command line:

```sh
xcrun xctrace record --template Logging --device <device> --attach Blau --output blau.trace
open blau.trace
```

### Checking the pipeline from the Mac

`scripts/verify-signposts.sh` proves the signpost path end to end without a
device. It records an os_signpost trace on the Mac while the opt-in
`SignpostSmokeTests` suite (`BLAU_SIGNPOST_SMOKE=1`) emits every canonical
interval through the real `OSSignposter`, exports the paired-intervals table
Instruments shows, and fails unless every interval above appears under
`com.joeblau.blau` with its documented category. Pass `--keep` to keep the
trace and open it in Instruments.

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

## What comes next

The rest of the performance epic (#11) builds on these names: MetricKit and
diagnostics export (#72), the XCTest performance suite with
`XCTOSSignpostMetric` baselines (#73), the end-to-end latency budget (#74),
thermal adaptation (#75), the soak test (#76), the debug HUD (#71) and a
custom Instruments template (#77).
