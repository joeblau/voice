# Blau

Blau is a native iOS app for long-form voice conversation with Grok. It is
built with Swift 6, SwiftUI and SwiftData, and targets iOS 26.0 and later.
See issue #1 for the architecture overview and
[`docs/architecture.md`](docs/architecture.md) for the module layout. Data is
stored with SwiftData and synced through the user's private iCloud container
([`docs/sync.md`](docs/sync.md)), with an optional Markdown copy of every
conversation in iCloud Drive → Blau ([`docs/export.md`](docs/export.md));
[`docs/release.md`](docs/release.md) has the
checklist to run before every TestFlight build.

## Getting started

The Xcode project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). `Blau.xcodeproj`, the app's
`Info.plist` and its entitlements file are generated and never committed.

```sh
brew install xcodegen && make generate
open Blau.xcodeproj
```

Run `make generate` again after every pull or after editing `project.yml`.

A fresh clone builds without any secrets. To have Debug builds pre-fill your
own xAI API key, run `make secrets` and set `XAI_DEV_API_KEY` in the
gitignored `Config/Secrets.xcconfig`. Release builds fail if a key is
configured. See [docs/configuration.md](docs/configuration.md).

## Make tasks

| Task             | What it does                                                     |
| ---------------- | ---------------------------------------------------------------- |
| `make generate`  | Generate `Blau.xcodeproj` from `project.yml`                      |
| `make open`      | Generate, then open the project in Xcode                         |
| `make build`     | Build the app for the iOS Simulator (Debug)                      |
| `make test`      | Run unit and UI tests (`Blau` scheme, `Blau` test plan, coverage) |
| `make test-unit` | Run only `BlauTests`                                             |
| `make test-ui`   | Run only `BlauUITests`                                           |
| `make test-kit`  | Run the `BlauKit` package tests on the macOS host (`swift test`) |
| `make perf`      | Run `BlauPerfTests` (`Blau-Perf` scheme, Release build)          |
| `make bench`     | Run the model benchmarks on an iPhone (`DEVICE=<udid>`, [docs](docs/benchmarks.md)) |
| `make bench-kit` | Run the model benchmarks on this Mac (reference numbers, downloads models) |
| `make eval-noise` | Compare noise suppressors (DeepFilterNet3, Apple voice isolation) on the ASR fixtures: WER and cost (downloads models, [docs](docs/noise-suppression.md)) |
| `make eval-asr`  | Evaluate the ASR engines on the fixtures: a WER, latency and RTF table per engine (downloads models, [docs](docs/asr-eval.md)) |
| `make icon-previews` | Render the app icon in every appearance into `.build/AppIcon` ([docs](docs/branding.md)) |
| `make secrets`   | Create `Config/Secrets.xcconfig` from the example                |
| `make test-scripts` | Test the secrets, CI and Instruments template scripts         |
| `make install-instruments-template` | Add the Blau template to Instruments' chooser ([docs](docs/performance.md#instruments-template)) |
| `make trace`     | Record Blau on `TRACE_DEVICE` with the Blau Instruments template |
| `make instruments-template` | Regenerate `Tools/Instruments/Blau.tracetemplate`     |
| `make verify-instruments` | Record with the template on the Mac and check every interval is captured |
| `make verify-hud` | Record a workload on the Mac and check the performance HUD's numbers match Instruments |
| `make clean`     | Delete the generated project, plists and DerivedData             |
| `make format`    | Format all Swift sources in place with swift-format              |
| `make lint`      | Lint all Swift sources with swift-format (fails on any finding)  |
| `make hooks`     | Install the optional pre-commit hook that lints staged Swift     |

Test tasks default to `DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=latest'`.
Point them at another simulator with, for example,
`make test DESTINATION='id=<simulator udid>'`. DerivedData is kept in
`.build/DerivedData`.

Formatting, branch naming, commit and pull request conventions are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Continuous integration

GitHub Actions runs `lint`, `package-tests` and `app-tests` on every pull
request and push to `main`, and the performance suite and the ASR evaluation
nightly. Each job calls
the same `make` targets as above. See [docs/ci.md](docs/ci.md).

## Project layout

| Path             | Contents                                                        |
| ---------------- | --------------------------------------------------------------- |
| `project.yml`    | XcodeGen spec: targets, settings, Info.plist keys, entitlements, schemes |
| `Blau/`          | App target sources and resources                                |
| `BlauWidgets/`   | App extension rendering the recording Live Activity ([docs](docs/background.md)) |
| `Packages/BlauKit` | Local Swift package with the business logic, one module per subsystem (see [`docs/architecture.md`](docs/architecture.md)) |
| `docs/`          | Architecture and engineering docs ([app shell, environment and feature flags](docs/app-shell.md), [branding](docs/branding.md)) |
| `BlauTests/`     | Unit tests (Swift Testing), hosted in the app                   |
| `BlauUITests/`   | UI tests (XCTest)                                               |
| `BlauPerfTests/` | Performance tests (XCTest UI-testing bundle, launch metrics)    |
| `BlauBenchmarks/` | On-device model benchmarks (XCTest, not hosted in the app; [docs](docs/benchmarks.md)) |
| `TestPlans/`     | `Blau.xctestplan` (unit + UI, coverage), `BlauPerf.xctestplan` and `BlauBenchmarks.xctestplan` |
| `Config/`        | xcconfig files; `Secrets.xcconfig` is gitignored ([docs](docs/configuration.md)) |
| `scripts/`       | `swift-format.sh` (behind `make format` and `make lint`), git hooks, embedded-secrets check, `Secrets.xcconfig` writer, `verify-signposts.sh`, `verify-hud.sh` and the Instruments template scripts (see [`docs/performance.md`](docs/performance.md)), `update-model-manifest.py` (see [`docs/models.md`](docs/models.md)), `make-vad-fixtures.py` (see [`docs/vad.md`](docs/vad.md)), `make-asr-fixtures.py` and `eval-asr.sh` (the ASR evaluation, see [`docs/asr-eval.md`](docs/asr-eval.md)), `fetch-deepfilternet3.sh` and `eval-noise-suppression.sh` (the noise suppression spike, see [`docs/noise-suppression.md`](docs/noise-suppression.md)), `voice-id-eval-librispeech.py` (the voice ID calibration set, see [`docs/voice-id-eval.md`](docs/voice-id-eval.md)), `embeddings/` (the text-embedding retrieval eval and Core ML conversion, see [`docs/benchmarks.md`](docs/benchmarks.md#text-embedding-model-59); the int8 token table, tokenizer parity and tokenizer fixtures, see [`docs/embeddings.md`](docs/embeddings.md)), and the CI helpers in `scripts/ci/` ([`docs/ci.md`](docs/ci.md)) |
| `Datasets/voice-id/` | The owner's voice ID evaluation recordings, stored with consent in LFS (see its README and [`docs/voice-id-eval.md`](docs/voice-id-eval.md)) |
| `Datasets/asr/` | The owner's ASR evaluation recordings, stored with consent in LFS (see its README and [`docs/asr-eval.md`](docs/asr-eval.md)) |
| `Tools/Instruments/` | `Blau.tracetemplate`, the Instruments template for profiling Blau, and the instrument list and options it is generated from |
| `docs/`          | Developer documentation, including [on-device models](docs/models.md), [text embeddings](docs/embeddings.md), the [memory search index](docs/memory-index.md), its [incremental indexer](docs/memory-indexer.md) and [hybrid memory search](docs/memory-search.md) |
| `.github/`       | CI workflow ([docs](docs/ci.md)), pull request and issue templates |

### Targets and schemes

- `Blau`: the app, bundle id `com.joeblau.blau`, iCloud container
  `iCloud.com.joeblau.blau`. Background mode `audio` keeps a conversation
  running with the screen locked ([docs](docs/background.md)).
- `BlauWidgets`: the app extension (`com.joeblau.blau.widgets`) that shows
  the recording Live Activity on the lock screen and in the Dynamic Island.
- `BlauTests`, `BlauUITests`, `BlauPerfTests`: unit, UI and performance tests.
- Scheme `Blau`: runs Debug and tests with the `Blau` test plan.
- Scheme `Blau-Perf`: runs and tests in Release with the `BlauPerf` test plan,
  so performance numbers come from an optimized build.
- Scheme `Blau-Benchmarks`: tests `BlauBenchmarks` in Release with the
  `BlauBenchmarks` test plan. Every test skips unless `BLAU_DEVICE_TESTS=1`
  (`make bench` sets it). Debug builds of the app also have a benchmark
  screen (the gauge button, or launch with `-BlauBenchmarks`).

The test plans refer to targets by the identifiers XcodeGen generates. Those
identifiers are derived from the target names, so they stay stable across
regenerations. If you rename a target, regenerate and update the identifiers in
`TestPlans/*.xctestplan`.
