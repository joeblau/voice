# Contributing to Blau

This file covers the conventions every change follows: setup, formatting,
branches, commits, pull requests and issues. Architecture decisions live in
issue #1. Read its "Key decisions" and "Product decisions" before you change a
design.

## Setup

```sh
brew install xcodegen
make generate      # generate Blau.xcodeproj from project.yml
make lint          # check formatting before you push
make hooks         # optional: lint staged Swift files on every commit
```

You need Xcode 26 or later. swift-format ships with the Xcode toolchain, so
there is nothing else to install. `make help` lists every task. The README
covers the project layout, targets and schemes.

## Code style

Formatting is enforced by [swift-format](https://github.com/swiftlang/swift-format)
with the repo-root [`.swift-format`](.swift-format) config: 4-space indentation,
120-column lines, sorted imports and swift-format's default rule set. The
config lists every rule explicitly, so turning one on or off is a one-line,
reviewable change.

| Command         | What it does                                                   |
| --------------- | -------------------------------------------------------------- |
| `make format`   | Rewrites every Swift file in place                             |
| `make lint`     | Reports findings and fails on any of them (`--strict`)         |
| `make hooks`    | Installs `scripts/git-hooks/pre-commit`, which lints staged Swift files |
| `make unhooks`  | Removes the hook                                               |

- Both tasks run [`scripts/swift-format.sh`](scripts/swift-format.sh). It
  processes every `.swift` file git tracks or would track, so `.build/` and
  SwiftPM checkouts are never touched. Pass paths to limit a run, for example
  `scripts/swift-format.sh format Blau/RootView.swift`.
- The script uses the swift-format from the selected Xcode toolchain (the same
  one Xcode's **Editor > Format File** uses). Set `SWIFT_FORMAT` to use
  another, e.g. `SWIFT_FORMAT="swift format" make lint`. If two swift-format
  versions disagree, the one in the CI Xcode wins.
- The pre-commit hook lints what is staged, not the working copy. Skip it for
  one commit with `git commit --no-verify`.
- `.editorconfig` sets matching defaults for editors other than Xcode.
- If `make lint` reports something `make format` can't fix (naming, `forEach`,
  `Array<T>` instead of `[T]`...), fix it by hand. Silence a rule only where it
  is genuinely wrong, with `// swift-format-ignore: RuleName` on the
  declaration and a comment saying why.

Beyond formatting:

- **Swift 6 language mode, strict concurrency.** No new warnings. Avoid
  `@unchecked Sendable` and `nonisolated(unsafe)`; when one is unavoidable,
  add a comment explaining why it is safe.
- **Logic goes in `Packages/BlauKit`**, behind protocols, so it builds and is
  tested on macOS with `swift test`. Guard iOS-only APIs (AVAudioSession,
  UIKit, ActivityKit...) with `#if os(iOS)` or `#if canImport(...)`. The app
  target `Blau/` holds SwiftUI views and the composition root.
- **iOS 26.0 is the deployment target.** iOS 27 APIs go behind
  `#available(iOS 27, *)`.
- **Tests**: Swift Testing (`@Test`, `#expect`) for unit tests, XCTest for UI
  and performance tests. Tests are hermetic: no network, real API keys or model
  downloads. Use fakes, recorded fixtures and protocol seams. Gate tests that
  need real models or a device behind an environment variable such as
  `BLAU_DEVICE_TESTS=1`.
- **Logging and signposts** go through BlauTelemetry's Logger categories and
  signposts, not `print`. Log what the user said with `privacy: .private`,
  and use the canonical interval names. Both are in
  [`docs/performance.md`](docs/performance.md).
- **Third-party APIs** (FluidAudio, GRDB...): check each type and signature
  against the resolved package source before you use it.

## Secrets and generated files

- Never commit secrets. The user's xAI API key lives in the Keychain and
  realtime tokens are minted on device (#33). Local build secrets go in the
  gitignored `Secrets.xcconfig`.
- Never commit `Blau.xcodeproj`, the generated `Info.plist` or entitlements.
  Change `project.yml` and run `make generate`.

## Branches

Work happens on a short-lived branch off `main`, one issue per branch:

```
issue/<number>-<short-slug>
```

For example `issue/24-mic-capture-engine`. For work without an issue, use
`fix/<slug>`, `chore/<slug>` or `docs/<slug>`. Rebase on `main` rather than
merging `main` into the branch.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <summary in the imperative, lower case, no period>

<optional body: what and why, wrapped at 72 columns>

<optional trailers, e.g. Refs: #24>
```

**Types**: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`,
`chore`, `style`, `revert`. Mark a breaking change with `!` after the scope,
e.g. `feat(persistence)!: ...`, and a `BREAKING CHANGE:` footer.

**Scopes** follow the module map:

| Scope           | Area                                             |
| --------------- | ------------------------------------------------ |
| `core`          | `BlauCore`                                       |
| `telemetry`     | `BlauTelemetry`                                  |
| `audio`         | `BlauAudio`                                      |
| `transcription` | `BlauTranscription`                              |
| `voiceid`       | `BlauVoiceID`                                    |
| `realtime`      | `BlauRealtime`                                   |
| `persistence`   | `BlauPersistence`                                |
| `topics`        | `BlauTopics`                                     |
| `memory`        | `BlauMemory`                                     |
| `app`           | App target `Blau/`: views and composition root   |
| `infra`         | `project.yml`, Makefile, scripts, tooling        |
| `ci`            | GitHub Actions                                   |

Examples:

```
feat(audio): add 16 kHz mono ring buffer with multi-consumer fan-out
fix(realtime): truncate the assistant item on barge-in
chore(infra): configure swift-format and make lint
```

Keep each commit building and passing `make lint`.

## Pull requests

- Open the PR against `main` with the title `<What it does> (#<issue>)`, for
  example `Build the mic capture engine (#24)`. PRs are squash-merged, so the
  title becomes the commit on `main`.
- Fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md):
  - Summary
  - `Closes #<issue>`
  - Acceptance criteria copied from the issue. Check a box only if you
    verified it, and say how.
  - What still needs on-device or manual verification
  - Test evidence
- Never mark a criterion verified when it was not. Criteria that need a
  physical iPhone, the CloudKit console, App Store Connect or real xAI
  credentials stay unchecked with the reason. Still ship everything code can
  do for them, such as harnesses, test plans and docs with pending-result
  tables.
- Stay within the issue's scope. Keep edits to shared files (`project.yml`,
  `Package.swift`, the composition root, `Makefile`, CI) small and additive so
  parallel branches merge cleanly.
- Before you ask for review, run `make lint`, `make build`, the tests you
  touched, and `swift test` in `Packages/BlauKit` once it exists.
- CI must be green: the `lint`, `package-tests` and `app-tests` checks run on
  every push to the PR (see [docs/ci.md](docs/ci.md)). A failing test job
  uploads its `.xcresult` or test report, and every job reproduces locally
  with the same `make` target.

## Issues

Use one of the [issue templates](.github/ISSUE_TEMPLATE):

| Template           | Use it for                                             | Label         |
| ------------------ | ------------------------------------------------------ | ------------- |
| **Bug report**     | Something is broken or behaves unexpectedly            | `bug`         |
| **Feature**        | A new capability or improvement that one PR can close  | `enhancement` |
| **Research spike** | A time-boxed investigation ending in a written finding | `research`    |

Issues also get an `area:*` label (`area:audio`, `area:asr`, `area:ui`...) and a
priority (`P0` critical path, `P1` important, `P2` polish). Planned work
belongs to an epic and a milestone (M0 Foundation to M4 Polish & Beta). Use
the feature template's "Depends on" list to record dependencies.
