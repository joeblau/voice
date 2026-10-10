# Continuous integration

Every pull request and every push to `main` runs
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) on GitHub Actions.
A nightly run on `main` repeats the suite against the current runner image and
adds the XCTest performance suite, the ASR evaluation and the memory
evaluation.

## Jobs

| Check           | Runs                                                       | Same as locally     | Uploads |
| --------------- | ---------------------------------------------------------- | ------------------- | ------- |
| `lint`          | swift-format (`make lint`), then the shell-script tests    | `make lint test-scripts` | nothing |
| `package-tests` | `swift build --build-tests` and `swift test` in `Packages/BlauKit` on the macOS host | `make test-kit` | Swift Testing xUnit report |
| `app-unit-tests` | XcodeGen, then the `Blau` test plan's unit tests (`BlauTests`) on an iOS Simulator | `make test-unit` | `app-unit-tests-xcresult` |
| `app-ui-tests (K/4)` | Four jobs, one per shard: XcodeGen, the build, a warm-up launch of the app on the simulator, then the K-th quarter of `BlauUITests`, then a check that the result bundle ran every test of the shard ([UI-test shards](#ui-test-shards)) | `make test-ui UI_SHARD=K/4` | `app-ui-tests-K-xcresult` |
| `app-tests`     | Waits for `app-unit-tests` and every `app-ui-tests` shard and passes only if all of them passed: the one check for the app's tests (ubuntu, seconds) | `make test` runs the same tests in one go | nothing |
| `perf-kit`      | The BlauKit micro-benchmarks (package-benchmark) on the macOS host; fails when an allocation count (and, on a machine with performance counters, an instruction count) is more than 10% above `Packages/BlauKitBenchmarks/Thresholds` ([performance.md](performance.md#micro-benchmarks)) | `make microbench-check` | `perf-kit-results` (the check's output), 30 days; the output on the summary page |
| `perf`          | Nightly (and on demand) only: `Blau-Perf` scheme, `BlauPerf` test plan, Release with the scripted session, then the regression gate against `BlauPerfTests/Baselines/ci-simulator.json`: 10% on memory, tolerances calibrated to the runner's run-to-run spread on time ([performance.md](performance.md#the-regression-gate)) | `make perf perf-check` | `perf-results` (`perf.xcresult`, `perf-report.md`, `perf-results.json`), 90 days; the report on the summary page |
| `soak`          | Nightly (and on demand) only: the long-session soak test at reduced length, 20 minutes of mixed audio at 10x through the app's pipeline on the simulator against a local fake realtime server, plus the app's leaks read during and after the run; fails on any soak check or on leak growth ([soak.md](soak.md)) | `make soak SOAK_MINUTES=20` | `soak-results` (`report.json`, `report.md`, `leaks.*`, `summary.md`, `soak.xcresult`), 90 days; `summary.md` on the summary page |
| `asr-eval`      | Nightly (and on demand) only: every ASR engine on the LFS fixtures with the real models; fails on the regression gate ([asr-eval.md](asr-eval.md#nightly-ci)) | `make eval-asr` | `asr-eval-report` (`report.json`, `report.md`, `summary.txt`), 90 days; `report.md` on the summary page |
| `memory-eval`   | Nightly (and on demand) only: memory retrieval (and, where Apple's on-device model can run, LLM-judged answers) on the memory eval set; fails on the regression gate ([memory-eval.md](memory-eval.md#nightly-ci)) | `make eval-memory` | `memory-eval-report` (`report.json`, `report.md`, `summary.txt`), 90 days; `report.md` on the summary page |

The PR jobs run in parallel, each on its own runner, so a lint failure does
not hide a test failure, and a failing UI shard does not cancel the other
shards. Artifacts are on the run's summary page for 14
days (30 for perf), named `<job>-…-<attempt>` so a re-run never collides with
the first attempt. Open an `.xcresult` with Xcode, or run
`xcrun xcresulttool get test-results summary --path app-ui-tests.xcresult`.

Run the perf job on demand from **Actions > CI > Run workflow** and tick
**Also run the performance suite**; run it on a pull request's branch to check
a change the micro-benchmarks don't cover. Tick **Record new performance
baselines** as well to have `perf` and `perf-kit` record baselines instead of
checking them: the run uploads `ci-simulator.json`, `perf-results.json` and
`Thresholds/` as artifacts. The committed perf baseline pools several such
runs, so it reflects more than one runner host (see
[performance.md](performance.md#updating-baselines)).
The suite runs on the runner's simulator, so its baselines describe that
machine; device numbers are a separate, manual table.

## Triggers and cancellation

- `pull_request`, `push` to `main`, `merge_group` (GitHub merge queue) and
  `workflow_dispatch` run `lint`, `package-tests`, `app-unit-tests`, the
  four `app-ui-tests` shards, `app-tests` and `perf-kit`.
- `schedule` (08:23 UTC daily, `main`) runs those plus `perf`, `soak`,
  `asr-eval` and `memory-eval`. **Run workflow** has a checkbox for each of
  the four (and a length for the soak).
- A new push to a pull request cancels that PR's in-flight run. Runs on `main`
  are never cancelled mid-flight, so every merged commit gets a result; GitHub
  still drops a *queued* `main` run once a newer one is waiting.

## Runner and Xcode

The jobs run on the `xcode-27` runner image (macOS 27 with Xcode 27.x), not
`macos-26`, which only has Xcode 26.x:

- Blau is developed with Xcode 27 and the iOS 27 SDK. iOS 27 APIs are used
  behind `#available(iOS 27, *)`, which still needs the iOS 27 SDK to compile.
- Xcode 26's Swift compiler rejects code that Swift 6.4 accepts. On `main` at
  the time CI was added, `ClockTests.swift` fails to compile with Xcode 26.6
  (`SendingClosureRisksDataRace`) and passes with Xcode 27.

[`scripts/ci/select-xcode.sh`](../scripts/ci/select-xcode.sh) picks the
**newest release Xcode** on the image and exports `DEVELOPER_DIR`, so every
later step (xcodebuild, swift, swift-format) uses it. Betas are skipped; they
are recognised by Apple's `XcodeBeta` app icon rather than the folder name,
because runner images keep some release builds in folders named `_beta`.

[`scripts/ci/simulator-destination.sh`](../scripts/ci/simulator-destination.sh)
resolves the test simulator (default **iPhone 17**) to a UDID on the newest
iOS runtime that has one. A UDID instead of `name=iPhone 17,OS=latest`
because `OS=latest` means the selected Xcode's SDK version, and images often
only ship an older runtime (Xcode 27.1 with only the iOS 27.0 runtime), which
leaves xcodebuild with no destination. If the model is missing, the job fails
and lists the iPhones that are available.

The simulator is **not** booted ahead of the build: xcodebuild boots it when
testing starts (the UI shards boot it right after the build, to warm it up;
see [UI-test shards](#ui-test-shards)), and a later step shuts it down. Booting it first starved the
runner; with the freshly booted simulator's background work competing,
xcodebuild took about four minutes just to start and the job took 14 minutes
instead of 6 to 7.5.

Override any of these without a code change through repository variables
(**Settings > Secrets and variables > Actions > Variables**):

| Variable                | Default                    | Example     |
| ----------------------- | -------------------------- | ----------- |
| `BLAU_CI_RUNNER`        | `xcode-27`                 | `macos-27` once that label exists |
| `BLAU_CI_XCODE_VERSION` | newest release on the image | `27.2` (pins it, betas included) |
| `BLAU_CI_SIMULATOR`     | `iPhone 17`                | `iPhone 18 Pro` |
| `BLAU_CI_MEMORY_EVAL_READER` | `auto` (Apple's on-device model if it can run) | `none` ([memory-eval.md](memory-eval.md#nightly-ci)) |
| `BLAU_CI_MEMORY_EVAL_REQUIRE_ANSWERS` | `0` | `1` on a self-hosted runner with Apple Intelligence |
| `BLAU_CI_SOAK_MINUTES`  | `20`                       | `120` for the full two hours (about 15 minutes at 10x) ([soak.md](soak.md)) |
| `BLAU_CI_SOAK_LEAKS`    | `1`                        | `0` if the runner can't read the simulator app's leaks |

When GitHub promotes Xcode 27 to a general-availability `macos-27` image, set
`BLAU_CI_RUNNER` (or change the default in `ci.yml`).

## Caching

| Job             | Cached                                | Key                                       |
| --------------- | ------------------------------------- | ----------------------------------------- |
| `package-tests` | `Packages/BlauKit/.build`: clones, FluidAudio's binary artifacts and build products | Xcode build + `Package.swift` + `Package.resolved` |
| `app-unit-tests`, `app-ui-tests`, `perf`, `soak` | `.build/DerivedData/SourcePackages`: package clones and binary artifacts | Xcode build + `Package.swift` + `Package.resolved` |
| `perf-kit`      | `Packages/BlauKitBenchmarks/.build`: clones and build products | Xcode build + the benchmark package's `Package.swift` and `Package.resolved` + BlauKit's `Package.swift` |
| `asr-eval`      | `Packages/BlauKit/.build` (shared with `package-tests`) and `.build/models`: the pinned Core ML models, about 700 MB | The same as `package-tests`; the models by `PinnedModelManifest.swift` |
| `memory-eval`   | `Packages/BlauKit/.build` (shared with `package-tests`); the vectors are recorded fixtures, so nothing is downloaded | The same as `package-tests` |

Each key changes only with the toolchain or the dependency graph, so a cache
is saved once per change (on `main`, where pull requests can read it) and
restored by prefix otherwise. A new Xcode build starts a fresh cache, so build
products from one compiler never meet another.

`~/Library/Caches/org.swift.swiftpm` is not cached: SwiftPM and Xcode keep
their own clones in the directories above, so caching it would only store the
same repositories twice. App build products (DerivedData `Build/`) are not
cached either: a cold app build takes about a minute and a stale DerivedData
is a classic source of flaky CI.

Note that only `Packages/BlauKit/Package.resolved` is committed. The app
target resolves the same `from:` ranges independently (the generated
`Blau.xcodeproj` and its resolved file are never committed), so a new
FluidAudio release inside the allowed range reaches the app's test jobs before
`package-tests`. Bump the package's `Package.resolved` when that happens.

## UI-test shards

UI tests are most of CI's time: each one launches the app on the simulator,
and the accessibility audits take about twice as long as the rest. In one job
the suite outgrew its 40-minute limit (#179; push run
[38013389852](https://github.com/joeblau/voice/actions/runs/38013389852) was
cancelled in `SettingsUITests` after about 30 minutes of UI tests, with 38 of
the 93 still to run). So `app-unit-tests` runs `BlauTests` alone and the
`app-ui-tests` matrix splits `BlauUITests` over four jobs.

[`scripts/ci/ui-test-shard.sh`](../scripts/ci/ui-test-shard.sh) lists every
XCTest method in `BlauUITests` from the sources, sorts them by
`Class/testMethod` and deals them out like cards: shard K of N gets every
N-th test starting at the K-th. Dealing single tests rather than whole
classes spreads the slow audits evenly, and a new test lands in a shard
without anyone editing a list. `make test-ui UI_SHARD=K/N` turns the shard
into `-only-testing:BlauUITests/<Class>/<testMethod>` arguments, so a shard's
failure reproduces locally with the command in the job's log:

```sh
make test-ui UI_SHARD=2/4 DESTINATION='id=<simulator udid>'
scripts/ci/ui-test-shard.sh --list 2/4   # which tests that is
```

Nothing is dropped:

- The script fails, naming the file and line, on a `func testX()` it can't
  place in a top-level class or an extension of one, and on Swift Testing in
  `BlauUITests` (`-only-testing` by class and method would not select it).
- `make test-scripts` (the `lint` job) checks that the matrix's shards
  together are every UI test, each exactly once.
- After testing, each shard runs `ui-test-shard.sh --check`, which fails
  unless the result bundle ran exactly as many tests as the shard selected
  (skipped and failed ones count), so a selection that matched nothing
  cannot pass. It runs after failing tests too.

To change the number of shards, edit the matrix (`shard: [1, 2, 3, 4]`); the
jobs pass `strategy.job-total` as N. `make test` and `make test-ui` without
`UI_SHARD` still run everything in one go.

Two things the single job got for free need doing in each shard:

- **A warm simulator.** On a cold runner simulator the app's first launch
  outlasted XCUITest's launch timeout ("Timed out while launching
  application"), failing the first test of two of the three shards of the
  first sharded run (38018073024). In one job the app-hosted unit tests had absorbed that.
  So each shard builds first (`make build-tests`), then
  [`scripts/ci/warm-simulator.sh`](../scripts/ci/warm-simulator.sh) boots the
  device, waits for it, and installs and launches the app once with the UI
  tests' fake services before `make test-ui` (whose build is then a no-op).
  Booting only after the build keeps the boot from starving the build (see
  [Runner and Xcode](#runner-and-xcode)).
- **No test diagnostics.** The app test jobs pass
  `-collect-test-diagnostics never`. Otherwise, at the end of a session with
  a failure (or even without one, after the unit tests), xcodebuild ran
  `simctl diagnose` for its full 600-second timeout and collected nothing:
  ten minutes of every job. Failures, logs and screenshots are in the
  `.xcresult` either way.

## Runtime

The jobs run in parallel, so a run takes as long as its slowest job when
enough runners are free; when they aren't, jobs queue, which can take longer
than the jobs. Measured on the pull request for #179 (runs 38018073024 and
38021860678), `xcode-27` image, Xcode 27.1, warm cache:

| Job             | Duration | Where the time goes |
| --------------- | -------- | ------------------- |
| `lint`          | ~1 min   | swift-format, script tests |
| `package-tests` | 6 to 8 min | cache restore (~580 MB), build (up to 4.5 min), up to 2 min of tests |
| `app-unit-tests` | about 9 min | 2.5 min build; booting the simulator, then 306 unit tests in about 4 min |
| `app-ui-tests` (each, three shards) | 24 to 36 min | 4 to 8 min build, 3 to 8 min booting and warming the simulator, then 14 to 21 min of UI tests |

The UI tests take 45 to 55 minutes in a row on the runner, and grow with the
number of UI tests, not with the code. Four shards bring each job to about
half its limit. When the shards approach their limit, add a shard before
reaching for a larger runner. Each job's `timeout-minutes` (15 to 60, 75 for
`soak`, 90 for `perf`) is a safety net for a hung simulator, not the budget:
`app-unit-tests` has 30 and each `app-ui-tests` shard 60, about twice what
they take on a busy runner.

## Secrets

CI uses **no secrets**. Tests are hermetic and never call xAI, and a missing
`Config/Secrets.xcconfig` is fine. The workflow uploads `.xcresult` bundles,
and GitHub does not mask secrets inside artifacts, so never map
`XAI_DEV_API_KEY` or any other secret into a job; see
[configuration.md](configuration.md#ci). `make test-scripts` fails if
`ci.yml` references a secret or the key, or uses an action that is not pinned
to a full commit SHA.

The release workflow, [`release.yml`](../.github/workflows/release.yml), is
the one exception: it runs only for `v*` tags (and on demand), reads the App
Store Connect key and signing secrets from the `testflight` environment, maps
them into the single step that signs and uploads, and never uploads the IPA
or build logs. `make test-scripts` checks those rules for `release.yml` too.
See [release.md](release.md).

## Required checks

To block merging on red CI, add `lint`, `package-tests`, `app-tests` and
`perf-kit` as required status checks for `main` under **Settings > Branches**
(or a ruleset). That is a repository setting, not part of the workflow.

`app-tests` stands for all of the app's tests: it needs `app-unit-tests` and
every `app-ui-tests` shard and fails unless each of them passed, so the
required checks don't change when the number of shards does. It runs even
when they fail or are cancelled (`if: always()`), because GitHub counts a
skipped required check as passing. Don't require the shards' own checks:
their names include the shard count.

## Changing the workflow

- Pin every action to a full commit SHA with the version in a comment
  (`uses: actions/checkout@<sha> # v7.0.1`). `make test-scripts` checks it.
- Lint the workflow with [actionlint](https://github.com/rhysd/actionlint)
  (`brew install actionlint`) and the scripts with `shellcheck`.
- Keep the jobs calling `make` targets so a failure reproduces locally with
  the same command.

## UI assertions on iOS 27

Selectable transcript text can report an accessibility frame at the screen
edge even when its rendered SwiftUI frame keeps the 16-point margin. Debug
builds launched in the `ui-test` environment expose each row's actual frame
through a one-point accessibility probe (`<row identifier>.geometry`).
Alignment, width, and header-overlap assertions read these frames, retaining
the original bounds. The probe is absent from production builds and other
launch environments.

Asynchronous state changes are awaited before assertions: debug-menu toggle
values, the model setup inset leaving, and onboarding's next visible step.
Resuming permissions can proceed directly to iCloud when models are already
ready. Timeline title refinement is triggered after reaching history rather
than by a timer measured from launch.
