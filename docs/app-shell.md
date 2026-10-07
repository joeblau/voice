# App shell

The app target is thin. `BlauApp` builds one `AppEnvironment` (the
composition root) at launch, puts it into the SwiftUI environment and
forwards scene phase changes to the services. Everything else lives in
BlauKit behind protocols, so the same views run on live services, on fakes
in SwiftUI previews and UI tests, and on whatever a unit test passes in.

| File | What it holds |
| ---- | ------------- |
| `Blau/BlauApp.swift` | `@main`: builds the environment, wraps `RootView` in `PersistenceGate`, injects the environment, runs `start()`, forwards `scenePhase` |
| `Blau/Composition/AppEnvironment.swift` | The composition root, its factories and launch-time environment detection |
| `Blau/Composition/ScenePhaseHandling.swift` | `ScenePhase` → `AppPhase`, background time, the `.appEnvironment(_:)` modifier |
| `Blau/Composition/DeviceLockObserver.swift` | Device lock and unlock (protected data) for the conversation keeper and the background inference monitor ([background.md](background.md)) |
| `Blau/LiveActivity/` | The recording Live Activity: its attributes and Stop intent (shared with the `BlauWidgets` extension) and the `RecordingIndicator` that starts, updates and ends it ([background.md](background.md)) |
| `Blau/RootView.swift` | The (still empty) main screen, the xAI Settings and onboarding entry points, and the DEBUG menu button |
| `Blau/XAI/XAIServices.swift` | The xAI services (#33): `make(config:)` for the app, `hermetic(config:)` for previews and tests |
| `Blau/Debug/` | The DEBUG menu and the reusable feature flag toggles |
| `BlauCore/Services/` | The service protocols and `UnavailableService` |
| `BlauCore/Fakes/` | Fakes for previews and tests, `TranscriptScript` |
| `BlauCore/FeatureFlags/` | `FeatureFlag`, `FeatureFlags` and their storage |
| `BlauCore/Lifecycle/` | `AppPhase` and `AppLifecycleCoordinator` |
| `Blau/Persistence/` | `PersistenceGate` (opens the stores, hands the current container to the views) and the in-memory `PersistenceController` for previews and tests |
| `BlauPersistence/Sync/PersistenceController.swift` | The SwiftData stores with iCloud sync ([sync.md](sync.md)); saves pending edits when the app leaves the foreground |

## `AppEnvironment`

`AppEnvironment` is `@MainActor @Observable`. It holds:

| Property | Type | Live | Preview / tests |
| -------- | ---- | ---- | --------------- |
| `config` | `AppConfig` | `AppConfig.current` | `AppConfig.fallback` |
| `flags` | `FeatureFlags` | `UserDefaults`, overrides in DEBUG | in memory |
| `clock` | `any BlauClock` | `SystemClock` | `SystemClock`, or a `ManualClock` from the test |
| `audio` | `any AudioService` | `AudioSessionKeeper` from `ConversationAudio.live` (#26): capture and playback on the voice-processing engine, kept alive off screen | `FakeAudioService` |
| `conversationAudio` | `ConversationAudio?` | the controller, capture hub, player and keeper behind `audio` | `nil` |
| `backgroundInference` | `BackgroundInferenceMonitor` | moves model stages off the Neural Engine off screen ([background.md](background.md)) | same, with no stages |
| `transcriber` | `any Transcriber` | unavailable until the live audio pipeline (capture hub and VAD) is composed; then `ParakeetStreamingTranscriber` (#29, [asr.md](asr.md)) | `FakeTranscriber` |
| `voiceGate` | `any VoiceGate` | unavailable until #47 | `FakeVoiceGate` |
| `realtime` | `any RealtimeService` | unavailable until #34 - #36 | `FakeRealtimeService` |
| `persistence` | `PersistenceController` | `PersistenceController.live(isDebugBuild:)`: `Application Support/Blau/Blau.store`, mirrored to iCloud when the account allows | `PersistenceController.inMemory()` |
| `topics` | `any TopicService` | unavailable until #52 - #54 | `FakeTopicService` |
| `memory` | `any MemoryService` | unavailable until #62 - #68 | `FakeMemoryService` |
| `xai` | `XAIServices` | Keychain + network (`XAIServices.make`); the `BLAU_UI_TEST_XAI` stub in DEBUG UI tests | in-memory key store + stub transport (`XAIServices.hermetic`) |
| `lifecycle` | `AppLifecycleCoordinator` | | |

Views read it with `@Environment(AppEnvironment.self)`. The
`.appEnvironment(_:)` modifier also injects `FeatureFlags`, the
`AppLifecycleCoordinator`, the `XAIAccount` (`xai.account`) and the
`PersistenceController` (Settings reads its iCloud status), so a view can
read just the part it needs.

The modifier does not set the SwiftData container: the controller opens the
stores asynchronously and replaces the container when the iCloud account
changes (`generation`). In the app, `PersistenceGate` sits inside
`.appEnvironment(_:)`, sets `.modelContainer` to the current container (so
`@Query` works) and rebuilds `RootView` for a new one. Code outside the view
tree reads `environment.modelContainer` (`persistence.stack?.container`)
each time rather than keeping it.

`BlauApp` calls `AppEnvironment.start()` from the root view's `.task` once at
launch. Today it starts the xAI services: DEBUG builds seed the developer key,
then the stored key is loaded.

### Service protocols

The protocols live in BlauCore, the lowest layer, so one subsystem can use
another through its protocol without a sibling import (rule 2 in
[architecture.md](architecture.md)). Persistence is the exception: the slot
holds BlauPersistence's `PersistenceController` itself, because views need
its `ModelContainer` and its iCloud sync state. Each
protocol is deliberately small; **the issue that builds a subsystem adds
what it needs to its protocol and replaces `UnavailableService` in
`AppEnvironment.live()`** with the real implementation.

`UnavailableService` conforms to every BlauCore service protocol: actions
throw `ServiceUnavailableError`, queries report "off" and the transcript
stream is already finished. So the live app runs, and code that calls a
missing subsystem gets an error instead of a crash.

### Choosing the environment at launch

`AppEnvironment.Kind.current` picks one when the app starts:

1. `BLAU_APP_ENVIRONMENT` (`live`, `preview`, `unit-test`, `ui-test`) if set;
2. `preview` when Xcode renders SwiftUI previews (`XCODE_RUNNING_FOR_PREVIEWS`);
3. `unit-test` when the process hosts test bundles (`XCTest*` variables), so
   `BlauTests` never opens the simulator's real store;
4. otherwise `live`.

UI tests set `BLAU_APP_ENVIRONMENT=ui-test` in `launchEnvironment` to run on
fakes with in-memory flags (see `BlauUITests/DebugMenuUITests.swift`).

### Previews and tests

```swift
#Preview {
    RootView()
        .appEnvironment(.preview(flags: [.perfHUD: true]))
}
```

`AppEnvironment.preview(flags:script:memories:isEnrolled:)` builds fakes over
a fresh in-memory store (`PersistenceController.inMemory()`, which never
touches iCloud or the disk; `await environment.persistence.start()` before
reading `modelContainer` in a test). `AppEnvironment.fake(kind:...)` does the same for
tests and takes a clock, so a test can drive the `FakeTranscriber` with a
`ManualClock`.

`FakeTranscriber` replays a `TranscriptScript`: timed `TranscriptEvent`s.
`TranscriptScript.speaking(_:)` turns lines of text into the partials (one
per word) and finals a streaming recognizer would produce. Every fake
records what it was asked to do (`sentUtterances`, `ingestedUtterances`,
`receivedTransitions`, ...) for assertions.

## Feature flags

| Flag | Default | Gates |
| ---- | ------- | ----- |
| `voiceIDEnabled` | on | Only the enrolled speaker's speech is sent to Grok |
| `secondPassASR` | on | Re-transcribing finished utterances with Parakeet TDT v3 |
| `topicLLMConfirm` | on | Confirming and titling topic boundaries with Foundation Models |
| `memoryTools` | on | Exposing the memory tools to Grok |
| `perfHUD` | off | The debug performance HUD (#71) |

A flag reads its **override** when overrides are allowed and one is set, and
its compiled-in **default** otherwise. The live environment allows
overrides only in DEBUG builds (`AppConfig.isDebugBuild`), so a release
build always runs with the defaults whatever is stored on the device.

```swift
if environment.flags.isEnabled(.secondPassASR) { ... }
```

`FeatureFlags` is `Observable` (views update when a flag changes) and
`Sendable` (pipeline code on any actor can read it synchronously).

Overriding a flag:

- **DEBUG menu.** Tap the ladybug button in the main screen's top bar. Each
  flag has a toggle; swipe a row or long-press it to reset it, or use
  **Reset All Overrides**. Overrides persist in `UserDefaults` under
  `blau.featureFlag.<name>`.
- **Launch argument**, for one run, in the scheme or a UI test:
  `-blau.featureFlag.perfHUD YES`. It wins over a stored override and can't
  be reset from the menu for that run.
- **Code:** `flags.setOverride(true, for: .perfHUD)`; `nil` removes it.

To add a flag, add a case to `FeatureFlag` with a `defaultValue`, `title` and
`summary`, update the table above and the test that lists the flags
(`FeatureFlagTests.declaresTheFlagsFromTheAppShellIssue`).

## Scene phases and the service lifecycle

`BlauApp` forwards every `scenePhase` change to
`AppEnvironment.handleScenePhase(_:)`, which maps it to a BlauKit `AppPhase`
and hands it to the `AppLifecycleCoordinator`. The coordinator ignores
repeats and calls each service's `appPhaseDidChange(_:)`:

- moving to `active`, lowest layer first: persistence, audio, transcriber,
  the background inference monitor, voice gate, realtime, topics, memory;
- moving to `inactive` or `background`, in reverse, so producers flush
  before the store saves.

Changes are delivered one at a time and in order, even when the app bounces
between foreground and background faster than the services respond. While
the services handle a move to the background, the app holds a
`UIApplication` background task so their work (such as the store's save)
finishes before iOS can suspend the process.

Blau keeps a conversation running in the background (`audio` background
mode), so a service must not stop a live session just because the app was
backgrounded: it releases what is idle and saves what could be lost. Today
`PersistenceController` saves pending main-context edits of the store that is
open now whenever the app leaves the foreground (inside a `db.save`
signpost); the `AudioSessionKeeper` keeps the conversation running off screen
and resumes on return what couldn't resume off screen, and the
`BackgroundInferenceMonitor` moves model stages off the Neural Engine and back
([background.md](background.md)). The subsystems add their own handling as
they are built.

Each move to `active` also calls `persistence.refresh()` in its own task, so
an iCloud account change made in the Settings app while Blau was in the
background (which doesn't always post `CKAccountChanged`) is picked up, and
the store's history is re-read. It runs outside the coordinator so a slow
account query never holds up the other services.

Each move to `active` also calls `xai.refresh()`, which re-reads the Keychain
so a key added or removed on another device (iCloud Keychain) shows up. A
launch goes `launch → inactive → active`, and that first activation usually
arrives while `start()` (run from the root `.task`) is still seeding the DEBUG
developer key and loading the stored key. `XAIServices.refresh()` therefore
does nothing until `start()` has finished (`hasStarted`): a read during the
seeding could miss the key being written, and `start()`'s own load would then
be skipped because the account is already loading. `start()` reads the
Keychain itself once seeding is done, so the skipped refresh loses nothing.
