# ASR evaluation

The ASR evaluation harness (#32) measures transcription quality and speed
the same way every time, so a model update, a new setting or a refactor of
the streaming pipeline shows up as a number, not an impression. It runs
every engine over a fixed set of fixtures and reports, per engine and per
condition:

- **WER**: word error rate after normalization.
- **First-partial latency**: from the start of speech to the first partial
  transcript.
- **End-of-utterance latency**: from the end of speech to the final
  transcript, the moment the turn can go to Grok.
- **RTF**: real-time factor, compute time over audio time.

```sh
make eval-asr          # a table per engine; reports in .build/asr-eval
```

The first run downloads the pinned models (about 700 MB) into
`.build/models` and builds the package; later runs take about 20 seconds on
an M3 Max. The fixtures are in Git LFS, so run `git lfs install && git lfs
pull` once after cloning. A nightly CI job runs the same target and fails on
a regression ([below](#nightly-ci)).

## Results (2026-10-07)

Mac host (Apple M3 Max, macOS 27.2), Core ML on the Neural Engine, debug
build, on the bundled fixtures. The full generated report, with every
fixture an engine got wrong, is [asr-eval/report.md](asr-eval/report.md);
its JSON is the committed baseline, [asr-eval/baseline.json](asr-eval/baseline.json).

`parakeet-eou-320ms`: Parakeet realtime EOU 120M at 320 ms chunks behind
Silero VAD, the production streaming path (`ParakeetStreamingTranscriber`,
[asr.md](asr.md)):

| Condition | WER | First partial p50 / p95 | End of utterance p50 / p95 | Unended | RTF |
| --- | ---: | ---: | ---: | ---: | ---: |
| clean | 4.1% | 942 / 970 ms | 930 / 962 ms | 0 of 8 | 0.052 |
| cafe | 2.9% | 821 / 1106 ms | 1958 / 4518 ms | 3 of 8 | 0.073 |
| tv | 27.9% | 517 / 884 ms | – | 7 of 7 | 0.125 |
| accented | 6.0% | 961 / 1275 ms | 930 / 942 ms | 0 of 9 | 0.063 |
| **all** | **9.8%** | **874 / 1267 ms** | **930 / 2171 ms** | **10 of 32** | **0.076** |

`parakeet-tdt-v3`: Parakeet TDT 0.6B v3 on each utterance, the second pass
(#30) as it ships (`ParakeetTdtRecognizer` on the audio
`SecondPassTranscriber` reads: 100 ms before the utterance, 120 ms after).
Its segments come from the reference labels, so these numbers, TV included,
are recognition accuracy with perfect boundaries (optimistic), not
endpointing or TV robustness:

| Condition | WER | End of utterance p50 / p95 | RTF |
| --- | ---: | ---: | ---: |
| clean | 0.0% | 180 / 184 ms | 0.012 |
| cafe | 0.0% | 179 / 187 ms | 0.012 |
| tv (label-segmented) | 2.9% | 189 / 214 ms | 0.015 |
| accented | 3.6% | 180 / 186 ms | 0.011 |
| **all** | **1.7%** | **182 / 197 ms** (120 ms of it padding) | **0.012** |

The host was running other builds during this run, so compute-inclusive
latency and RTF are higher than on an idle Mac (an earlier run of the same
commit: streaming RTF 0.051, second pass 176 / 182 ms and RTF 0.011, with
identical WER).

### Findings

- **A TV in the room keeps the turn open.** Silero VAD hears the presenter
  as speech, so VAD's segment never closes, and Parakeet's end-of-utterance
  token doesn't fire while someone keeps talking. All 7 TV utterances and
  3 of 8 cafe utterances were only finalized when the audio ran out
  ("unended"); live, they would have waited for the 30 s maximum. The TV's
  words also end up in the user's turn (18 of the 19 insertions). This is
  what the voice ID gate (#47) and noise suppression (#51) have to fix; the
  `unended` count is the number to watch.
- **First partials take about 0.94 s, not < 400 ms.** In quiet conditions
  the transcriber starts only once VAD confirms speech (about 0.5 s in, at
  256 ms VAD chunks), then needs a 630 ms window for its first chunk. Where
  VAD was already open (the TV fixtures) the first partial comes after
  0.5 s. Speculative transcription before VAD confirms, or the 160 ms
  export, would close most of the gap (#29's on-device check).
- **End of utterance is 0.93 s when something ends it**: VAD's end of
  speech plus the 0.9 s fallback, as designed in [asr.md](asr.md).
- **The second pass is much more accurate.** Parakeet TDT v3 gets 1.7%
  (5 words of 296) given the utterance boundaries, against 9.8% for the
  streaming model (which also has to find the boundaries and decodes in
  320 ms chunks). Its cost per utterance is about 60 ms on the Neural
  Engine.
- **The shipped padding is tight.** With `SecondPassConfiguration`'s 100 ms
  before and 120 ms after (an earlier version of this harness used 200 ms on
  both sides and scored 0.0%), two fixtures go wrong: `accented-07` loses
  the onset ("I need to" → "Inito") and `tv-02` picks up two of the TV's
  words in the trailing 120 ms ("... wrap that up with the"). Worth
  re-checking on the owner's recordings before tuning the padding.
- **Both run far faster than real time** on the Mac (RTF 0.05 and 0.01).

### Limitations

- **Synthetic speech.** The fixtures are macOS text to speech: clean,
  consistent and easier than people. The real numbers come from the owner's
  recordings ([below](#the-owners-own-voice)).
- **Mac, not iPhone.** Latency and RTF on an iPhone are pending
  ([On a device](#on-a-device)).
- **A debug build.** `swift test -c release` doesn't build on `main` yet
  (`DiagnosticsSamples` is Debug-only and BlauTelemetry's tests use it), so
  the harness runs in the package's debug build. The model work happens in
  Core ML either way; the Swift around it is slower than in the app.
- **The second pass is given the boundaries.** The offline engine
  transcribes each labelled utterance, so its WER is recognition accuracy
  alone, not endpointing.

## What it measures

`ASREvaluator` (BlauTranscription, `Sources/BlauTranscription/Evaluation`)
runs each engine over every fixture, from a clean state, and records every
transcript event with where in the audio it came out and how long the call
that produced it took.

| Metric | Definition |
| --- | --- |
| WER | Edits (substitutions + deletions + insertions) over reference words, summed over all fixtures (corpus WER, so short files don't weigh more). Both texts go through `TranscriptNormalizer` first |
| First partial | Start of an utterance's speech to the first partial that covers it (before the next utterance starts). Streaming engines only |
| End of utterance | End of an utterance's speech to the last final that covers it: when the whole turn is available. For the offline engine, the padding after the speech plus the model's compute |
| … (audio) | The same in audio time only, without compute: set by the algorithm (chunking, VAD, endpointing delays), not the hardware, so it is gated tightly anywhere |
| RTF | Compute time over audio time, VAD included. Below 1 is faster than real time |
| Missed | Utterances with no final |
| Split | Utterances cut into several finals (an end of utterance detected mid-sentence) |
| Unended | Utterances a streaming engine finalized only because the audio ended: nothing detected their end. Left out of the end-of-utterance latency, whose value would only be the fixture's tail |

**Latency without real time.** The harness replays the audio as fast as the
models allow. An event's latency is its position in the stream (how much
audio had been fed when it came out) plus the compute of the call that
produced it, which is what a live run sees as long as the engine keeps up
(RTF below 1, which the table shows).

**Normalization** (`TranscriptNormalizer`): case and diacritics folded;
punctuation and hyphens dropped; numbers, ordinals, clock times (`3:30`,
`3.30`), money and `%` spelled out; hesitations (`um`, `uh`) dropped; a few
spelling variants unified (`ok`/`okay`, British `-ise`). Contractions are not
expanded. Reference transcripts are written as spoken (no digits).

### Engines

| Id | Type | What runs |
| --- | --- | --- |
| `parakeet-eou-320ms` | `StreamingASREvaluationEngine` | The fixture through `VoiceActivitySegmenter` (Silero VAD), then 20 ms frames through `ParakeetStreamingTranscriber` with each VAD event delivered at the stream position VAD decided it, as live |
| `parakeet-tdt-v3` | `OfflineASREvaluationEngine` | The second pass as it ships: each labelled utterance cut with `SecondPassConfiguration`'s padding (100 ms before, never back into the previous utterance; 120 ms after), clamped by the same `SecondPassConfiguration.audioRange` that `SecondPassTranscriber` uses, through `ParakeetTdtRecognizer` (a fresh decoder state each time) |

Both conform to `ASREvaluationEngine`. To add an engine (the
`SpeechTranscriber` fallback, #31, or a 160 ms Parakeet export), build it as
a `StreamingASREvaluationEngine` over its recognizer, an
`OfflineASREvaluationEngine` over a `SecondPassRecognizer`, or a
new conformance; add a case to `ASREvaluationEngineID` in
`ASREvaluationRunTests.swift`, and a block to
[asr-eval/thresholds.json](asr-eval/thresholds.json).

## Fixtures

26 short WAVs in `Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR`
(Git LFS), 165 s in all, with 32 utterances and their reference transcripts
in `manifest.json`. Made by `scripts/make-asr-fixtures.py` from macOS text
to speech, so the transcripts and the speech boundaries are exact:

| Category | Fixtures | What |
| --- | ---: | --- |
| `clean` | 6 | US English (Samantha, the Siri voice) at different speaking rates over quiet room tone |
| `cafe` | 6 | Six background talkers, cups and plates and room noise, at 12, 10, 8 and 6 dB SNR |
| `tv` | 6 | A news presenter on a TV across the room (band-limited, reverberant) at 12, 9 and 6 dB SNR |
| `accented` | 8 | UK, Irish, Australian, Indian (two voices), South African English; German and Mexican Spanish voices reading English |

Six fixtures have two utterances with a 1.6–1.7 s pause, so the
end-of-utterance rules are exercised between turns. Every file ends at
least 2 s after its last word, enough for the VAD fallback.

The older formant-style macOS voices (Eddy, Flo, Sandy...) only talk in the
background: Parakeet realtime EOU decodes some of them poorly or not at all,
which says little about real people. Regenerating changes the audio a
little (it depends on the installed voices), so re-run `make eval-asr` and
update the baseline afterwards.

### The owner's own voice

The issue asks for the owner's voice in the set. That has to be recorded:
the protocol and the manifest format are in
[Datasets/asr/README.md](../Datasets/asr/README.md). Evaluate it with

```sh
make eval-asr ASR_EVAL_MANIFEST=Datasets/asr/manifest.json ASR_EVAL_BASELINE= ASR_EVAL_THRESHOLDS=
```

### Manifest format

```json
{
  "name": "blau-asr-fixtures",
  "consent": "Who agreed to what, or the licence. Required.",
  "sampleRate": 16000,
  "fixtures": [
    {
      "id": "cafe-02",
      "path": "cafe-02.wav",
      "category": "cafe",
      "sampleCount": 128640,
      "utterances": [
        { "start": 12800, "end": 46720, "text": "I just ordered a coffee so give me a second" },
        { "start": 72320, "end": 93440, "text": "Okay go ahead with the summary" }
      ],
      "tags": { "voice": "Voice 1", "snr": "12dB" }
    }
  ]
}
```

Positions count samples at `sampleRate` (default 16 kHz), `start`
inclusive, `end` exclusive; audio is any format Core Audio reads, converted
to 16 kHz mono. Paths must stay inside the manifest's directory. The loader
refuses a manifest without consent, out-of-order or overlapping labels,
labels past the audio, a `sampleCount` that doesn't match the file, and Git
LFS pointer files (with the `git lfs pull` hint).

## Running it

| Variable | Default | |
| --- | --- | --- |
| `ASR_EVAL_MODELS` | `.build/models` | Model store root; missing models are downloaded into it |
| `ASR_EVAL_DOWNLOAD` | `1` | `0` fails on missing models instead |
| `ASR_EVAL_ENGINES` | all | e.g. `parakeet-eou-320ms` |
| `ASR_EVAL_CATEGORIES` | all | e.g. `cafe,tv` |
| `ASR_EVAL_MANIFEST` | the bundled fixtures | Another set |
| `ASR_EVAL_OUTPUT` | `.build/asr-eval` | `report.json`, `report.md`, `summary.txt` |
| `ASR_EVAL_THRESHOLDS` | `docs/asr-eval/thresholds.json` | The gate; empty disables it |
| `ASR_EVAL_GATE` | `1` | `0` reports a failed gate without failing |
| `ASR_EVAL_BASELINE` | `docs/asr-eval/baseline.json` | Prints the change against it; empty disables it |
| `ASR_EVAL_CONFIGURATION` | `debug` | The `swift test` configuration |

`make eval-asr` runs `scripts/eval-asr.sh`, which runs
`ASREvaluationRunTests` with `BLAU_ASR_EVAL=1` (the test is skipped
otherwise, so `swift test` stays hermetic). The rest of the harness is
covered by hermetic tests in `Tests/BlauTranscriptionTests/Evaluation`: the
normalizer, the alignment, the dataset loader, the metrics on hand-built
transcripts, both engines over the simulated Parakeet recognizer (no Core
ML), the report, the gate and the committed baseline and thresholds.

### Updating the baseline

After a change that moves the numbers on purpose (a new model, a setting,
regenerated fixtures):

1. `make eval-asr ASR_EVAL_GATE=0` and read the comparison with the old
   baseline.
2. Copy `.build/asr-eval/report.json` to `docs/asr-eval/baseline.json` and
   `report.md` to `docs/asr-eval/report.md`.
3. Update [thresholds.json](asr-eval/thresholds.json): WER limits a few
   words above the new baseline per category, audio-time latency 150–450 ms
   above it; latency with compute and RTF stay ceilings for the CI machine.
4. Update the results above and add a row to [History](#history).

`ASREvaluationReportTests` checks that the committed thresholds accept the
committed baseline and cover every engine.

## Nightly CI

The `asr-eval` job in [ci.yml](../.github/workflows/ci.yml) runs nightly
(and from **Actions > CI > Run workflow** with **Also run the ASR
evaluation**). It checks out the LFS fixtures, restores the package build
and the models from caches (the models keyed by the pinned manifest),
runs `make eval-asr`, writes `report.md` to the run's summary page and
uploads `report.json`, `report.md` and `summary.txt` as the
`asr-eval-report-<attempt>` artifact, kept 90 days: the history of WER and
latency, night by night. The job fails when the regression gate fails.

The CI runners are virtual machines without the Neural Engine, so Core ML
runs on the CPU there: WER and the audio-time latencies should match the
Mac, compute-inclusive latency and RTF will be higher. Those two are
ceilings for now; tighten them once a few nightly runs show what the runner
does.

## On a device

These need a physical iPhone and are recorded here when run.

| Check | How | Result |
| --- | --- | --- |
| Latency and RTF on iPhone (A17 Pro or later) | Run the fixtures through the app's pipeline in a Release build (the `Blau-Benchmarks` scheme hosts model benchmarks, [benchmarks.md](benchmarks.md)) | Pending |
| The owner's voice | Record [Datasets/asr](../Datasets/asr/README.md), then `make eval-asr ASR_EVAL_MANIFEST=...` | Pending |
| First nightly run on CI | The `asr-eval` job's first artifacts: WER should match the baseline; set the compute-inclusive ceilings from them | Pending |

## History

| Date | Fixtures | Engine | WER | First partial p95 | End of utterance p95 | Unended | RTF | Device |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 2026-10-07 | 26 synthetic | `parakeet-eou-320ms` (`40a23f4c`) | 9.8% | 1260 ms | 2168 ms | 10 of 32 | 0.052 | M3 Max, debug |
| 2026-10-07 | 26 synthetic | `parakeet-tdt-v3` (`7dd20fe6`), 200 ms padding both sides | 0.0% | – | 266 ms | – | 0.010 | M3 Max, debug |
| 2026-10-07 | 26 synthetic | `parakeet-eou-320ms` (`40a23f4c`), rebased on #115 | 9.8% | 1267 ms | 2171 ms | 10 of 32 | 0.076 | M3 Max, debug, loaded host |
| 2026-10-07 | 26 synthetic | `parakeet-tdt-v3` (`7dd20fe6`), the shipped second pass (`ParakeetTdtRecognizer`, 100 / 120 ms padding) | 1.7% | – | 197 ms | – | 0.012 | M3 Max, debug, loaded host |
