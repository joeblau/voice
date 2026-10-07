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
| `Blau/RootView.swift` | The main screen ([below](#main-screen)): navigation stack, bottom bar, content area, the Settings and xAI onboarding sheets, and the DEBUG menu button |
| `Blau/Branding/` | The brand's color tokens (`BrandColor`, `TopicDotColor`), type scale (`BrandTextStyle`) and the `BrandLockup` the empty main screen shows ([branding.md](branding.md)) |
| `Blau/MainScreen/` | The bottom bar's `SettingsButton` and `RecordButton` (its face, VoiceOver text and the "You're muted" hint) and their accessibility identifiers; the button's logic is `RecordButtonModel` in `BlauRealtime/Control` ([below](#record)) |
| `Blau/XAI/XAIServices.swift` | The xAI services (#33): `make(config:)` for the app, `hermetic(config:)` for previews and tests |
| `Blau/VoiceLoop/` | `VoiceLoop` (the spoken conversation: the live audio pipeline feeding the `TurnOrchestrator`, #36), the SwiftData transcript recorder, the HUD rows and the DEBUG Voice Loop screen |
| `Blau/Debug/` | The DEBUG menu and the reusable feature flag toggles |
| `Blau/Issues/` | `IssueCenter` (the current issue of the conversation, the audio and iCloud, fed to the banner; the network path fed to the orchestrator) and `IssueBanner`, the banner above the conversation with the recovery actions ([errors.md](errors.md), #80) |
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
| `conversationAudio` | `ConversationAudio?` | the controller, capture hub, player and keeper behind `audio`; the `TurnOrchestrator` plays replies on its player and `VoiceLoop` starts it | `nil` |
| `backgroundInference` | `BackgroundInferenceMonitor` | moves model stages off the Neural Engine off screen ([background.md](background.md)); `VoiceLoop` registers its Silero VAD | same, with no stages |
| `transcriber` | `any Transcriber` | unavailable; `VoiceLoop` builds a `ParakeetStreamingTranscriber` (#29, [asr.md](asr.md)) over the conversation audio's capture hub and its own VAD for each conversation | `FakeTranscriber` |
| `voiceGate` | `any VoiceGate` | unavailable until #47 | `FakeVoiceGate` |
| `realtime` | `any RealtimeService` | `TurnOrchestrator` (#36, [realtime.md](realtime.md#turn-orchestration)): the xAI client, session configuration, a `StreamingAudioPlayer` and the SwiftData transcript | `FakeRealtimeService` |
| `voiceLoop` | `VoiceLoop` | Starts the conversation audio (through its keeper), builds the VAD and Parakeet on `start()` and feeds the orchestrator; Debug menu → Voice Loop, and the Live Activity Stop button stops it | unavailable (no orchestrator) |
| `conversation` | `any ConversationSession` | `VoiceLoopSession`: the voice loop and its conversation audio, for the record button (#41) | `FakeConversationSession` over the fake `audio` (a 400 ms start in previews) |
| `persistence` | `PersistenceController` | `PersistenceController.live(isDebugBuild:)`: `Application Support/Blau/Blau.store`, mirrored to iCloud when the account allows | `PersistenceController.inMemory()` |
| `topics` | `any TopicService` | `TopicLifecycle` (#54, [topics.md](topics.md#topic-lifecycle)): fed by the orchestrator's transcript (`TopicTrackingTranscript`), writing topics through the transcript's store | `FakeTopicService` |
| `topicLifecycle` | `TopicLifecycle` | the same lifecycle as `topics`; the timeline's rename, merge and split go through it | keyword titles over the in-memory store (`TopicLifecycle.offline`) |
| `memory` | `any MemoryService` | `MemoryToolService` (#68, [memory-tools.md](memory-tools.md)): search over the store and index `memoryIndexing` has open; the same service backs Grok's memory tools, which `realtimeSession` declares and the orchestrator runs behind the `memoryTools` flag | `FakeMemoryService` |
| `transcriptionSettings` | `TranscriptionSettings` | `UserDefaults` (`blau.transcription.engine`); the `blau.uitests` suite in DEBUG UI tests | in memory, Apple's engine reported installed |
| `markdownExport` | `MarkdownExportController` | Markdown files in iCloud Drive → Blau (#78, [export.md](export.md)); settings in `UserDefaults`, the `blau.uitests` suite in DEBUG UI tests; `start()` runs its automatic export, leaving the foreground flushes it | a temporary folder and in-memory settings (`MarkdownExportController.local`) |
| `xai` | `XAIServices` | Keychain + network (`XAIServices.make`); the `BLAU_UI_TEST_XAI` stub in DEBUG UI tests | in-memory key store + stub transport (`XAIServices.hermetic`) |
| `issues` | `IssueCenter` | follows the orchestrator, the conversation audio's keeper and the store's sync state; feeds `NWPathMonitor` (`SystemNetworkMonitor`) to the orchestrator for offline mode | the store's sync state only; `-BlauIssueFixture <code>` shows one catalog entry in UI tests |
| `lifecycle` | `AppLifecycleCoordinator` | | |

Views read it with `@Environment(AppEnvironment.self)`. The
`.appEnvironment(_:)` modifier also injects `FeatureFlags`, the
`AppLifecycleCoordinator`, the `XAIAccount` (`xai.account`), the
`PersistenceController` (Settings reads its iCloud status), the
`TranscriptionSettings` (Settings → Speech Recognition) and the
`MarkdownExportController` (Settings → Markdown Export), so a view can read
just the part it needs.

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

## Main screen

`RootView` is the one screen the app opens on (#40). Its layout is a
product requirement: **Settings bottom-left, Record bottom-right**, on every
iPhone size, in portrait and landscape.

```swift
NavigationStack {
    MainScreen()  // the conversation (#42) and topic timeline (#56)
        .toolbar {
            ToolbarItem(placement: .bottomBar) { SettingsButton { ... } }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { RecordButton(model: record) }
        }
}
```

- Both controls are bottom-bar toolbar items with a flexible
  `ToolbarSpacer` (iOS 26) between them, so the system pins one to each end,
  keeps them clear of the home indicator and the landscape safe areas, and
  draws them as Liquid Glass. Record uses the prominent (tinted) style,
  tinted per state (see [Record](#record)). Nothing is positioned by hand, which is what
  keeps the layout right on every screen size.
- `MainScreen` is a `ScrollView` anchored to the bottom
  (`defaultScrollAnchor(.bottom)`) that runs under the bar's glass, with
  the system scroll edge effect behind the controls. Its empty state is at
  least as tall as the area between the bars (a `GeometryReader` around the
  scroll view, which respects the safe area while the scroll view inside
  still runs under the bars), so it stays centered and scrolls rather than
  clips at large Dynamic Type sizes. Once there is a conversation it shows
  the chat transcript instead ([chat.md](chat.md)).
- Until onboarding (#44) exists, the speech-model setup card
  (`SpeechModelSetupView`, `blau.models.setup`) shows while the required
  models aren't ready. It is a `.safeAreaInset(edge: .bottom)` on
  `MainScreen` *inside* the navigation stack, after `.toolbar`, so it sits
  above the bottom bar. On the outside of the stack it would be drawn over
  Settings and Record.
- Both buttons are icon-only with text labels for VoiceOver and the large
  content viewer (long-press a bar button at accessibility text sizes).
- The app supports portrait and both landscape orientations
  (`UISupportedInterfaceOrientations` in `project.yml`).

| Control | Identifier | Label | Value |
| ------- | ---------- | ----- | ----- |
| Content (scroll view) | `blau.root` | | |
| Empty state | `blau.mainScreen.empty` | | |
| Settings | `blau.settings.open` | Settings | |
| Record | `blau.record` | Start Conversation / End Conversation | See [Record](#record) |
| "You're muted" | `blau.record.mutedHint`, Resume `blau.record.mutedHint.resume` | | |

The identifiers live in `MainScreenAccessibility`.

### Record

The record button (#41) is the main screen's primary control. It starts and
ends a conversation, pauses listening, and shows where the conversation is.

| State | Face | Tint | VoiceOver value |
| ----- | ---- | ---- | --------------- |
| `idle` | `mic.fill` | accent | Not listening |
| `connecting` | spinner (ellipsis with Reduce Motion) | accent | Connecting |
| `listening` | `stop.fill` in a ring that follows the microphone level | red | Listening (", connecting to Grok" while the session opens) |
| `agentSpeaking` | `speaker.wave.2.fill` in a ring and halo that follow Grok's level | red | Grok is speaking |
| `paused` | `mic.slash.fill` | gray | Paused, microphone muted |
| `stopping` | spinner | red | Ending |
| `error` | `exclamationmark.triangle.fill` | orange | Couldn't start / Lost the connection to Grok / Microphone in use by another app / ... |

- **Tap** starts a conversation (also after a failed start) and ends a
  running one, whatever it is doing. Taps while a start or stop is in flight
  are ignored. The label says what a tap does: Start Conversation or End
  Conversation.
- **Touch and hold** while a conversation runs opens a menu (a `Menu` whose
  primary action is the tap): Pause Listening / Resume Listening and End
  Conversation. VoiceOver gets Pause / Resume as custom actions.
- **Pause listening** mutes the microphone inside voice processing
  (`MicrophoneMute`, [audio.md](audio.md#pause-listening-41)): the session,
  the Live Activity and Grok's playback go on, nothing said reaches ASR or
  Grok. If the user talks while paused, `setMutedSpeechActivityEventListener`
  reports it and a "You're muted" capsule with a Resume button appears above
  the button (VoiceOver announces it). It hides 3 s after they stop talking,
  or at once on resume.
- **Haptics** (`sensoryFeedback`): `.start` when the conversation is
  listening, `.stop` on End, a light impact on pause and resume, `.error`
  when a start fails (with an alert saying why).
- **Reduce Motion**: the ring keeps its size and only its opacity follows
  the level; the spinner becomes a static ellipsis; the hint fades instead
  of sliding.

How it is put together:

- `RecordButtonModel` (`BlauRealtime/Control`, unit-tested on macOS) holds
  the logic: its own phase (idle, starting, running, stopping), the
  session's `ConversationStatus`, the derived `RecordButtonState`, smoothed
  levels (`LevelMeter`, attack 40 ms, release 250 ms), the hint and the
  haptic requests. `run()` (the scaffold's `.task`) follows the session, so
  what ends or starts a conversation without the button (the Live
  Activity's Stop, an interruption, a dropped connection, the debug Voice
  Loop screen) shows at once; levels are only followed while a conversation
  runs and the scene is active.
- `ConversationSession` is what it drives. The live app's
  `VoiceLoopSession` adapts `VoiceLoop` (#36) and its `ConversationAudio`:
  status from the voice loop's phase and turn snapshot (`Observations`) and
  the keeper's `updates()`, input levels from the capture hub, output
  levels from the player, the mute and its speech reports from
  `MicrophoneMute`. Previews and UI tests use `FakeConversationSession`.
- `RecordButtonState` puts audio problems first (nothing is heard), then a
  lost connection, then the user's pause (a muted microphone never shows as
  listening), then who is talking. The microphone counts as listening while
  Grok is still connecting: utterances are queued.
- **Start latency.** The `session.start` signpost spans the tap to the first
  moment the button shows listening ([performance.md](performance.md)), also
  logged (`Log.ui`) and kept in `lastStartLatency`. The target is under
  500 ms with the models warm. `LiveVoicePipeline.start` loads Silero and
  Parakeet while the audio session comes up, so the start costs the slower
  of the two rather than their sum. Measuring it needs an iPhone: profile
  with the Blau Instruments template and read `session.start`.

### Tests

- `RecordButtonModelTests` and `RecordButtonStateTests` (BlauKit,
  `swift test`): taps, ignored taps, failures and retries, pause and resume,
  the muted hint, following the session, levels, haptics and the
  `session.start` interval.
- `BlauTests/RecordButtonSnapshotTests.swift`: a snapshot of the button's
  face in every state, the ring at both extremes and with Reduce Motion
  (references in `BlauTests/__Snapshots__/`, per iOS major version; record
  with `TEST_RUNNER_BLAU_RECORD_SNAPSHOTS=1`, see `SnapshotAssertion`).
- `BlauTests/RecordButtonTests.swift`: VoiceOver labels, values and hints
  per state, glyphs, tints, haptics, and the live and fake wiring.
- `BlauUITests/MainScreenUITests.swift`: finds both controls by identifier
  and checks Settings is in the left quarter and Record in the right quarter
  of the window, on one row in the bottom quarter and clear of the
  speech-model setup card, in portrait, in landscape and at the largest
  accessibility text size; that the content runs under the
  bar; that Settings opens; that Record starts and ends a conversation; and
  that touch and hold pauses and resumes listening. Run it on the
  smallest and the largest iPhone to cover the sizes:

```sh
make generate
xcrun simctl create blau-se "iPhone SE (3rd generation)" com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl create blau-max "iPhone 17 Pro Max" com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcodebuild test -project Blau.xcodeproj -scheme Blau -testPlan Blau \
  -only-testing:BlauUITests/MainScreenUITests -derivedDataPath .build/DerivedData \
  -destination 'id=<udid>' CODE_SIGNING_ALLOWED=NO
```
