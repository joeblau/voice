# Blau

Blau is a native iOS app for long-form voice conversation with Grok. It is
built with Swift 6, SwiftUI and SwiftData, and targets iOS 26.0 and later.
See issue #1 for the architecture overview.

## Getting started

The Xcode project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). `Blau.xcodeproj`, the app's
`Info.plist` and its entitlements file are generated and never committed.

```sh
brew install xcodegen && make generate
open Blau.xcodeproj
```

Run `make generate` again after every pull or after editing `project.yml`.

## Make tasks

| Task             | What it does                                                     |
| ---------------- | ---------------------------------------------------------------- |
| `make generate`  | Generate `Blau.xcodeproj` from `project.yml`                      |
| `make open`      | Generate, then open the project in Xcode                         |
| `make build`     | Build the app for the iOS Simulator (Debug)                      |
| `make test`      | Run unit and UI tests (`Blau` scheme, `Blau` test plan, coverage) |
| `make test-unit` | Run only `BlauTests`                                             |
| `make test-ui`   | Run only `BlauUITests`                                           |
| `make perf`      | Run `BlauPerfTests` (`Blau-Perf` scheme, Release build)          |
| `make clean`     | Delete the generated project, plists and DerivedData             |

Test tasks default to `DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=latest'`.
Point them at another simulator with, for example,
`make test DESTINATION='id=<simulator udid>'`. DerivedData is kept in
`.build/DerivedData`.

## Project layout

| Path             | Contents                                                        |
| ---------------- | --------------------------------------------------------------- |
| `project.yml`    | XcodeGen spec: targets, settings, Info.plist keys, entitlements, schemes |
| `Blau/`          | App target sources and resources                                |
| `BlauTests/`     | Unit tests (Swift Testing), hosted in the app                   |
| `BlauUITests/`   | UI tests (XCTest)                                               |
| `BlauPerfTests/` | Performance tests (XCTest UI-testing bundle, launch metrics)    |
| `TestPlans/`     | `Blau.xctestplan` (unit + UI, coverage) and `BlauPerf.xctestplan` |

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
