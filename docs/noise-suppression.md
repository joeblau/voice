# Noise suppression (#51)

Blau's capture runs through voice processing (VPIO: echo cancellation,
noise suppression and gain control, [audio.md](audio.md)). This spike
asked whether a second, neural suppressor on top pays for itself on the
ASR path, the voice ID path or both, with DeepFilterNet3 (Core ML, about
4 MB, ~40 ms) as the candidate. It compared three suppressors against
"VPIO only" on the ASR evaluation harness (#32) and the voice ID evaluation
harness (#48), and measured what each costs.

## Decision

**Keep voice processing alone. Don't add DeepFilterNet3 (or Apple's
`AUSoundIsolation`) to the ASR or the verification path, and don't prompt
the user to turn on the Voice Isolation mic mode.**

- **ASR: no gain, some loss.** On the streaming path that commits turns
  (Parakeet realtime EOU), every suppressor raised the overall WER:
  9.8% alone, 13.2% after DeepFilterNet3, 19.6-23.3% after Apple's voice
  isolation. The second pass gained 2 words of 296 with DeepFilterNet3
  (1.7% → 1.0%), within the noise of a 26-fixture set.
- **The problem it was meant to fix isn't noise.** The ASR harness's worst
  case is a TV in the room (27.9% WER, 7 of 7 utterances never ended). A
  TV presenter is speech; every suppressor kept it (TV background level
  -0.3 dB after DeepFilterNet3) and some made it more intelligible, so the
  recognizer transcribed more of it (TV WER 39.7% after DeepFilterNet3).
  Competing speech is the voice ID gate's job (#47), not a denoiser's.
- **Voice ID: see [below](#voice-id).** VOICEID_SUMMARY
- **It costs latency for nothing.** 30 ms of algorithmic delay for
  DeepFilterNet3 (58-94 ms for Apple's models) on every turn, before
  compute, plus a 48 kHz path through two resamplers.
- **Cost is affordable, so it can come back.** DeepFilterNet3 runs at about
  1 ms of CPU per 20 ms frame on an M3 Max (release), entirely on the CPU
  (Core ML places all 167 operations there), so the iOS 27 background
  Neural Engine restriction wouldn't touch it. If the owner's recordings
  (below) show a gain, the code is ready to wire in.

This is recorded in issue #1 with the numbers. It is **provisional** in
the same way the harnesses are: synthetic ASR fixtures and a public voice
ID corpus on a Mac, without VPIO in the loop. The on-device checks
[below](#pending-on-device) can overturn it.

## What was compared

| Id | Suppressor | Delay | What it is |
| --- | --- | ---: | --- |
| `none` | VPIO only | 0 | The fixtures as they are. On a Mac VPIO can't process a file, so "VPIO only" is the unprocessed audio; on a device VPIO would already have taken the stationary noise off, which leaves an extra suppressor *less* to do |
| `dfn3` | DeepFilterNet3 | 30 ms | `iky1e/DeepFilterNet3-Streaming-CoreML@dfc12319` (Apache-2.0 / MIT), 48 kHz, 10 ms hops, run on the 16 kHz stream through two resamplers (`DeepFilterNet3Suppressor`) |
| `apple-voice-isolation` | Apple `AUSoundIsolation`, voice model | 58 ms | The system's neural voice isolation as an audio unit (iOS 16+), no download (`SoundIsolationSuppressor`) |
| `apple-voice-isolation-hq` | Apple `AUSoundIsolation`, high-quality voice model | 94 ms | The same unit's iOS 18+ model |

Apple's unit was added to the comparison because it answers two questions
at once: is there a zero-download alternative to DeepFilterNet3, and what
would Voice Isolation-style processing do to ASR? (It is not literally the
mic mode, which the system applies inside VPIO, but the same family of
model.)

### Where the design notes met reality

- **No Swift package to depend on.** The model's own runtime
  (`DeepFilterNet-mlx`'s `DeepFilterNetCoreML`) depends on MLX and
  `swift-huggingface`. Blau instead runs the Core ML graph itself:
  `DeepFilterNet3Processor` is an Accelerate port of DeepFilterNet's
  streaming signal path (STFT with the Vorbis window, ERB and complex
  features with running normalization, ERB gains, the 5-tap deep filter,
  overlap-add), ported from that runtime's Core ML engine and checked by
  tests that a unit-gain network reconstructs the input exactly, 30 ms
  late. With the real model it behaves like a denoiser should (cafe
  background -15 dB, speech -1.6 dB, clean speech correlation 0.998 to
  the input); a sample-level parity check against the PyTorch reference
  was not run.
- **The Core ML graph runs on the CPU.** Core ML's compute plan puts all
  167 operations on the CPU even when the Neural Engine is allowed; ANE,
  CPU-only and `.all` take the same 0.45-0.47 ms per 10 ms hop.
- **`auxiliary.npz` stores `erb_inv_fb` in Fortran order.** The reader
  reorders it (`NumPyArchive`); reading it row-major scrambles the gains.
- **~40 ms** in the issue is the model's 30 ms algorithmic delay plus
  compute and buffering.

## ASR

`make eval-noise` (Mac15,8, M3 Max, macOS 27.2, debug `swift test` build,
host loaded by other jobs; the 26 synthetic fixtures of
[asr-eval.md](asr-eval.md)). Each suppressor enhances the whole fixture
before VAD and ASR see it, as if it sat in the capture chain; its delay
and compute are added to every event's latency and to RTF
(`NoiseSuppressedASREvaluationEngine`).

Streaming, `parakeet-eou-320ms` (the path that commits turns):

| Suppressor | WER clean | WER cafe | WER tv | WER accented | WER all | Inserted | Unended | First partial p95 | End of utterance p95 | RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `none` | 4.1% | 2.9% | 27.9% | 6.0% | **9.8%** | 19 | 10 of 32 | 1259 ms | 2167 ms | 0.049 |
| `dfn3` | 2.7% | 5.7% | 39.7% | 7.1% | **13.2%** | 26 | 8 of 32 | 1291 ms | 4169 ms | 0.147 |
| `apple-voice-isolation` | 5.4% | 18.6% | 64.7% | 9.5% | **23.3%** | 31 | 9 of 32 | 1320 ms | 4746 ms | 0.067 |
| `apple-voice-isolation-hq` | 5.4% | 5.7% | 66.2% | 6.0% | **19.6%** | 28 | 6 of 32 | 1354 ms | 1924 ms | 0.078 |

Second pass, `parakeet-tdt-v3` (segmented by the reference labels):

| Suppressor | WER clean | WER cafe | WER tv | WER accented | WER all | Inserted | End of utterance p95 | RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `none` | 0.0% | 0.0% | 2.9% | 3.6% | **1.7%** | 2 | 225 ms | 0.012 |
| `dfn3` | 0.0% | 0.0% | 0.0% | 3.6% | **1.0%** | 0 | 251 ms | 0.161 |
| `apple-voice-isolation` | 0.0% | 1.4% | 0.0% | 3.6% | **1.4%** | 0 | 415 ms | 0.044 |
| `apple-voice-isolation-hq` | 0.0% | 1.4% | 7.4% | 3.6% | **3.0%** | 1 | 395 ms | 0.043 |

RTF here is the debug build's; the release cost is [below](#cost).

What each suppressor takes off (`NoiseSuppressionLiveTests`, level change
inside and outside the labelled speech, all fixtures of a category):

| Suppressor | clean: speech / background | cafe: speech / background | tv: speech / background |
| --- | --- | --- | --- |
| `dfn3` | -0.3 / -19.4 dB | -1.6 / -14.9 dB | -1.3 / -0.3 dB |
| `apple-voice-isolation` | -0.8 / -30.6 dB | -2.2 / -9.2 dB | -2.7 / -2.7 dB |
| `apple-voice-isolation-hq` | +0.1 / -32.0 dB | -0.9 / -10.6 dB | -0.9 / -0.1 dB |

Findings:

- **The suppressors work as denoisers.** DeepFilterNet3 takes 15 dB of cafe
  babble and dishes off for 1.6 dB of the user's speech; Apple's models
  take 30 dB of room tone off.
- **Parakeet doesn't need it.** The streaming model's cafe WER was 2.9%
  without any suppressor; it was trained on noisy speech, and the
  suppressors' artifacts cost it more than the noise did (cafe 5.7-18.6%).
- **TV gets worse, not better.** The TV is speech, so nothing removes it;
  cleaned up, more of it is recognized (DeepFilterNet3 18 → 26 inserted
  words overall, most of them TV). Unended utterances barely move (10 → 8
  of 32): the turn stays open because the TV keeps talking.
- **End of utterance gets slower** with every suppressor except the HQ
  model (p95 2.2 s → 4.2-4.7 s): with the background gone, the speech
  decays differently and VAD closes later on some fixtures.
- **The differences are a handful of words.** 70 words a category: one
  word is 1.4%. Nothing here argues *for* a suppressor; the streaming
  regressions are consistent across suppressors and categories.

## Voice ID

VOICEID_SECTION

## Cost

What it takes to run each suppressor on the 16 kHz stream in 20 ms capture
frames (`NoiseSuppressionBenchmark`), release build, M3 Max, host loaded by
other jobs:

| Suppressor | Load | Delay | Compute per 20 ms frame p50 / p95 | Share of the frame (p95) | Real-time factor | Memory growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `dfn3`, `cpuAndNeuralEngine` | 336 ms | 30 ms | 1.10 / 1.63 ms | 8.2% | 15× | 26 MB |
| `dfn3`, `cpuOnly` | 105 ms | 30 ms | 0.98 / 1.09 ms | 5.4% | 20× | 0.6 MB |
| `dfn3`, `all` | 180 ms | 30 ms | 0.97 / 1.08 ms | 5.4% | 20× | 1.2 MB |
| `apple-voice-isolation` | 111 ms | 58 ms | 0.24 / 0.25 ms | 1.3% | 82× | 5.4 MB |
| `apple-voice-isolation-hq` | 49 ms | 94 ms | 0.24 / 0.48 ms | 2.4% | 84× | 6.6 MB |

DeepFilterNet3's Core ML step alone is 0.47 ms per 10 ms hop (p95 0.55 ms)
on `cpuAndNeuralEngine`, 0.45 ms (p95 0.48 ms) on `cpuOnly`: the compute
plan places every operation on the CPU, so asking for the Neural Engine
only adds dispatch and load time. The other ~0.1 ms per frame is the
Swift signal path and the two resamplers. In a debug build the same chain
runs at about 3× real time, which is why the voice ID runs below used a
release build.

On an iPhone the CPU is slower than the M3 Max's; a few percent of one
core continuously, for a 1-2 hour session, is affordable but not free
(battery, thermal headroom with Parakeet and WeSpeaker on the Neural
Engine). `make bench` measures it ([pending](#pending-on-device)).

## Voice Isolation mic mode

iOS lets the user pick Standard, Voice Isolation or Wide Spectrum in
Control Center for an app using voice processing;
`AVCaptureDevice.showSystemUserInterface(.microphoneModes)` opens that
picker, and `preferredMicrophoneMode` / `activeMicrophoneMode` report it.
Blau now reads the mode (`SystemMicrophoneModeSource`, BlauAudio) but
**doesn't prompt for Voice Isolation**: Apple's voice isolation models
were the worst streaming ASR variants above (cafe 5.7-18.6%, TV 64.7-66.2%
WER), and the mode adds no protection against the TV case. If a user turns
it on themselves, Blau keeps working; the on-device check below measures
the mode itself, since a Mac can't run VPIO on a file.

## Pending on device

| Check | How | Result |
| --- | --- | --- |
| Cost on iPhone (A17 Pro or later): DeepFilterNet3 CPU and ANE, Apple's models | `scripts/fetch-deepfilternet3.sh BlauBenchmarks/Assets/DeepFilterNet3`, then `make bench DEVICE=<udid>` (`NoiseSuppressionBenchmarks`) | Pending |
| VPIO in the loop | Record the owner set ([Datasets/asr](../Datasets/asr/README.md)) through the app (VPIO on), then `make eval-noise` with `ASR_EVAL_MANIFEST` pointing at it | Pending |
| Voice Isolation mic mode vs Standard | The same recordings with the mode on and off (Control Center), compared with `make eval-asr` | Pending |
| The owner's voice ID set with each suppressor | `BLAU_VOICEID_EVAL_SUPPRESSORS=dfn3,apple-voice-isolation-hq` on [the owner's set](voice-id-eval.md#the-owners-set) | Pending |

Revisit the decision if the owner's recordings, with VPIO in the loop,
show DeepFilterNet3 lowering streaming WER or voice ID EER. Wiring it in
would mean: running it at the hardware's 48 kHz before the capture
resampler (no 16 → 48 kHz round trip), on the CPU, feeding VAD and ASR
(and voice ID only if its own numbers improve), and pinning the model in
`ModelManifest` as an optional model.

## Running it

```sh
make eval-noise                     # ASR A/B and cost; reports in .build/noise-eval
```

`scripts/eval-noise-suppression.sh` fetches DeepFilterNet3
(`scripts/fetch-deepfilternet3.sh`: the pinned revision, each file's size
and SHA-256 checked, into `.build/deepfilternet3/<revision>`; keep it out of
a `ModelStore` root such as `.build/models`, whose `ModelManager` deletes
what its manifest doesn't list), downloads the ASR models like
`make eval-asr`, and runs `NoiseSuppressionEvaluationRunTests`
(`BLAU_NOISE_EVAL=1`): every ASR engine alone and behind each suppressor,
then `NoiseSuppressionBenchmark` for each. It writes `report.json` and
`report.md` (the full ASR report), `comparison.md` (the tables above) and
`cost.md` / `cost.json`. `NOISE_EVAL_SUPPRESSORS`, `ASR_EVAL_ENGINES` and
`ASR_EVAL_CATEGORIES` narrow it.

The voice ID side runs the existing calibration run with suppressors:

```sh
cd Packages/BlauKit
BLAU_SPEAKER_MODEL_DIR=<speakerEmbedding model dir> \
BLAU_VOICEID_EVAL_MANIFEST=<dir>/blau-voiceid-manifest.json \
BLAU_VOICEID_EVAL_OUTPUT=/tmp/blau-voiceid-noise \
BLAU_VOICEID_EVAL_SUPPRESSORS=dfn3,apple-voice-isolation-hq \
BLAU_DFN3_MODEL_DIR=.build/deepfilternet3/dfc12319b3a62d09e9d51aace480c981067b9d7b \
  swift test --filter VoiceIDEvaluationRunTests
```

In the package's debug build DeepFilterNet3 runs at about 3× real time,
so a full LibriSpeech run takes hours; the numbers above came from the
same `VoiceIDEvaluator` call in a release build.

`BLAU_NOISE_SUPPRESSION_LIVE=1` (plus `BLAU_DFN3_MODEL_DIR`) runs
`NoiseSuppressionLiveTests`: each real suppressor keeps clean speech
aligned (lag 0 after removing its stated delay) and takes cafe background
down more than the speech.

## Code

| Type | Module | Role |
| --- | --- | --- |
| `NoiseSuppressor`, `NoiseSuppressorDescriptor` | BlauAudio | A streaming 16 kHz suppressor with a stated delay; `enhance(_:)` returns a whole recording aligned with the input |
| `DeepFilterNet3Parameters`, `NumPyArchive` | BlauAudio | Frame sizes, window, ERB filterbanks and normalization state from `auxiliary.npz` |
| `DeepFilterNet3Processor` | BlauAudio | The 48 kHz signal path, one 10 ms hop at a time, around a `DeepFilterNet3Network` |
| `CoreMLDeepFilterNet3Network`, `DeepFilterNet3Model` | BlauAudio | The Core ML graph with explicit GRU state; the loaded model, shared by every suppressor |
| `DeepFilterNet3Suppressor` | BlauAudio | 16 → 48 → 16 kHz around the processor (480 samples of delay at 16 kHz) |
| `SoundIsolationSuppressor` | BlauAudio | Apple's `AUSoundIsolation` in an offline manual-rendering `AVAudioEngine` |
| `NoiseSuppressorKind` | BlauAudio | The suppressors by report id, and their factories |
| `NoiseSuppressionBenchmark` | BlauAudio | Load, per-frame compute, RTF and memory (`make bench`, `make eval-noise`) |
| `MicrophoneMode`, `SystemMicrophoneModeSource` | BlauAudio | The Control Center mic mode and its picker |
| `NoiseSuppressedASREvaluationEngine`, `NoiseSuppressionComparison` | BlauTranscription | An ASR engine behind a suppressor, and the A/B table |
| `NoiseSuppressionPreprocessor` | BlauVoiceID | A suppressor as a `VoiceIDAudioPreprocessor` for `VoiceIDEvaluator` |

None of it is in the app's pipeline. Hermetic tests run the signal path
with a scripted network (no model): exact reconstruction 30 ms late at
48 kHz and through the 16 kHz resamplers, gains, feature order and
normalization, reset, the `.npz` reader (ZIP64, Fortran order, refusing
compressed or float64 entries) and every adapter.
