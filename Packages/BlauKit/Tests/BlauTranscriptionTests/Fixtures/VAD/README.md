# VAD fixtures

Labelled speech for the voice activity segmenter tests (#28). Each fixture is
three files:

| File | Contents |
| --- | --- |
| `<name>.wav` | 16 kHz mono 16-bit PCM |
| `<name>.labels.json` | The expected segments, as 16 kHz sample offsets (`start` inclusive, `end` exclusive) |
| `<name>.silero.json` | Silero VAD v6's speech probability for every 4096-sample chunk of the WAV, recorded from the real model |

| Fixture | What it checks |
| --- | --- |
| `conversation-quiet` | Five utterances from different voices (including a 570 ms "Yes") over a quiet room at -62 dBFS, the level voice processing delivers |
| `conversation-noisy` | Four utterances over loud room noise (-42 dBFS, about 18 dB SNR) |
| `monologue-long` | 13.4 s of continuous speech: longer than the 8 s maximum, so it must be split (the label is the whole span; the test joins the split segments) |
| `pauses` | A 200 ms pause inside one segment (shorter than the 300 ms hangover) and a 700 ms pause between two |

## How they are made

`scripts/make-vad-fixtures.py` synthesises each utterance with macOS text to
speech (`say`), finds its speech on the clean clip (10 ms frames above
-50 dBFS), and places it on seeded room noise. The label is where the clean
speech sits on the timeline, so it is exact rather than hand-marked. Pauses
shorter than the hangover join utterances into one expected segment.

The speech depends on the voices installed, so regenerating changes the
audio slightly. After regenerating, re-record the probabilities:

```sh
scripts/make-vad-fixtures.py
cd Packages/BlauKit
BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=sileroVAD \
  BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
BLAU_VAD_RECORD=1 BLAU_VAD_MODEL_DIR=/tmp/blau-models/sileroVAD/<revision> \
  swift test --filter SileroLiveTests
```

`VADFixtureTests` replays the recorded probabilities through the real
segmenter, so `swift test` checks the ±100 ms criterion without Core ML or a
model download. `SileroLiveTests` runs the same check against the live model.
