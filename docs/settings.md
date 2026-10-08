# Settings

All of Blau's configuration lives in one sheet, opened from the main
screen's bottom-left button (#43). The sources are in `Blau/Settings/`.

## Presentation

```swift
ToolbarItem(placement: .bottomBar) { SettingsButton { isShowingSettings = true } }
    .matchedTransitionSource(id: SettingsView.transitionSourceID, in: settingsTransition)
...
.sheet(isPresented: $isShowingSettings) {
    SettingsView()
        .navigationTransition(.zoom(sourceID: SettingsView.transitionSourceID, in: settingsTransition))
}
```

- The sheet zooms out of the Settings button. `ToolbarContent` got
  `matchedTransitionSource(id:in:)` in iOS 26, so the source is the toolbar
  item itself; no `#available` check is needed at the iOS 26 deployment
  target.
- `SettingsView` sets `.presentationDetents([.medium, .large], selection:)`.
  The root list opens at the medium detent, so the conversation stays
  visible above it. Opening a pane grows the sheet to the large detent (a
  pane is a page of controls); the user can drag between the two.
- The root is a `NavigationStack` over a list of panes, one row per
  `SettingsPane`, each with a one-line summary (`SettingsSummary`): whether
  the xAI key is connected, the voice and speed, the voiceprint's status,
  the engine and language, the iCloud sync state, the models' size on disk,
  and whether the performance HUD is on.

## Panes

| Pane | View | What it edits | Stored in | Takes effect |
| ---- | ---- | ------------- | --------- | ------------ |
| xAI Account | `XAIAccountSettingsView` | API key (add, replace, remove), **Test Connection** (`XAIAccount.testConnection()`), this month's usage and cost estimate | Keychain, synced through iCloud Keychain (#33) | At once; cached realtime tokens and voice previews are dropped when the key changes |
| Voice | `VoiceSettingsView` | Voice with a spoken **preview**, speaking speed, reasoning effort (Think Before Answering), web and X search | `UserDefaults` (`RealtimeVoiceSettingsStore`) | The next `session.update`, i.e. Grok's next reply |
| Voice ID | `VoiceIDSettingsView` | Status of the voiceprint, **enroll / re-enroll** (the guided capture, `VoiceEnrollmentView`), **Add This iPhone's Microphone** (the 15 s top-up), **Delete Voiceprint**, the enrolled microphones, **sensitivity** | Voiceprint: SwiftData, synced; sensitivity: `UserDefaults` (`blau.voiceID.sensitivity`), per device | Enrollment and deletion at once, and on the other devices as iCloud syncs; sensitivity at the next segment the gate scores (`VoiceIDSettings.currentConfig()`) |
| Transcription | `TranscriptionSettingsView` | Engine (always Apple's), second pass, language | `UserDefaults` (`blau.transcription.engine`, `blau.transcription.options`), per device | Engine and language at the next utterance boundary (`preferenceChanges()`); second pass per utterance (`isSecondPassEnabled()`) |
| Knowledge | `KnowledgeSettingsView` | The knowledge base (#65, [knowledge-base.md](knowledge-base.md)): **About Me**, **Company**, **Notes** and **Collections** (paste a list of questions); what Blau learned (people, facts), whether Grok may search it, **Learn From Conversations** and **What Blau Learned** (`MemorySettingsSection`, #66, [memory-extraction.md](memory-extraction.md)), and the on-device **search index** (`MemoryIndexSettingsSection`: status, progress, **Rebuild Index**, see [memory-indexer.md](memory-indexer.md)) | SwiftData, synced; the index is derived per device | Rebuild at once |
| iCloud | `ICloudSettingsView` | Sync status, account, last sync; **Markdown Export** to iCloud Drive → Blau (`MarkdownExportSettingsSection`, #78, [export.md](export.md)); **Export Conversations** as one Markdown file through the share sheet | Export settings: `UserDefaults` (see export.md) | Export Now at once; automatic export as conversations change |
| Speech Models | `SpeechModelSettingsView` | Wi-Fi only, extra models, per-model download and delete, disk usage | `UserDefaults` (`blau.models.preferences`) | At once |
| Privacy & Data | `PrivacySettingsView` | Where data lives; delete conversations, the knowledge base, the voiceprint, or everything | – | At once, and on the user's other devices as iCloud syncs the deletions |
| Developer | `DeveloperSettingsView` | Performance HUD (`PerformanceHUDToggle`, #71, every build), feature flags, MetricKit diagnostics, **Export Logs** | HUD: `UserDefaults` (`blau.performanceHUD.*`); flag overrides: `UserDefaults`, DEBUG builds only | At once: the HUD appears over the main screen as soon as it is on |

DEBUG UI-test launches (`BLAU_UI_TEST_XAI`) keep every `UserDefaults`
setting in the `blau.uitests` suite, so UI tests never change the
developer's own choices. Fake environments (previews, unit tests,
`BLAU_APP_ENVIRONMENT=ui-test`) keep them in memory.

## Details

**Test Connection** re-runs the unbilled key checks against the stored key
(`GET /v1/api-key`, then minting a throwaway realtime client secret) and
reports the result under the button. The key is never removed by a failed
test. Only a key or account problem (invalid, switched off, no credits,
not permitted) marks the key unverified; a transient failure (offline, a
timeout, rate limiting, a server error) is reported under the button but
leaves a verified key verified.

**Usage and cost** (`RealtimeUsageEstimator`, BlauRealtime) counts this
calendar month from the stored transcript: Grok's speaking time (each agent
utterance's length is the audio it sent) and one text input per committed
user utterance, priced at `RealtimePricing.grokVoice` (the rates the performance HUD uses too: $0.08 per
minute of audio, $0.004 per text input, xAI's pricing page in October
2026). It is an estimate; replies interrupted before they were stored,
merged turns, searches and previews make the bill differ. The footer points
to console.x.ai for the exact figure.

**Voice preview** (`RealtimeVoicePreviewer`, BlauRealtime) asks xAI's text
to speech (`POST /v1/tts`, `voice_id`, `language: "en"`, MP3 at 24 kHz) for
one sentence in the chosen voice at the chosen speed, caches it per voice
and speed for the session, and `VoicePreviewPlayer` plays it with
`AVAudioPlayer` in the `.playback` category. Realtime and TTS voices share
their ids. A preview is refused while the microphone is capturing, so it
never fights the conversation for the audio session. Each new sample is a
small TTS request on the user's xAI bill, which the footer says. Starting
another preview, or picking another voice, cancels the one in flight and
clears an earlier failure message.

**Voice ID sensitivity** (`VoiceIDSensitivity`, BlauVoiceID) is a slider
from Relaxed (0) through Balanced (0.5, the calibrated thresholds) to
Strict (1), in steps of 0.25. It moves both the accept and the reject
threshold of both score windows by up to ±0.06
(`VoiceIDConfig.adjusted(for:)`).

**Voice enrollment** (#46, [voice-id.md](voice-id.md#enrollment-46)) opens
full screen: four prompts of about 5 s each, recorded through the
conversation's voice-processing capture, each clip checked for talking
time, background noise and consistency with the others. Re-enroll replaces
the voiceprint on every device once the new one is saved. When the synced
voiceprint has no set from this device model, **Add This iPhone's
Microphone** records a 15 s top-up. **Delete Voiceprint** asks first and
deletes through `DataEraser`, like Privacy & Data. Enrolling and deleting
are refused while a conversation is running. A voiceprint from another
embedding model shows "Re-enroll needed".

**Second pass and language** (`TranscriptionOptions`, BlauTranscription).
Parakeet's realtime model understands English only, so choosing any other
language makes `effectiveEnginePreference` Apple's engine (the user's own
engine choice is kept for when they switch back), and the Apple engine's
availability is checked for that language. The language list is Apple's
`SpeechTranscriber.supportedLocales` on the device. An availability check
that finishes after the language changed is dropped, so the old language's
result never shows for the new one.

**Export Conversations** (`ConversationExporter`, BlauPersistence) writes
every conversation, oldest first, as one Markdown file: a heading per
conversation (its title or its date), its time span, a heading per topic,
and a paragraph per committed utterance led by **You**, **Grok** or
**Blau**. Partials are left out. The conversations are read on the main
context and formatted and written off the main actor; the file is a
snapshot, so **Export Again** makes a fresh one. It lives in the app's
temporary directory (`ConversationExportFiles`): each export replaces the
last, and deleting conversations in Privacy & Data removes it. The Markdown Export section above it
keeps one file per conversation in iCloud Drive → Blau instead (#78,
[export.md](export.md)).

**Delete data** (`DataEraser`, BlauPersistence) fetches and deletes every
record of the chosen models one by one, then saves, so each deletion lands
in the persistent history and the CloudKit mirror removes it from iCloud
and the user's other devices (a batch delete would bypass that). Each
action asks first, with a count. Nothing is deleted while a conversation is
recording.

**Knowledge** opens the knowledge base (#65, [knowledge-base.md](knowledge-base.md)):
About Me, Company, Notes and Collections. Its rows show the About Me and
company names and the note and collection counts, and below them the people
and things and current facts learned from conversations, all counted with
`ModelContext.fetchCount` when the pane opens and after every
`ModelContext.didSave`, rather than loading every record through `@Query`
just to count it.

**Export Logs** (`LogExporter`, BlauTelemetry) reads the last hour of
Blau's subsystem from the running process's unified log (`OSLogStore`,
`.currentProcessIdentifier`) into a text file for the share sheet. Values
logged as `.private` (what the user said) come back redacted.

## Tests

- `swift test` in `Packages/BlauKit`: `XAIAccountConnectionTests`,
  `RealtimeVoicePreviewTests`, `RealtimeUsageEstimateTests`,
  `VoiceIDSensitivityTests`, `TranscriptionOptionsTests`,
  `DataMaintenanceTests` (erase and export on an in-memory store) and
  `LogExportTests`. All hermetic: scripted HTTP, in-memory stores.
- `BlauTests/SettingsAppTests.swift`: the panes, the root summaries, the
  wording of the destructive actions, and that the settings the panes edit
  are the ones the pipeline reads.
- `BlauUITests/SettingsUITests.swift`: the sheet opens from the bottom-left
  button at the medium detent; every pane opens; the performance HUD shows
  and hides as it is toggled; the voice ID sensitivity and the second pass
  persist across launches; Test Connection; export opens the share sheet;
  deleting asks first. `XCTestCase+Settings.swift` has
  `openSettings(in:)` and `openSettingsPane(_:in:)` for the other UI tests.
