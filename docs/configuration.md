# Configuration and secrets

Blau has no backend. The user's own xAI API key lives in the Keychain and the
app mints short-lived realtime tokens on device (issue #33). So **no API key is
ever committed to git or shipped in a release binary**. Build-time
configuration only carries non-secret values, plus an optional developer key
that is honoured in Debug builds alone.

## Files

| File | In git | Purpose |
| ---- | ------ | ------- |
| `Config/Base.xcconfig` | yes | Non-secret defaults shared by every configuration |
| `Config/Debug.xcconfig` | yes | Debug: includes Base, then `Secrets.xcconfig`, then embeds the developer key |
| `Config/Release.xcconfig` | yes | Release: includes Base, then `Secrets.xcconfig`, then forbids embedded secrets |
| `Config/Secrets.example.xcconfig` | yes | Template for `Secrets.xcconfig` (empty key) |
| `Config/Secrets.xcconfig` | **no** (gitignored) | Your local developer key; optional |

`project.yml` attaches `Debug.xcconfig` and `Release.xcconfig` at the project
level (`configFiles:`), so every target inherits them. Both pull in
`Secrets.xcconfig` with `#include?`, which is a no-op when the file is missing:
**a fresh clone builds with no secrets at all.** Settings that come after the
include (`BLAU_ENVIRONMENT`, `BLAU_INFO_XAI_DEV_API_KEY`,
`BLAU_FORBID_EMBEDDED_SECRETS`) can't be overridden from `Secrets.xcconfig`.

## Settings

| Build setting | Info.plist key | `AppConfig` property | Default |
| ------------- | -------------- | -------------------- | ------- |
| `BLAU_ENVIRONMENT` | `BlauEnvironment` | `environment` (`.debug` / `.release`) | per configuration |
| `XAI_API_HOST` | `BlauXAIAPIHost` | `xaiAPIHost`, `xaiAPIBaseURL`, `xaiRealtimeURL` | `api.x.ai` |
| `XAI_REALTIME_MODEL` | `BlauXAIRealtimeModel` | `xaiRealtimeModel` | `grok-voice-think-fast-2.0` |
| `XAI_DEV_API_KEY` → `BLAU_INFO_XAI_DEV_API_KEY` | `BlauXAIDevAPIKey` | `developmentAPIKey` | empty |

`//` starts a comment in an xcconfig file, which is why the host is stored
rather than a URL. `AppConfig` builds `https://<host>` and
`wss://<host>/v1/realtime?model=<model>` itself.

## `AppConfig`

`Blau/Configuration/AppConfig.swift` is the only code that reads these
Info.plist keys.

- `AppConfig.current` is the running app's configuration, read once from
  `Bundle.main`.
- `AppConfig(infoDictionary:honorsDevelopmentKey:)` parses strictly and throws
  `AppConfig.LoadError` for a missing, unexpanded (`$(…)`) or invalid value.
  Tests use it directly.
- `AppConfig.load(from:)` never fails. If the Info.plist is unusable it logs a
  fault (subsystem `com.joeblau.blau`, category `config`) and returns
  `AppConfig.fallback` (the `Base.xcconfig` defaults), so the app still
  launches.
- `developmentAPIKey` is `nil` unless the binary was compiled with `DEBUG`
  **and** a non-empty key was configured. Callers treat `nil` as "ask the
  user". The DEBUG-only Keychain pre-fill on first launch belongs to
  `APIKeyStore` (#33) and reads this property.
- `description`, `debugDescription` and `dump()` redact the key.

`AppConfig` is plain Foundation with no app dependencies, so it moves into
`BlauKit/BlauCore` unchanged once that package lands (#13).

## Developer key (optional)

```sh
make secrets          # creates Config/Secrets.xcconfig from the example
$EDITOR Config/Secrets.xcconfig   # XAI_DEV_API_KEY = xai-...
make generate
```

Debug builds then embed the key in their Info.plist so the app can seed the
Keychain on first launch, which saves typing it on every simulator. Without it
the app behaves exactly like a user's install: it asks for a key in onboarding
or Settings, and features that need xAI stay unavailable until one is entered.

## Release builds fail on embedded keys

The `Blau` target has a post-build phase, **Check for embedded secrets**, which
runs `scripts/check-embedded-secrets.sh`. It only enforces when
`BLAU_FORBID_EMBEDDED_SECRETS = YES` (set by `Release.xcconfig`) and fails the
build if:

1. `XAI_DEV_API_KEY` is non-empty, or
2. the built executable or Info.plist contains something shaped like an xAI
   key (`xai-` followed by 20+ letters or digits), which catches a key
   hard-coded in Swift as well.

As defence in depth, `Release.xcconfig` also forces
`BLAU_INFO_XAI_DEV_API_KEY` to empty, so the key never reaches a release
Info.plist even if the check were bypassed. The script prints only the key's
length, never the key.

The `Blau-Perf` scheme builds Release. `make perf` passes `XAI_DEV_API_KEY=`
on the command line so it works with a local key; running that scheme from
Xcode with a key configured fails, by design.

## CI

CI creates `Config/Secrets.xcconfig` from a GitHub Actions secret before
building:

```yaml
- name: Write Secrets.xcconfig
  run: scripts/write-secrets-xcconfig.sh
  env:
    XAI_DEV_API_KEY: ${{ secrets.XAI_DEV_API_KEY }}
```

The secret is optional. Tests are hermetic and never call xAI, so an unset
secret just writes an empty key. **Never set it for Release, TestFlight or App
Store jobs** (#83): those builds would fail the embedded-secrets check.
The script writes the file with mode 0600, rejects values that would break the
xcconfig syntax, and never prints the key.

`make test-scripts` runs `scripts/tests/test-secrets-scripts.sh`, the
hermetic tests for both scripts.
