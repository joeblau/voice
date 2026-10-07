# Blau

Blau is a native iOS app for long-form voice conversation with Grok. It is
built with Swift 6, SwiftUI and SwiftData, and targets iOS 26.0 and later.
See issue #1 for the architecture overview and
[`docs/architecture.md`](docs/architecture.md) for the module layout.

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
| `make secrets`   | Create `Config/Secrets.xcconfig` from the example                |
| `make test-scripts` | Test the secrets build scripts                                |
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

## Project layout

| Path             | Contents                                                        |
| ---------------- | --------------------------------------------------------------- |
| `project.yml`    | XcodeGen spec: targets, settings, Info.plist keys, entitlements, schemes |
| `Blau/`          | App target sources and resources                                |
| `Packages/BlauKit` | Local Swift package with the business logic, one module per subsystem (see [`docs/architecture.md`](docs/architecture.md)) |
| `docs/`          | Architecture and engineering docs                               |
| `BlauTests/`     | Unit tests (Swift Testing), hosted in the app                   |
| `BlauUITests/`   | UI tests (XCTest)                                               |
| `BlauPerfTests/` | Performance tests (XCTest UI-testing bundle, launch metrics)    |
| `TestPlans/`     | `Blau.xctestplan` (unit + UI, coverage) and `BlauPerf.xctestplan` |
| `Config/`        | xcconfig files; `Secrets.xcconfig` is gitignored ([docs](docs/configuration.md)) |
| `scripts/`       | `swift-format.sh` (behind `make format` and `make lint`), git hooks, embedded-secrets check and `Secrets.xcconfig` writer |
| `docs/`          | Developer documentation                                         |
| `.github/`       | Pull request and issue templates                                |

### Targets and schemes

- `Blau`: the app, bundle id `com.joeblau.blau`, iCloud container
  `iCloud.com.joeblau.blau`.
- `BlauTests`, `BlauUITests`, `BlauPerfTests`: unit, UI and performance tests.
- Scheme `Blau`: runs Debug and tests with the `Blau` test plan.
- Scheme `Blau-Perf`: runs and tests in Release with the `BlauPerf` test plan,
  so performance numbers come from an optimized build.

The test plans refer to targets by the identifiers XcodeGen generates. Those
identifiers are derived from the target names, so they stay stable across
regenerations. If you rename a target, regenerate and update the identifiers in
`TestPlans/*.xctestplan`.
