# Voice ID

Blau only answers the enrolled speaker. `BlauVoiceID` turns speech into
speaker embeddings, compares them with the enrolled voiceprint and decides
accept, reject or uncertain per speech segment (issue #5). This document
covers the embedding extractor (#45); enrollment (#46), the verification
gate (#47) and threshold calibration (#48, [voice-id-eval.md](voice-id-eval.md))
build on it.

## Speaker embeddings

```swift
import BlauVoiceID

// The model directory comes from ModelManager.directory(for: .speakerEmbedding).
let embedder = try await WeSpeakerEmbedder.load(modelDirectory: directory)

// The gate's first score: the first 1.5 s of a speech segment.
let first = try await embedder.embed(SpeakerEmbeddingWindow.short.prefix(of: segment))
let score = first.cosineSimilarity(to: voiceprint)

// Several windows of one segment (one model run each).
let embeddings = try await embedder.embed(segment, windows: SpeakerEmbeddingWindow.standard)
```

| Type | Role |
| --- | --- |
| `SpeakerEmbedder` | The protocol enrollment and the gate use. Lets a challenger (CAM++) or a fake stand in |
| `WeSpeakerEmbedder` | The live embedder: validation, windows, long-audio splitting, L2 normalization, the `voiceid.embed` signpost |
| `SpeakerEmbeddingNetwork` | One model run. `CoreMLSpeakerEmbeddingNetwork` runs the Core ML model; tests use fakes |
| `SpeakerEmbedding` | A unit-length `[Float]` (256 values), the model's identifier and the audio duration it covers. `cosineSimilarity(to:)`, `mean(of:)` |
| `SpeakerEmbeddingWindow` | `.short` (1.5 s) and `.long` (3 s): how much of a segment's start to embed |
| `SpeakerEmbeddingModelInfo` | `weSpeakerResNet34LM`: identifier `wespeaker-resnet34-lm@df2625ac`, 256-d |
| `SpeakerEmbeddingBenchmark` | Latency harness behind [benchmarks.md](benchmarks.md) |

### Input

- 16 kHz mono `AudioFrame`s (what the capture engine produces), at least
  0.5 s long (`WeSpeakerEmbedder.defaultMinimumDuration`). Other sample
  rates, shorter segments and NaN or infinite samples throw
  `SpeakerEmbedderError`.
- **Windows.** Short segments degrade embeddings sharply (about 2.4% EER at
  3 s against 18.4% at 1 s), so the gate scores the first 1.5 s of speech and
  re-scores at 3 s. A window longer than the segment uses the whole segment;
  `audioDuration` on the result says how much was used.
- **Long audio.** The model takes at most 10 s. Longer segments are split
  into equal pieces of at most 10 s (no short leftover), each piece is
  embedded, and the result is the normalized mean of their directions.

### Output

L2-normalized `[Float]` of 256 values, so cosine similarity is a dot
product. On the fixture set, same-speaker pairs score at least 0.57 (mean
0.67 at 1.5 s, 0.76 at 3 s) and different speakers at most 0.37 (mean
0.07); see [benchmarks.md](benchmarks.md). The gate's thresholds
(`VoiceIDConfig.calibrated`) are calibrated on a cross-session set with
simulated rooms and noise, where scores run lower; see
[voice-id-eval.md](voice-id-eval.md).

Store `SpeakerEmbedding.modelIdentifier` with every vector
(`VoiceProfile.embeddingModelVersion`). Vectors from different models or
weights are not comparable; `cosineSimilarity(to:)` traps on a mismatch, and
a stored voiceprint with another identifier means re-enrollment. Bump the
identifier whenever the pinned weights change (a test compares it with
FluidAudio's pinned revision).

### The model

FluidAudio's Core ML conversion of pyannote's WeSpeaker ResNet34-LM
(`FluidInference/speaker-diarization-coreml`, `wespeaker_v2.mlmodelc`),
downloaded and pinned by `ModelManager` ([models.md](models.md)). Its
interface comes from pyannote's diarization pipeline:

| Tensor | Shape | Meaning |
| --- | --- | --- |
| `waveform` (in) | [3, 160000] | 10 s of 16 kHz audio. **Only row 0 is read** |
| `mask` (in) | [3, 589] | Up to three speaker masks over that one waveform |
| `embedding` (out) | [3, 256] | One embedding per mask |

The three rows are three local speakers of one chunk, not a batch: the
program slices `waveform[0:1]` and pools it under each mask. So each run
embeds one segment, and packing different segments into the rows would
silently embed the first one three times
(`otherSegmentsInTheCallDoNotChangeTheResult` guards this).

Shorter speech is **repeated** to fill the 10 s row, as FluidAudio's own
`EmbeddingExtractor` does, under an all-ones mask. Zero padding would be
wrong: the model subtracts the mean filterbank feature over the whole 10 s,
so silence would shift every frame. The result matches FluidAudio's
extractor (cosine 1.0 in `matchesFluidAudiosEmbeddingExtractor`).

`CoreMLSpeakerEmbeddingNetwork` is an actor on its own serial queue: it
owns the model and reuses its input buffers, and the synchronous Core ML
prediction never blocks Swift's cooperative thread pool. It loads with
`cpuAndNeuralEngine`, the compute units the model warm-up compiles for.
On the Mac, Core ML still places almost all of this model on the CPU; see
[benchmarks.md](benchmarks.md) for the latency and the alternative
conversion measured there.

## Telemetry

Each `embed` call is one `voiceid.embed` signpost interval (category
`voiceid`). Failures log at `error` on `Log.voiceID` with the segment count
and the error; no audio or embedding values are logged.

## Testing

| What | How |
| --- | --- |
| Unit tests (hermetic) | `swift test --filter BlauVoiceIDTests` in `Packages/BlauKit`: normalization, cosine, windows, padding, long-audio splitting, validation, errors, signposts, reading Core ML outputs (padded strides, Float16), the benchmark statistics, and the fixture clips themselves. A fake `SpeakerEmbeddingNetwork` stands in for the model |
| Real model on the fixture set (opt-in) | Download the pinned model once, then point `BLAU_SPEAKER_MODEL_DIR` at it (commands below). Checks that every same-speaker pair scores above every different-speaker pair at 1.5 s, 3 s and the whole clip, that a two-clip voiceprint picks its own speaker's held-out clip, parity with FluidAudio's `EmbeddingExtractor`, and that other segments in a call don't change a result |
| Latency (opt-in) | Add `BLAU_SPEAKER_BENCHMARK=1` to the command above: times every compute-unit setting and prints Markdown tables and the Core ML compute plan |
| Latency on iPhone (opt-in) | `SpeakerEmbeddingDeviceBenchmarkTests` in `BlauTests` with `BLAU_DEVICE_TESTS=1`, after the app has downloaded its models ([benchmarks.md](benchmarks.md)) |

```sh
cd Packages/BlauKit
BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=speakerEmbedding \
  BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
BLAU_SPEAKER_MODEL_DIR=/tmp/blau-models/speakerEmbedding/df2625ac79a7ac6b65ad868fee6d80f320da4232 \
  swift test --filter SpeakerEmbeddingModelTests
```

The fixture set is 12 CMU ARCTIC clips: four speakers (two male, two
female) reading the same three sentences, so a score can't be explained by
what was said. Licence and provenance are in
`Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures/README.md`.
