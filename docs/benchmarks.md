# Benchmarks

Measured results for Blau's on-device models. Each section says how the
numbers were produced so they can be re-run and compared. Device rows stay
**Pending** until someone runs the harness on a physical iPhone.

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
speakers (`clb`/`slt`). Thresholds are calibrated on real recordings in #48.
