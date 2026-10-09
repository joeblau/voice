# Voice ID

Blau only answers the enrolled speaker. `BlauVoiceID` turns speech into
speaker embeddings, compares them with the enrolled voiceprint and decides
accept, reject or uncertain per speech segment (issue #5). This document
covers the embedding extractor (#45), [enrollment](#enrollment-46) (#46)
and the [verification gate](#verification-gate-47) (#47); threshold
calibration (#48) is in [voice-id-eval.md](voice-id-eval.md).

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

## Enrollment (#46)

The guided capture records the owner's voice, checks every clip, and
stores the voiceprint in the synced SwiftData store. Settings → Voice ID
starts it (Enroll Your Voice / Re-enroll), offers the per-device top-up and
deletes the voiceprint; onboarding (#44) can host the same
`VoiceEnrollmentView`.

```swift
import BlauVoiceID

let enrollment = VoiceEnrollment(
    plan: .enrollment,                                   // or .topUp
    audio: ConversationEnrollmentAudio(audio: conversationAudio),
    loadEmbedder: { try await WeSpeakerEmbedder.load(modelDirectory: directory) },
    store: SwiftDataVoiceprintStore(modelContainer: container),
    deviceModel: VoiceprintDevice.currentModel)
await enrollment.start()            // returns when finished, failed, or a clip is rejected
if case .rejected = enrollment.phase { await enrollment.retry() }
```

| Type | Role |
| --- | --- |
| `EnrollmentPlan` | The prompts and clip lengths: `.enrollment` (4 × ~5 s) and `.topUp` (3 × ~5 s, about 15 s) |
| `EnrollmentPrompt` | Read a sentence, answer a question, speak quietly, speak from arm's length. The app supplies the wording (`EnrollmentPromptCopy`) |
| `EnrollmentClipRecorder` | Collects one clip from capture frames and decides when it is done; drives the live `EnrollmentMeter` |
| `EnrollmentClipAnalysis` / `EnrollmentLevelAnalyzer` | Talking time, speech and noise level, SNR, clipping and the speech range of a clip |
| `EnrollmentQualityPolicy` | The bar a clip must clear (below) |
| `EnrollmentConsistency` | Whether a clip sounds like the others, and which clip is the odd one out |
| `VoiceEnrollment` | The flow: prompts, recording, checks, embedding, saving (`@MainActor @Observable`) |
| `EnrollmentAudioSource` | The microphone. `ConversationEnrollmentAudio` in the app; `ScriptedEnrollmentAudio` in tests, previews and UI tests |
| `VoiceprintStoring` | `SwiftDataVoiceprintStore` (synced) and `InMemoryVoiceprintStore` |
| `Voiceprint`, `VoiceprintSet`, `VoiceprintStatus` | The stored voiceprint as the gate reads it: `notEnrolled`, `enrolled`, `needsReenrollment(storedModel:)`, `unreadable` |
| `VoiceprintMatcher` | Scores a probe against the centroid and every device's set, keeping the best (for the gate, #47) |

### The capture

- **Same path as a conversation.** `ConversationEnrollmentAudio` starts the
  conversation's `AudioSessionKeeper` and reads the `MicrophoneCapture`
  hub: the same voice-processing (VPIO) engine, with echo cancellation,
  noise suppression and AGC, resampled to 16 kHz by the same converter
  ([audio.md](audio.md)). It refuses to start while a conversation holds
  the microphone (`microphoneBusy`) and unmutes "pause listening" first.
  Like any capture, it shows the recording Live Activity while it runs.
- **Hands-free.** The microphone stays on from the first prompt to the
  last. A clip ends by itself once it holds 5 s of talking time and the
  user pauses for 0.5 s, or at 12 s; **Done Speaking** ends it early. An
  accepted clip moves straight on to the next prompt; a rejected one shows
  why and waits for **Try Again**.
- **Under a minute.** Four clean clips are about 4 × 7 s of audio (a
  second of reading, 5–6 s of speech, the pause). The worst case with no
  retries is 4 × 12 s = 48 s of recording. On the Mac, analysis and the
  four WeSpeaker embeddings take about 0.4 s in all
  (`RealModelEnrollmentTests`), and the model loads while the microphone
  comes up. `VoiceEnrollment.duration` and the log record the real time.
- **Only speech is embedded.** Each clip is trimmed to its speech range
  (100 ms of context on each side), so the lead-in and trailing silence
  don't dilute the voiceprint.

### The quality meter

While a clip records, the meter shows the input level, talking time
toward the 5 s target, and the running SNR. Each clip is then judged:

| Check | Rule (`EnrollmentQualityPolicy.standard`) | Shown as |
| --- | --- | --- |
| Duration | At least 3 s of talking time (speech frames plus pauses up to 160 ms). Below 3 s embeddings degrade sharply | Duration |
| Level | Mean speech energy ≥ -45 dBFS (≥ -55 dBFS for the quiet and arm's-length prompts) | Background |
| SNR | Speech over background ≥ 12 dB (≥ 8 dB for the quiet and arm's-length prompts) | Background |
| Clipping | At most 0.5% of samples at full scale | Background |
| Consistency | Cosine with the mean of the other clips ≥ 0.40, the calibrated gate's 3 s accept threshold: each clip must itself pass the gate | Your Voice |
| Top-up match | A top-up clip scores ≥ 0.27 (the 3 s reject threshold) against the synced centroid | Your Voice |

Speech frames are 20 ms frames at least 10 dB above the clip's noise floor
(its 10th-percentile frame energy) and above -60 dBFS. The level and SNR
limits are provisional, set for VPIO-processed speech; revisit them with
the owner's recordings ([voice-id-eval.md](voice-id-eval.md)).

**Which clip is wrong?** The first clip has nothing to compare with, so
consistency is decided as clips arrive (`EnrollmentConsistency`): a clip
that doesn't match the accepted ones is rejected; a second mismatch in a
row checks every clip against the others (leave one out) and drops the
accepted clips that don't fit (their prompts are asked again), or starts
over when only one clip was accepted. Before saving, the whole set is
checked once more, which also covers the first clip.

### The voiceprint

Stored in `VoiceProfile` and `VoiceEnrollmentSet` (schema v1, #19), which
sync through the private CloudKit database with the rest of the user's
data; the vectors are CloudKit-encrypted ([data-model.md](data-model.md)).

- **Enroll once, every device.** A second device reads the synced profile
  and scores against it without enrolling (`VoiceprintStatus.enrolled`).
- **Per-device sets.** Microphones differ (iPhone, iPad, AirPods), so each
  device can add its own enrollment set with the optional 15 s top-up
  (Settings → Voice ID → Add This iPhone's Microphone, offered when the
  device has no set). Sets are keyed by the hardware model
  (`VoiceprintDevice.currentModel`, e.g. `iPhone18,1`): two devices of one
  model share microphones and share a set. A top-up replaces this model's
  set and recomputes the centroid over every clip.
- **Scoring** takes the best of the centroid and every set
  (`VoiceprintMatcher`), so a probe uses whichever reference fits its
  microphone.
- **Re-enrolling** replaces the whole voiceprint (every device's set) once
  the new one is saved; cancelling keeps the old one.
- **Conflicts: last writer wins.** CloudKit resolves concurrent edits of
  one record that way. Duplicates it can't merge are resolved on read the
  same way on every device: the newest profile (`createdAt`, then
  `updatedAt`, then `id`) and the newest set per device model. Each write
  deletes the losers. Adaptive updates (#49) should write only the current
  device's set (`saveDeviceSet`), so devices don't churn each other's data.
- **Model version.** `VoiceProfile.embeddingModelVersion` stores the
  embedding model's identifier (`wespeaker-resnet34-lm@df2625ac`). When the
  app's model differs, the status is `needsReenrollment` and Settings shows
  "Re-enroll needed" with the Re-enroll button; a top-up is refused
  (`modelMismatch`). Unreadable vectors (a reset iCloud Keychain loses the
  encrypted fields) are `unreadable` and also need re-enrollment.
- **Deleting** (Settings → Voice ID or Privacy & Data) goes through
  `DataEraser`, record by record, so the deletion syncs and the voiceprint
  disappears from every device.

### On-device test plan

These need real devices and an iCloud account; record results in the PR
that runs them.

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | On iPhone A, Settings → Voice ID → Enroll Your Voice; time it from Start to "You're enrolled" | Done in under 60 s; the log line `Enrollment (enrollment) finished in … s` agrees | pending |
| 2 | Say a prompt with a TV on loud nearby | The clip is rejected (Background) | pending |
| 3 | Have someone else answer prompt 3 | Rejected (Your Voice) | pending |
| 4 | On device B (same iCloud account), open Settings → Voice ID after sync | "Enrolled", A's model listed under Enrolled Microphones, Add This iPhone's Microphone offered (if B is another model); voice ID verifies the owner on B without enrolling (the gate, #47: B's log shows `Voice ID gate on`) | pending |
| 5 | On B, run the top-up | Done in about 20 s; both models listed on A and B | pending |
| 6 | On A, Delete Voiceprint | "Not enrolled" on A, and on B after sync | pending |
| 7 | Install a build with a different speaker model identifier | Settings shows "Re-enroll needed"; re-enrolling fixes it | pending |
| 8 | Enroll with AirPods connected | The capture uses the AirPods microphone (HFP route) and completes | pending |

## Verification gate (#47)

Only the enrolled speaker's utterances reach Grok. `VerificationGate` sits
between the transcriber and the turn orchestrator, and decides each final
utterance from VAD's speech segments while the user is still talking, so
it adds (almost) no latency.

```swift
import BlauVoiceID

let verifier = try SpeakerVerifier(
    embedder: try await WeSpeakerEmbedder.load(modelDirectory: directory),
    voiceprint: voiceprint,                          // VoiceprintStatus.enrolled
    config: { settings.currentConfig() })            // Settings → Voice ID → Sensitivity
let gate = VerificationGate(verifier: verifier, history: capture.hub)
let speech = vad.speechAudio()                       // subscribe before VAD runs
Task { await gate.run(speech: speech) }
Task { await orchestrator.run(transcript: gate.filter(transcriber.events)) }
let bargeIn = BargeInMonitor(target: orchestrator, ..., speakerGate: VoiceIDBargeInGate(gate: gate))
```

| Type | Role |
| --- | --- |
| `VerificationGate` | The gate: follows VAD's speech audio, scores each segment at its checkpoints, decides finals, filters the transcript, answers barge-in |
| `SpeechVerifying` / `SpeakerVerifier` | Embeds speech and scores it against the voiceprint (`VoiceprintMatcher`, best of the centroid and every device's set) with the current sensitivity's thresholds. Also the `VoiceGate` service |
| `VerificationGateConfiguration` | Windows, the short-segment and inheritance rules, the uncertain policy, the waits |
| `UncertainSpeechPolicy` | What happens to uncertain utterances: `.commitDuringActiveTurn(minimumDuration: 2 s)` (default), `.commit`, `.discard` |
| `ConversationTurnActivity` | Whether the conversation is in an active turn: Grok answering, or within 10 s of Grok's reply or of an accepted utterance |
| `VerificationGateRules` | The decision rules as pure functions (also replayed by the evaluation harness) |
| `GatedUtterance`, `SegmentVerdict`, `SpeakerScore` | What the gate decided and why: the DEBUG lane, logs, adaptive updates (#49) |
| `VerificationGateStatistics` | Scores, failures, decisions, committed and dropped utterances, partials held back, continuations seeded and stream gaps filled, barge-in queries, the hold on finals |

### Speculative ASR

The transcriber starts on VAD's speech onset whatever voice ID will say
(it always did, #29): partials show at once and the words are ready the
moment the utterance ends. The gate scores the same speech alongside it,
from VAD's `speechAudio()` stream:

1. **1.5 s** into a segment: the first score.
2. **3 s**: the re-score, which overrides the first (longer embeddings are
   more reliable: EER 4.5% at 1.5 s, 3.0% at 3 s).
3. **End of the segment** (VAD's `speechEnded`), or **end of the
   utterance** if the transcriber commits first: scored again over all the
   speech, unless the last score already covers all but 0.5 s of it.

The score that covered the most audio decides, with `VoiceIDConfig`'s
thresholds for its length (`short` under 3 s, `long` from 3 s, after the
sensitivity shift): **accept** at or above `T_hi`, **reject** below `T_lo`,
**uncertain** in between.

**The hangover.** VAD sends about 300 ms of audio past the speech before
it ends a segment, so a segment of 1.2 - 1.5 s (or 2.7 - 3 s) can reach a
checkpoint on audio that includes the silence after it. Once the segment
has ended, scores that ran past its speech no longer count, and the end of
segment score covers exactly the speech.

**Long speech.** VAD splits a segment at 8 s, at the quietest point of the
last second, and the continuation (`SpeechOnset.isContinuation`) starts at
the split point. VAD's audio stream simply carries on from where it had
got to, up to a second past that point, so the gate starts the
continuation with the audio the split segment had already received past
the split. Any other gap in VAD's audio is filled from the capture history
(`CaptureFrameSource.history(in:)`), and only with silence when the history
no longer holds it. `VerificationGateStatistics` counts both
(`seededContinuations`, `gapSamplesFromHistory`, `gapSamplesSilenced`).

**Short segments.** Speech under 1 s isn't scored (18% EER at 1 s). It
inherits the previous segment's decision when the last *scored* speech
ended less than 5 s before it, and is uncertain otherwise. Measuring from
scored speech rather than from the previous segment stops a run of short
segments (a TV's "Yeah." "Okay." after the owner spoke) from carrying the
owner's decision on indefinitely.

### Committing and discarding

A final can span several segments (the transcriber keeps an utterance open
across short pauses, #29). Each segment it covers gives a decision, and
they combine by speech share (`VerificationGateRules.combine`), with
uncertain speech counted in the total. Unless accepted or rejected speech
makes up at least two thirds of it all, the utterance is uncertain and goes
through the uncertain policy: the owner's few words followed by 6 s of a
voice voice ID can't place (the transcriber keeps one utterance open across
the pause) is uncertain, not accepted, so it is neither sent outside an
active turn nor counted as the owner's speech that keeps a turn active.
The owner's 2 s with a 0.5 s uncertain tail (80%) still accepts, and so
does exactly two thirds. Only evidence of uncertainty counts: a short
segment that is uncertain just because it had nothing recent to inherit
(basis `noRecentDecision`) says nothing about who spoke, so it is left out
of the shares. Otherwise the owner's "Okay, so… [pause] what about
tomorrow?" (a 0.7 s opener, then 1.3 s scored and accepted) would be
dropped whenever their last scored speech was more than 5 s earlier: the
first utterance of a conversation, or any reply after Grok spoke for more
than 5 s. An utterance made only of such segments is still uncertain. Past that,
accepted and no rejected parts accept, rejected and no accepted parts
reject; a mix goes to the larger share unless the smaller is a third or
more, which makes it uncertain (the text can't be split by speaker).

| Decision | Disposition | What the orchestrator sees |
| --- | --- | --- |
| accept | `accepted` | The final, `speakerDecision: .accept`: committed to Grok |
| uncertain, in an active turn and ≥ 2 s | `uncertainCommitted` | The final, `speakerDecision: .uncertain`: committed (the orchestrator ignores only `.reject`) |
| uncertain otherwise | `uncertainDiscarded` | The final, `speakerDecision: .reject`: ignored |
| reject | `rejected` | The final, `speakerDecision: .reject`: ignored. Never sent, never stored |

A final that isn't sent still reaches the orchestrator, marked `.reject`:
the speech's partials reach it before the first score (1.5 s), moving it to
`userSpeaking` with the TV's words as the live text, and only a final ends
that utterance. The orchestrator ignores the final (it is neither sent nor
stored) and goes back to `listening`.

Only accepted utterances (and Grok's replies) keep a turn active
(`ConversationTurnActivity`): uncertain speech sent during an active turn
doesn't extend it, so a podcast can't keep itself flowing to Grok.

Partials of a segment already rejected are held back, so a TV's words don't
show as the user's live text; a refined transcript (#30) follows only a
final that was sent. Everything the gate didn't send is listed, greyed, in
the DEBUG **Ignored Speech** lane (Debug menu → Voice Loop) from
`VerificationGate.verdicts`; it is kept in memory only, and only in DEBUG
builds (Release drains the verdicts unread).

The gate runs when the `voiceIDEnabled` flag is on and a voiceprint is
enrolled for the current model (`VoiceIDGateLoader` in the app, per
conversation). Without a voiceprint every utterance goes through, as
onboarding and Settings explain. If a voiceprint is enrolled but the gate
can't start (the speaker model isn't installed, the store can't be read),
the conversation runs unprotected and the failure is logged at `error`:
better than not hearing the user at all. The user is told: while that
conversation runs, Settings → Voice ID shows "Off for this conversation"
with the reason (`VoiceIDGateStatus.unavailable`, from `VoiceLoop.voiceIDStatus`),
and the debug Voice Loop screen shows the gate's status.

### Barge-in

`VerificationGate`, adapted by the app (`VoiceIDBargeInGate`), is the barge-in monitor's `BargeInSpeakerGate` (#37):
`bargeInDecision(for:)` waits for the segment's first decision (its 1.5 s
score, or its end for shorter speech) and only `reject` stops the barge-in,
so **only accepted or uncertain speech interrupts Grok**. If no decision
comes within 2 s, the speech counts as uncertain. The cost: with voice ID
on, a barge-in lands about 1.2 s after VAD confirms the onset (at the
1.5 s score) instead of at once. Speech under 1 s is decided when it ends
(it inherits), so a quick "wait" right after the owner spoke interrupts as
soon as it is over.

### Latency

The decision is normally made before the final arrives: the gate only
holds a final while a score is still being computed, which is at most the
end-of-speech re-score, one embedding. On this Mac (M3 Max, Core ML
`cpuAndNeuralEngine`) that hold is 32-64 ms for 2.4 s of speech
(`RealModelGateScenarioTests`), under the 100 ms target; with a 3 s
segment the 3 s score already covers it and the hold is under 0.1 ms.
`VerificationGateStatistics.longestDelay` and the log line per utterance
(`held … ms`) give the number in the app; the iPhone figure is pending
(table below).

### Scoring method and AS-norm

The gate scores with whatever `VoiceIDConfig.scoring` says. The shipped
config is raw cosine against the centroid: the calibration run (#48)
found AS-norm no better on the public set (EER 4.50% against 4.50% at
1.5 s, 3.17% against 3.00% at 3 s), so no impostor cohort is bundled yet.
`SpeakerVerifier(cohort:)` takes one, and the harness compares AS-norm on
every run; switch when the owner's recordings show a gain
([voice-id-eval.md](voice-id-eval.md)).

### Results on the public calibration set

The evaluation harness replays the gate's decision on every trial
([voice-id-eval.md](voice-id-eval.md#the-verification-gate)): each 7 s+
LibriSpeech probe as one segment, decided by its longest score, 40
speakers under six clean and simulated conditions (rooms, babble, a TV
loudspeaker, overlap).

| | Accepted | Uncertain | Rejected |
| --- | ---: | ---: | ---: |
| Owner (1,600 trials) | 96.3% | 2.25% | **1.50%** |
| Impostor (74,880 trials) | **0.71%** | 6.80% | 92.5% |

Owner FRR is 1.50% counting rejections, 3.75% if uncertain speech is never
sent (outside an active turn or under 2 s). Impostors are accepted 0.71% of
the time; during an active turn, uncertain impostor speech of 2 s or more
is also sent (up to 7.5%). That is the price of the issue's default
uncertain policy; `UncertainSpeechPolicy.discard` closes it at the cost of
owner recall. These are public-corpus numbers with simulated rooms: the
owner set decides the thresholds and the policy.

### On-device test plan

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1 | Enrolled; talk to Blau normally for 5 minutes, close and from across the room | Every utterance answered; Debug → Voice Loop → Ignored Speech stays (nearly) empty; log `Utterance accepted … held … ms` under 100 ms | pending |
| 2 | Play a TV news channel and a podcast near the phone for 5 minutes while idle | Nothing sent to Grok; the lines show in Ignored Speech as rejected | pending |
| 3 | Same with Grok replying to the owner meanwhile (active turn) | TV lines not answered; count any `uncertainCommitted` TV lines | pending |
| 4 | Someone else asks Blau a question | Not answered; Ignored Speech shows it rejected | pending |
| 5 | While Grok speaks, the TV talks; then the owner says "stop" | The TV doesn't interrupt (`otherSpeaker`); the owner does, about 1.5 s into their speech | pending |
| 6 | Settings → Voice ID → Sensitivity to Strict, repeat 1 | Fewer owner utterances accepted at a distance; none sent from the TV | pending |
| 7 | Delete the voiceprint, talk | Every utterance answered (no gate) | pending |
| 8 | Instruments, Blau template: `voiceid.embed` and `voiceid.verify` per segment | One `verify` per checkpoint; embed p95 on the iPhone recorded here | pending |

## Telemetry

Each `embed` call is one `voiceid.embed` signpost interval (category
`voiceid`). Failures log at `error` on `Log.voiceID` with the segment count
and the error; no audio or embedding values are logged.

The gate's every score is a `voiceid.embed` interval followed by a
`voiceid.verify` interval (scoring and decision, `VoiceprintMatcher.verify`),
and reports the score and its accept threshold to the performance HUD's
Voice score row (`PerformanceGauges`). Each final logs its disposition,
decision, score, segment count and hold time at `notice` (the text itself
`private`); each segment's decision logs at `debug`.

Enrollment logs each clip's verdict (prompt, talking time, SNR, or the
issues) and the total duration on `Log.voiceID`, never audio or vectors.
Voiceprint saves are `db.save` intervals.

## Testing

| What | How |
| --- | --- |
| Unit tests (hermetic) | `swift test --filter BlauVoiceIDTests` in `Packages/BlauKit`: normalization, cosine, windows, padding, long-audio splitting, validation, errors, signposts, reading Core ML outputs (padded strides, Float16), the benchmark statistics, and the fixture clips themselves. A fake `SpeakerEmbeddingNetwork` stands in for the model |
| Real model on the fixture set (opt-in) | Download the pinned model once, then point `BLAU_SPEAKER_MODEL_DIR` at it (commands below). Checks that every same-speaker pair scores above every different-speaker pair at 1.5 s, 3 s and the whole clip, that a two-clip voiceprint picks its own speaker's held-out clip, parity with FluidAudio's `EmbeddingExtractor`, and that other segments in a call don't change a result |
| Latency (opt-in) | Add `BLAU_SPEAKER_BENCHMARK=1` to the command above: times every compute-unit setting and prints Markdown tables and the Core ML compute plan |
| Latency on iPhone (opt-in) | `SpeakerEmbeddingDeviceBenchmarkTests` in `BlauTests` with `BLAU_DEVICE_TESTS=1`, after the app has downloaded its models ([benchmarks.md](benchmarks.md)) |
| Enrollment (hermetic) | `EnrollmentQualityTests`, `EnrollmentConsistencyTests`, `VoiceEnrollmentTests`, `VoiceprintStoreTests` and `VoiceprintMatcherTests`: the analysis on synthetic speech and the fixture clips, the recorder's stop rules, the checks, every flow (clean, rejected, someone else, restart, top-up, denied microphone, missing model, cancel, Done), both stores (model version, top-up, duplicates, delete) and max-over-sets scoring. `ScriptedEnrollmentAudio` and `ScriptedSpeakerEmbedder` stand in for the microphone and the model |
| Enrollment on the real model (opt-in) | `RealModelEnrollmentTests` with `BLAU_SPEAKER_MODEL_DIR`: each fixture speaker enrolls, another speaker's clip is rejected, and the compute time is reported |
| Enrollment in the app | `VoiceEnrollmentAppTests` (`BlauTests`) and `VoiceEnrollmentUITests` (`BlauUITests`): enrolling from Settings stores the voiceprint Settings reads, cancelling stores nothing, deleting removes it |
| Gate (hermetic) | `VerificationGateTests`, `VerificationGateRulesTests`, `SpeakerVerifierTests`: checkpoints and re-scores, short-segment inheritance and its limit, the uncertain policy, utterances spanning segments, finals before their segment ends or starts, the capture-history fallback, continuations after VAD's 8 s split and gaps in VAD's audio (no silence scored), checkpoints reached on the hangover, which utterances extend the active turn, the transcript filter (dropped finals passed on as `.reject`), barge-in verdicts and timeouts, the hold on finals; `ScriptedVerifier` scores a scripted speaker timeline. `VoiceGateTranscriptIntegrationTests` (BlauKitIntegrationTests) runs a TV line through `gate.filter` into the real `TurnOrchestrator` |
| Gate scenarios (hermetic) | `VerificationGateScenarioTests`: the owner talking to Blau between a TV, a podcast and another person (synthetic voices through the real `SpeakerVerifier`); only the owner's lines are sent, with the turn idle and active |
| Gate on the real model (opt-in) | `RealModelGateScenarioTests` with `BLAU_SPEAKER_MODEL_DIR`: the owner (CMU ARCTIC `bdl`) close and in a small room, other speakers through a simulated TV loudspeaker and in the room; only the owner is sent. Also measures the hold on a final |
| Barge-in with voice ID | `VoiceGateBargeInIntegrationTests` (`BlauKitIntegrationTests`): the real `BargeInMonitor` asking the real gate; accepted and uncertain speech interrupt, rejected doesn't |
| Gate in the app | `VoiceLoopTests` (`BlauTests`): the Ignored Speech lane and Grok's activity reaching the gate |

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
