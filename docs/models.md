# On-device models

Blau runs speech-to-text, voice activity detection and voice ID on device
with Core ML models from [FluidAudio](https://github.com/FluidInference/FluidAudio)
(pinned in `Packages/BlauKit/Package.swift`). The models are too large to
ship in the app, so `ModelManager` (in `BlauTranscription`) downloads them
at runtime, checks them, prepares them for the device and manages them for
the rest of the app's life.

## The models

| `ModelID` | Model | Size | Required | Used by |
| --- | --- | --- | --- | --- |
| `.sileroVAD` | Silero VAD v6.2.1 (256 ms, unified) | 1 MB | yes | VAD segmenter (#28, [vad.md](vad.md)) |
| `.speakerEmbedding` | WeSpeaker ResNet34 (`wespeaker_v2`, 256-d) | 8 MB | yes | Voice ID (#45) |
| `.parakeetRealtimeEOU` | Parakeet realtime EOU 120M, 320 ms chunks | 224 MB | yes | Streaming ASR (#29, [asr.md](asr.md)) |
| `.parakeetTDTv3` | Parakeet TDT 0.6B v3 (int8 encoder) | 483 MB | no | Second pass (#30, [asr.md](asr.md#second-pass-punctuation-and-accuracy)) |
| `.textEmbedding` | EmbeddingGemma-300M, Core ML, int8 weights and int8 token table, 128 tokens | about 300 MB | no | Shared text embeddings for memory and topics (#60, [embeddings.md](embeddings.md)). **Not pinned yet** (below) |

Required models download first, during onboarding. The optional second-pass
model follows when **Download High-Accuracy Model** is on (the default);
Blau transcribes without it. The text embedding model is optional too
(Blau listens without it, and topics fall back to Apple's contextual
embedding), but it doesn't follow that setting: it downloads after the
required models either way (`ModelID.followsOptionalModelsPreference`).

### The text embedding model is not pinned yet

`ModelID.textEmbedding` exists, and `TextEmbeddingService` loads whatever
`ModelManager` installs for it, but `ModelManifest.pinned` has no entry:
#59 converts EmbeddingGemma with `scripts/embeddings/convert_coreml.py`,
and publishing the converted weights (under the Gemma Terms of Use) is the
repository owner's call, as is accepting those terms to get the weights.
Until then the manager doesn't list the model, the service reports
`notInstalled`, and topics segment on their fallback. To ship it: host the
`hosting/` folder ([benchmarks.md](benchmarks.md#hosting-the-model)),
uncomment the `textEmbedding` entry in `scripts/update-model-manifest.py`
with its repository and commit, run the script and `make format`.

## Pinning and checksums

`ModelManifest.pinned` lists, for every model, the Hugging Face repository,
a **full commit SHA** (never a branch), and every file with its exact size
and SHA-256. The app never asks Hugging Face what to download, so a build of
Blau always runs exactly the weights it was tested with, even if the
upstream repository changes. Every downloaded file is hashed before it is
accepted.

The manifest is generated, not hand-written:

```sh
scripts/update-model-manifest.py --latest   # compare pins with each repo's current commit
# edit the pins in the script, then:
scripts/update-model-manifest.py            # rewrite PinnedModelManifest.swift
make format                                 # the generated file is swift-formatted
```

Before bumping a pin, check the new revision against the resolved FluidAudio
version: file names and tensor shapes must match what its loaders expect.
`ModelManifestTests` checks the file names, the repositories and (for the
speaker model, where FluidAudio pins a commit itself) the revision against
FluidAudio's own constants, and fails if a bundle is incomplete. Old
revisions on a device are deleted automatically at the next launch.

Version note: FluidAudio's own downloader (`ModelHub`) follows `main` for
most repositories, has no checksums and always uses any network. That is why
Blau has its own downloader, and why the app calls
`FluidAudioModels.disableImplicitDownloads()` at launch (it sets
`ModelHub.offlineMode`), so a FluidAudio convenience loader can never fetch
a second, unpinned copy.

## Download

- **Wi-Fi only by default.** Downloads wait while the device is on cellular,
  a personal hotspot or a Low Data Mode network, and resume by themselves on
  Wi-Fi. The URL session also sets `allowsExpensiveNetworkAccess` and
  `allowsConstrainedNetworkAccess` to `false`, so the system enforces it even
  if the path monitor is late. Settings has **Download on Wi-Fi Only**;
  onboarding offers **Download Using Cellular Data** for the current launch
  only. Turning **Download on Wi-Fi Only** on takes effect at once: a
  download already running over cellular stops and waits for Wi-Fi, keeping
  its partial file, and the launch-only cellular override ends.
- **Resume.** Bytes stream straight to `<file>.partial` in a staging
  directory. A dropped connection, a retry or a relaunch continues with an
  HTTP `Range` request from the bytes on disk. A server that answers with
  the whole file restarts that file; a mismatched `Content-Range` is never
  spliced in.
- **Retry.** Timeouts, dropped connections, HTTP 408, 429 and 5xx retry with
  exponential backoff (1 s, 2 s, 4 s ... capped at 30 s), up to 5
  consecutive attempts that make no progress; an attempt that receives bytes
  resets the count. 4xx errors fail straight away. A file that fails its
  checksum is discarded and fetched once more, then the model fails.
- **Offline.** No connection pauses the download (`waiting(for: .connection)`)
  until the network changes.
- **Disk space.** A download doesn't start without the remaining bytes plus
  50 MB free (`volumeAvailableCapacityForImportantUsage`).

## Storage

```
Application Support/Blau/Models/          isExcludedFromBackup = true
  <model id>/<revision>/                  installed model; load it from here
    .blau-receipt.json                    written last: "this model is complete"
  .staging/<model id>/<revision>/         in-progress download (*.partial)
```

- **Application Support**, not Caches, so iOS doesn't purge the models under
  storage pressure and an offline launch keeps working.
- **Excluded from backup.** `ModelStore.prepare()` sets
  `URLResourceValues.isExcludedFromBackup` on the root at every launch (which
  covers everything inside it) and reads it back; `ModelManager
  .isExcludedFromBackup` reports the result, and Settings warns if it failed.
  The models are re-downloadable and must not count against the user's
  iCloud storage.
- **Atomic install.** A model only moves from staging to its final directory
  after every file passed its checksum, and its receipt (revision plus every
  file's SHA-256) is written before the move. At launch a model counts as
  installed only if the receipt matches the manifest and every file has the
  right size, so a crash can never leave a half-written model that looks
  complete.

## Warm-up

The first Core ML load of a model on a device compiles it for that device's
Neural Engine (about 3 to 4 s for Parakeet). After a model is installed,
`ModelManager` loads every bundle once (`CoreMLModelWarmer`, with the compute
units FluidAudio uses: Neural Engine plus CPU, the TDT preprocessor on CPU)
and records the OS version in the receipt. Core ML caches the compiled
result, so later launches on the same OS skip the warm-up and go straight to
`ready` with no loading. An OS update invalidates Core ML's cache and
triggers one more warm-up. Onboarding shows this as "Preparing the models
for this iPhone".

If a model fails to load, its files are re-hashed. Damaged files are deleted
and the model is downloaded again (once); intact files mean the model can't
run on this device and it is reported as failed.

## States

```
notDownloaded ─▶ queued ─▶ downloading ─▶ preparing ─▶ ready
                   ▲  │          │             │
                   │  ▼          ▼             ▼
                  waiting(for:)            failed
```

`ModelManager` is `@MainActor @Observable`. The app creates one in
`SpeechModels.makeManager()`, puts it in the SwiftUI environment and calls
`start()` from `BlauApp`. Views read `states`, `setupStatus` (aggregate
progress of the required models), `diskUsage` and `preferences`.

| UI | Where |
| --- | --- |
| Setup card: progress, Wi-Fi wait, cellular override, preparing, retry | `Blau/SpeechModels/SpeechModelSetupView.swift` (shown by `RootView` until onboarding, #44) |
| Settings: Wi-Fi only, optional model, per-model status and size, delete, total usage | `Blau/SpeechModels/SpeechModelSettingsView.swift` (Settings → Speech Models, from the gear on the main screen) |

## Loading a model

Load from `ModelManager.directory(for:)` with FluidAudio's local-directory
APIs; never with its downloading convenience loaders.

| Model | FluidAudio call |
| --- | --- |
| `.sileroVAD` | `SileroSpeechProbabilityModel(modelDirectory: directory)`, which wraps `VadManager(config:vadModel:)` with `MLModel(contentsOf: directory/FluidAudioModels.vadModelBundle)` |
| `.parakeetRealtimeEOU` | `StreamingEouAsrManager(chunkSize: .ms320).loadModels(from: directory)`; Blau wraps it as `ParakeetEouRecognizer.load(modelDirectory: directory)` ([asr.md](asr.md)) |
| `.parakeetTDTv3` | `AsrModels.loadLocal(from: directory, version: .v3)` |
| `.speakerEmbedding` | `MLModel(contentsOf: directory/FluidAudioModels.speakerEmbeddingBundle)`; Blau wraps it as `WeSpeakerEmbedder.load(modelDirectory: directory)` ([voice-id.md](voice-id.md)) |
| `.textEmbedding` | Not FluidAudio: `TextEmbeddingModel.load(bundle: TextEmbeddingBundle(directory: directory))` in BlauMemory, through `TextEmbeddingService` ([embeddings.md](embeddings.md)) |

`ModelDownloadSmokeTests` runs exactly these calls against real downloads.

## Telemetry

Logs go to `Log.asr` (lifecycle at `notice`, failures at `error`, metadata
only). Signposts: `model.download` (one per model download) and
`model.warmUp` (one per warm-up), both in the `asr` category; see
[performance.md](performance.md).

## Testing

| What | How |
| --- | --- |
| Unit tests (hermetic) | `swift test` in `Packages/BlauKit`: manifest, store, downloader (resume, retry, checksum, network policy, disk space), the `URLSession` transport against a stub `URLProtocol`, and the manager end to end on fixture models with fake network, transport and warmer |
| App and UI tests (hermetic) | `make test`. `BLAU_MODEL_FIXTURES=1` makes the app use tiny in-memory fixture models (`ModelFixtures`) through the real download, verify, install and warm-up path. Unit tests hosted in the app and UI tests that set any `BLAU_UI_TEST_*` stub variable use fixtures automatically, and the launch and performance tests set the variable, so no test downloads real models |
| Real download (opt-in) | `BLAU_MODEL_DOWNLOAD_SMOKE=1 swift test --filter ModelDownloadSmokeTests` in `Packages/BlauKit`: downloads the real pinned models from Hugging Face, warms them up with Core ML, loads them with FluidAudio, then relaunches offline. `BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=sileroVAD,parakeetTDTv3` picks models; `BLAU_MODEL_DOWNLOAD_SMOKE_DIR` keeps the store (run twice to test resume) |

### On-device checks

These need a physical iPhone and are recorded here when run.

| Check | How | Result |
| --- | --- | --- |
| Fresh install downloads and warms up all models with visible progress | Delete the app, install, launch on Wi-Fi, watch the setup card | Pending |
| Warm-up time per model (first launch after install) | `model.warmUp` intervals in Instruments, or `Model … ready; warm-up took … ms` in the `asr` log | Pending |
| Offline launch after the first download | Airplane mode, force-quit, launch: the setup card doesn't appear | Pending |
| Wi-Fi only | Wi-Fi off on a fresh install: "Waiting for Wi-Fi"; Wi-Fi on: resumes | Pending |
| Resume after a dropped connection or a kill | Kill the app mid-download, relaunch: progress continues from where it was | Pending |
| Excluded from backup | Settings shows no backup warning (`isExcludedFromBackup` read back `true`); after an iCloud backup, Blau's entry under Manage Account Storage > Backups is far smaller than its Documents & Data in iPhone Storage | Pending |
