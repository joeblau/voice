# Long-session soak test

Issue #76 (epic #11). Some problems only show up after an hour of talking:
a few bytes leaked per audio frame, a list that grows with every turn, a
recognizer that slows down as its history fills, a realtime session that
doesn't survive xAI's 120-minute limit, a topic segmenter that drifts. The
soak test runs the voice loop's real pipeline for one to two hours of
conversation, samples it as it goes, and fails when any of that happens.

```sh
make soak                                  # 120 min of audio at 10x on the iPhone 17 simulator (~15 min)
make soak SOAK_MINUTES=20                  # the nightly CI length (~3 min plus the build)
make soak DESTINATION='id=<udid>' SOAK_SPEED=realtime SOAK_ASR=parakeet   # the weekly device run
```

Results land in `.build/results/soak/`: `report.json` and `report.md` (the
report artifact), `leaks.jsonl`, `leaks.json`, `leaks.md` and the raw
`leaks/*.txt` readings, `summary.md` (both together, what CI shows),
`soak.xcresult` (with the report attached) and `xcodebuild.log`.

| Piece | Where | What it does |
| ----- | ----- | ------------ |
| `SoakRun` | `Blau/Performance/Soak/SoakRun.swift` | Builds the pipeline, plays the session, samples it, returns a `SoakReport` |
| `SoakConfiguration` | `Blau/Performance/Soak/SoakConfiguration.swift` | Length, speed, recognizer, where the session renewal lands; read from the launch environment |
| `SoakView` | `Blau/Performance/Soak/SoakView.swift` | The screen `BLAU_SOAK=1` opens instead of the app (also Debug menu → **Automated soak**); saves the report to `Documents/Soak` |
| `SoakSample`, `SoakOutcome`, `SoakAnalysis`, `SoakReport` | `BlauTelemetry/Soak` | The samples, the checks and their thresholds, the JSON and Markdown report |
| `ConversationAudioScript.Interlude` | `BlauAudio/Fixtures` | The mixed audio: TV dialogue from another voice and silence between topics |
| `SessionContinuityConfiguration.scaled(by:)` | `BlauRealtime/Continuity` | xAI's session schedule (renew at 110 min, deadline 118, limit 120) scaled to the run |
| `TimedSpeechRecognizer` | `BlauTranscription/ASR` | Times the calls of a recognizer that doesn't time itself, so the scripted recognizer's per-chunk work is measured |
| `SoakTests` | `BlauPerfTests/SoakTests.swift` | The XCTest that launches the app, runs the soak and attaches the report |
| `BlauSoak.xctestplan` | `TestPlans/` | Runs only `SoakTests`, in Release, with `BLAU_SOAK=1` (the `BlauPerf` plan skips it) |
| `soak.sh`, `leaks-report.py` | `scripts/soak/` | `make soak`: runs the test, reads the app's leaks, collects the report and the verdict |

## What runs

The soak is the performance suite's scripted session
([performance.md](performance.md#the-scripted-session), `PerfReplay`) made
long and messier. Everything runs in the app process, on a temporary store
and index; nothing touches the user's data, the network, the Keychain or the
microphone.

| Stage | In the soak | Real or stand-in |
| --- | --- | --- |
| Microphone | `ConversationAudioScript.session(lasting:interlude:)`: the user's lines (speech-shaped synthetic audio, -54 dBFS room noise between them) with an **interlude before every new topic**: 2 s of quiet, 30 s of TV dialogue (bursts of 3 to 8 s from another synthetic voice, about 6 dB below the user), 2 s of quiet, 30 s of silence. About 60% of the session is the conversation, 15% TV, the rest silence and room noise. Played into the real `CaptureHub` by `CaptureReplayFeeder` at `SOAK_SPEED` | Synthetic audio, real capture hub |
| VAD | `VoiceActivitySegmenter`, energy model (Silero with real models) | Real |
| ASR | `ParakeetStreamingTranscriber` on `AlignedTranscriptRecognizer`, wrapped in `TimedSpeechRecognizer` so each call that runs chunks reports its own duration (the aligned recognizer runs no model and reports none); Parakeet itself with `SOAK_ASR=parakeet`, which times its Core ML work | Real transcriber, stand-in model |
| Voice ID | Every VAD segment scored by `VoiceprintScorer.verify`; segments on the TV get another speaker's embedding | Real scoring, synthetic embeddings |
| Grok | `TurnOrchestrator` and `RealtimeClient` against `ScriptedRealtimeServer`, a local fake that answers each line with a canned reply as streamed PCM16 and transcript deltas, and records every connection | Fake server, real client and orchestrator |
| Session renewal | xAI's schedule scaled so the renewal lands 60% into the audio (`SOAK_ROLLOVER_MINUTES`); the orchestrator mints a token, renews between turns, reseeds the new conversation from the stored transcript (`ConversationStore.topicDigest`), as in a real two-hour session ([realtime.md](realtime.md#long-sessions)) | Real |
| Transcript, topics, memory | `ConversationStore` on SwiftData, `StreamingTopicSegmenter`, `MemoryIndex` and `MemorySearch` per exchange | Real |

**Sampling.** Every `SOAK_SAMPLE_SECONDS` of audio (a 120th of the session,
at least 10 s) the run records a `SoakSample`: the process's physical
footprint (`task_vm_info.phys_footprint`, what jetsam counts), the
recognizer's chunk count and time, capture frames delivered and lost,
utterances, replies, topic boundaries, renewals and reseeds, and the mean
time to first reply audio of the turns since the last sample.

**Session clock.** Faster than real time, a two-hour session lasts twelve
minutes of wall time, so xAI's limits are divided by
`sessionTimeScale = speed × 110 min / rolloverAt`. With the defaults (120
minutes at 10x, renewal at 72 audio minutes) the session is renewed after
7.2 minutes of wall time, its deadline is 7.7. `SOAK_ROLLOVER_MINUTES=xai`
keeps xAI's own schedule, divided by the speed only: at `realtime` that is
the real 110 minutes, so a 120-minute device run renews exactly as a user's
session would.

## The checks

`SoakAnalysis` judges the samples after a warm-up (the first 10% of the
audio: caches, the first SQLite pages, the first topic). All eight must
pass, and on a simulator the leak readings must not grow.

| Check | Fails when | Default limit |
| --- | --- | --- |
| `memory.slope` | The footprint climbs: the Theil–Sen slope (median of the slopes between every pair of samples, so a transient spike doesn't move it) in MB per hour of **audio**, so a leak per frame, chunk or turn reads the same at any speed | ≤ 2 MB/h |
| `asr.chunkLatency` | The recognizer's time per chunk in the late third of the run is more than 1.5× the early third and more than 2 ms longer. With the scripted recognizer a chunk takes microseconds, so only work that grows into milliseconds (a history that is never reset, say) trips it; with Parakeet the 1.5× applies | 1.5×, 2 ms floor |
| `realtime.firstAudio` | The same for the time from end of utterance to Grok's first audio | 1.5×, 50 ms floor |
| `capture.droppedFrames` | More than 0.1% of capture frames were lost (dropped buffers plus frames a slow subscriber missed) | ≤ 0.1% |
| `conversation.complete` | A line wasn't transcribed or answered, or a turn ended in the error state | all lines, 0 failed |
| `realtime.rollover` | Fewer renewals than the run's length requires (every session ends by its deadline, so a run lasting `n` deadlines renewed at least `n` times), a renewal without a reseed, or no new connection for it | ≥ expected |
| `voiceid.background` | A TV segment was accepted, a user segment wasn't, or the VAD never heard the TV | all |
| `topics.count` | Topic boundaries below half the script's topic changes, or above 1.5× plus one (flapping) | 0.5× to 1.5× + 1 |

The limits are `SoakThresholds.standard`; the report records the ones it
was judged by. A failing report names the checks (`failed: memory.slope`)
and shows every sample, so the moment something started growing is in the
artifact.

**Leaks.** On a simulator, `scripts/soak/soak.sh` runs macOS's `leaks` (the
same leak detection as Instruments' Leaks instrument, on the simulator
app's process) a little after the app starts, every sixth of the run's
expected wall time, and once more after the run while the app sits idle
(`SoakTests` keeps it open for `SOAK_HOLD_SECONDS`, 90 by default).
`leaks-report.py` fails the soak when the leak count or the leaked bytes
grew between the first reading and the last; it is inconclusive (and fails)
with fewer than two readings. Leaks already there at the first reading
(on the iOS 27.0 simulator, 56 blocks of 32 bytes, 1,792 bytes, the same
in every run so far) don't count; only growth does. The simulator app isn't
debuggable by `leaks` and the soak doesn't turn on malloc stack logging, so
the readings count leaks but don't say where they were allocated: to find
the owner of a new leak, record the soak with Instruments' Leaks template
(below), which keeps the allocation stacks.

## Configuration

`make soak` variables (the test runner gets each as `BLAU_SOAK_*`; set
them with a `TEST_RUNNER_` prefix when calling xcodebuild directly):

| Variable | Default | Meaning |
| --- | --- | --- |
| `SOAK_MINUTES` | 120 | The session's length on the audio timeline |
| `SOAK_SPEED` | 10 | How much faster than real time the audio plays: a factor, `realtime` or `max` |
| `SOAK_ASR` | `scripted` | `parakeet` transcribes with the installed models (a device with them downloaded) |
| `SOAK_ROLLOVER_MINUTES` | 60% of the session | Where on the audio timeline the session renewal lands, or `xai` for xAI's schedule |
| `SOAK_SAMPLE_SECONDS` | session / 120, ≥ 10 | Audio between samples (env only: `TEST_RUNNER_BLAU_SOAK_SAMPLE_SECONDS`) |
| `SOAK_OUTPUT` | `.build/results/soak` | Where the results go |
| `SOAK_LEAKS` | 1 on a simulator | 0 skips the leak readings |
| `SOAK_LEAKS_INTERVAL` | a sixth of the expected wall time, 20 to 300 s | Seconds between leak readings |
| `SOAK_HOLD_SECONDS` | 90 with leaks, else 0 | How long the idle app stays open after the run for the last leak reading |
| `DESTINATION` | the newest iPhone 17 simulator | A simulator by name is resolved to its UDID |

## Where it runs

- **Nightly, simulator, 20 minutes.** The `soak` job in
  [CI](ci.md) runs `make soak SOAK_MINUTES=20` on the runner's iPhone 17
  simulator: 20 minutes of audio at 10x, renewal at 12 audio minutes, leaks
  read every 20 s. The summary page shows the report and the leak table;
  `soak-results-<attempt>` keeps everything for 90 days. **Actions > CI >
  Run workflow** with **Also run the long-session soak test** runs it on
  demand, at any length (`soak_minutes`); the repository variables
  `BLAU_CI_SOAK_MINUTES` and `BLAU_CI_SOAK_LEAKS` change the nightly run.
- **Weekly, device, two hours at real time.** There is no self-hosted runner
  with an iPhone yet, so the weekly run is manual (below); a self-hosted
  runner with a device attached would run the same `make soak` line.
- **By hand, on a simulator or a Mac.** `make soak` (two hours of audio in
  about fifteen minutes).

### The weekly device run

On an iPhone with the speech models downloaded (open Blau once and finish
onboarding), a development-signed build, plugged in and on a desk:

1. `make soak DESTINATION='id=<udid>' SOAK_SPEED=realtime SOAK_ASR=parakeet SOAK_ROLLOVER_MINUTES=xai`
   (`xcrun devicectl list devices` for the UDID). Two hours; the session
   renews at 110 minutes as a real one would. Keep the device awake (the
   test runner does) and on power.
2. For leaks: Instruments → **Leaks** template → attach to **Blau** on the
   device once the soak screen shows `running`, and keep it recording
   (`xcrun xctrace record --template Leaks --device <udid> --attach Blau
   --output .build/traces/soak-leaks.trace` does the same from the
   terminal). The leak count must not grow after the first few minutes.
3. The report is attached to the test result
   (`.build/results/soak/soak.xcresult`); `soak.sh` copies it to
   `report.json` and `report.md`. The soak screen also has **Share JSON
   report**, and Debug menu → **Automated soak** runs the same soak without
   Xcode (at the default 10x).
4. Add a row to the table below.

## Results

| Date | Where | Run | Wall time | Result | Memory slope | Renewals | Leaks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-09 | iPhone 17 simulator, iOS 27.0, Apple silicon Mac | 120 min at 10x, scripted ASR ([report](soak/2026-10-09-simulator-120min.md)) | 12.1 min | passed, 8/8: 265 lines answered, 0 of 363,022 frames lost, ASR 3.9 µs/chunk early and late, first audio 63.8 → 63.3 ms, 461 of 461 TV segments rejected, 43 topic boundaries for 44 changes | +0.30 MB/h (33.4 → 34.5 MB) | 1, reseeded (at 7.2 min wall, 72 audio min) | 56 leaks, 1,792 bytes at every reading (4 during, 1 after the run): no growth |
| 2026-10-09 | same | 120 min at 10x, two earlier runs | 12.1 min each | passed, 8/8 | +0.32 and +0.28 MB/h | 1 each | no growth (56 leaks, 1,792 bytes) |
| 2026-10-09 | same | 20 min at 10x (the nightly length) | 2.0 min | passed, 8/8 | +0.79 MB/h (33.5 → 34.4 MB) | 1 (at 1.2 min wall) | no growth (56 leaks, 1,792 bytes) |
| | iPhone (A17 Pro or later) | 120 min at real time, Parakeet, xAI schedule | | pending (needs a device) | | | pending (Instruments Leaks) |

## Where this differs from the issue's plan, and why

- **Synthetic mixed audio instead of a recorded two-hour file.** The issue
  sketched a two-hour recording of the owner, a TV and silence. The soak
  generates it: the same deterministic speech-shaped signal the performance
  suite uses for the owner, another seed of it for the TV, and room noise.
  A two-hour WAV would be about 230 MB of LFS (or bundled in the app),
  and the owner's voice couldn't be shared in a public repository's CI. The
  script's word alignment is exact, so the scripted recognizer "hears" the
  owner's words without a model, and the TV is known to the sample, so voice
  ID's verdicts can be checked. With `SOAK_ASR=parakeet` the model runs on
  this audio too: its per-chunk cost depends on the audio's length, not its
  words, so `asr.chunkLatency` stays meaningful.
- **The virtual input is the capture hub.** The soak feeds the real
  `CaptureHub`, which every consumer (VAD, ASR, barge-in) subscribes to,
  rather than injecting audio below `AVAudioEngine`. Everything after the
  hardware runs as in a conversation; the audio session and the engine are
  covered by the device soak of #26 ([background.md](background.md)).
- **The fake realtime server is in process.** `ScriptedRealtimeServer`
  (#73) plays the server behind the real `RealtimeClient`'s socket seam,
  rather than a local WebSocket server: no port, no network permission on a
  device, and the same code on the simulator and the phone.
- **The session clock is scaled.** Waiting 110 real minutes for a renewal
  would make the nightly run two hours long. The renewal is placed in the
  session instead, with the orchestrator's real schedule logic, and
  `SOAK_ROLLOVER_MINUTES=xai` keeps the real schedule for the device run.
- **Voice ID scores but doesn't gate.** The verification gate (#47) isn't
  between ASR and the orchestrator yet, so the soak checks voice ID's
  verdicts on the TV separately; the TV's segments carry no words for the
  scripted recognizer, so none reaches Grok (with Parakeet they would, until
  the gate exists).
- **Leaks by the `leaks` tool on the simulator.** The Leaks instrument can't
  be driven headless in CI. `leaks` runs the same detector on the simulator
  app's process; on a device, Instruments' Leaks template is the way.
