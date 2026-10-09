# Onboarding

Onboarding (#44) takes a fresh install to a working conversation. It runs
at the first launch, resumes where it stopped if it is interrupted, and
comes back later if a conversation's requirements go missing.

## Steps

| Step | Page | Done when | Requirement |
| ---- | ---- | --------- | ----------- |
| `welcome` | What Blau is and what setup needs | the user taps Get Started | |
| `xaiAccount` | Paste the xAI API key (`XAIKeyOnboardingStep`). Connect checks it with xAI (`GET /v1/api-key`) before storing it in the iCloud Keychain (#33) | a key is stored | yes |
| `microphone` | Allow Microphone shows the system prompt. If access is denied, the page explains how to fix it and has **Open Settings** (`UIApplication.openSettingsURLString`) | access is granted | yes |
| `speechModels` | Model size, a notice that downloads use Wi-Fi only, and live progress (`SpeechModelSetupView`, which offers cellular data while waiting for Wi-Fi and Try Again after a failure) | the required models are ready | yes |
| `iCloud` | iCloud sync status (`SyncStatusPresentation`), with Open Settings when the user can fix it | sync is running | |
| `voiceEnrollment` | Voice ID. The guided capture is #46 (M2), so for now the page says enrollment is coming and moves on | a voiceprint for the current embedding model is stored, possibly synced from another device | |
| `aboutYou` | "Tell Blau about you": an optional note saved to the knowledge base as its `.profile` document (`AboutYouDocument`; Settings → Knowledge → About Me edits the same kind of document). `ProfileComposer` pins it verbatim into the session instructions ("In the user's own words", see [memory-profile.md](memory-profile.md)), and the memory indexer embeds it like any other page, so `search_memory` finds it too | a non-empty profile document exists | |
| `ready` | How to start a conversation, plus anything still missing or downloading | the user taps Start Using Blau | |

Every step can be skipped (Skip for Now / Not Now / Continue While It
Downloads), so onboarding never traps the user. The model download keeps
running in the background, and the main screen's setup card shows its
progress after onboarding ends.

## How it works

- **`OnboardingFlow`** (`BlauCore/Onboarding`) holds the state and is tested
  on macOS. It decides which step is on screen and what comes next. It reads
  an `OnboardingPrerequisites` snapshot each time it decides, and saves
  `OnboardingProgress` after every step.
- **Prerequisites.** Each module maps its own state to an
  `OnboardingRequirement` (`unknown`, `missing`, `inProgress`, `satisfied`):
  `XAIAccount.Status`, `MicrophonePermission`, `ModelSetupStatus`, `SyncState`
  and `AboutYouDocument.onboardingRequirement(in:)`. The voiceprint check uses
  `VoiceIDStatus`. `unknown` (still checking) never counts as missing.
- **`OnboardingController`** (`Blau/Onboarding`) connects the flow to the
  live services, requests microphone permission, and logs each transition to
  `Log.ui`. It lives on `AppEnvironment.onboarding`.
- **`RootView`** shows `OnboardingView` *in place of* the main screen while
  the flow is presented. Because it is not a modal, it never competes with the
  main screen's sheets for presentation.

### Setup (first run)

Setup walks the steps in order and skips any step that is already
satisfied when the flow reaches it. For example, on a second device the key
arrives through iCloud Keychain and the voiceprint through iCloud. A step in
an `unknown` state is shown, and its page follows the live state.

### Resuming

Progress is saved in `UserDefaults` (`blau.onboarding.progress`) after every
step. It is per device, because each device needs its own microphone
permission and models. Relaunching mid-setup reopens the step that was on
screen, never the welcome page. This matters for the microphone: iOS
terminates an app when one of its privacy settings changes in the Settings
app, so after the user turns the microphone on, Blau relaunches on the
microphone page, which now shows that access is allowed.

### Coming back (recovery)

After setup finishes, `checkPrerequisites()` runs at launch (once the key and
the installed models have been read) and on every return to the foreground
(after the Keychain has been re-read). The app's first activation arrives
while launch is still reading the key and the models, so it only re-reads
the microphone permission; the check at the end of `AppEnvironment.start()`
covers it. If a requirement is `missing`, onboarding comes back with only the
missing steps: no key, microphone access not granted, or a required model
that isn't scheduled or that failed. A download that is running or waiting
is not missing. Recovery:

- picks each next step from every missing requirement, not only the ones
  after the step on screen, so a requirement found missing after recovery
  opened is still asked for. A presentation shows each step once;
- never interrupts a running conversation;
- has **Not Now** in its top bar. A requirement the user skips or dismisses
  isn't asked for again until the next launch;
- doesn't change the saved progress.

## Launches that show it

`OnboardingLaunch` decides per launch:

| Launch | Onboarding |
| ------ | ---------- |
| The app, run by the user or from Xcode (`live`) | On, with progress in `UserDefaults.standard` |
| Previews, hosted unit tests, `ui-test` launches, and `live` launches with fixture models or any `BLAU_UI_TEST_*` stub | Off, so tests that don't care about onboarding open on the main screen |
| `BLAU_UI_TEST_ONBOARDING=fresh` / `resume` / `finished` (DEBUG builds) | On, with progress in the `blau.uitests` suite: start over, keep the previous launch's progress, or start with setup finished (to test recovery) |

`BLAU_UI_TEST_MICROPHONE` (DEBUG builds) replaces the system permission with
`StubMicrophonePermission`: `granted`, `denied`, `undetermined` (the prompt
allows) or `undetermined-deny` (the prompt denies). The live audio pipeline
still uses the system permission.

The DEBUG menu's **Onboarding → Show Onboarding** starts setup over.

## Tests

- `BlauCoreTests/OnboardingFlowTests.swift`: step order, skipping finished
  steps, the next step from the latest prerequisites, Back, resuming after an
  interruption, progress persistence and forward compatibility, and recovery
  (only missing requirements, including one before the step on screen, never
  during a conversation, Not Now postponing until the next launch, the saved
  progress left alone).
- `MicrophoneOnboardingTests`, `ModelSetupOnboardingTests` (including a fresh
  install and a deletion on the real `ModelManager` over fixture models),
  `XAIAccountOnboardingTests`, `AboutYouDocumentTests` and
  `SyncStateOnboardingTests` cover the per-module mappings (`swift test`).
- `BlauTests/OnboardingAppTests.swift`: which launches show onboarding, the
  stubs, prerequisites read from the real services, the microphone prompt and
  a denial fixed in Settings, recovery after the key is removed, no recovery
  from the launch-time activation before the key is read, and the store read
  once per step rather than on every render.
- `BlauUITests/OnboardingUITests.swift`: a fresh install through every step
  to a conversation that starts and listens; a denied microphone opens
  Settings.app; relaunching mid-setup resumes on the same step; a finished
  setup comes back for missing requirements and Not Now leaves it.

```sh
make generate
xcrun simctl create blau-onboarding "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcodebuild test -project Blau.xcodeproj -scheme Blau -testPlan Blau \
  -only-testing:BlauUITests/OnboardingUITests -derivedDataPath .build/DerivedData \
  -destination 'id=<udid>' CODE_SIGNING_ALLOWED=NO
```

## On-device checks

These need a real iPhone with a signed build, so they are checked by hand:

| Check | Result |
| ----- | ------ |
| Fresh install: the real microphone prompt, real model download over Wi-Fi, a real xAI key, then a first conversation with Grok | pending |
| Deny the microphone, Open Settings, turn it on, return: Blau relaunches on the microphone page showing access allowed | pending |
| On cellular with Wi-Fi only: the models page waits and Download Using Cellular Data starts the download | pending |
| Second device on the same Apple ID: the key step is skipped (iCloud Keychain) | pending |
| Remove the key in Settings, background and reopen Blau: onboarding comes back on the key step | pending |
