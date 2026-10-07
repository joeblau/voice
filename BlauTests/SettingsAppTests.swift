import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTranscription
import BlauVoiceID
import Foundation
import Testing

@testable import Blau

/// The settings sheet (#43): its panes, the root rows' summaries, the
/// wording of the destructive actions, and the services the panes edit
/// being the ones the pipeline reads.
@Suite("Settings")
@MainActor
struct SettingsAppTests {
    // MARK: Panes

    @Test func everyPaneIsInExactlyOneGroup() {
        let grouped = SettingsPane.groups.flatMap { $0 }
        #expect(grouped.count == SettingsPane.allCases.count)
        #expect(Set(grouped) == Set(SettingsPane.allCases))
    }

    @Test func panesHaveDistinctTitlesAndIdentifiers() {
        let panes = SettingsPane.allCases
        #expect(Set(panes.map(\.title)).count == panes.count)
        #expect(Set(panes.map(\.identifier)).count == panes.count)
        #expect(panes.allSatisfy { !$0.systemImage.isEmpty })
        // UI tests that open Speech Models through the old link keep working.
        #expect(SettingsPane.models.identifier == SpeechModelSettingsView.Identifier.link)
        #expect(SettingsPane.voice.identifier == "settings.pane.voice")
    }

    // MARK: Summaries

    @Test func accountSummary() async throws {
        #expect(SettingsSummary.account(.unknown) == "Checking…")
        #expect(SettingsSummary.account(.noKey) == "Not connected")
        // Assembled at runtime so the repository never holds a key-shaped literal.
        let key = try XAIAPIKey(validating: "xai-" + String(repeating: "Settings0Key", count: 4) + "a1b2")
        let account = XAIAccount.preview(key: key)
        await account.load()
        #expect(SettingsSummary.account(account.status) == "Connected")
        #expect(SettingsSummary.account(.unavailable(.corruptItem)) == "Needs a new key")
        #expect(SettingsSummary.account(.unavailable(.locked)) == "Unavailable")
    }

    @Test func voiceSummary() {
        let english = Locale(identifier: "en_US")
        #expect(SettingsSummary.voice(.default, locale: english) == "Eve, 1.0×")
        #expect(SettingsSummary.voice(RealtimeVoiceSettings(voice: .rex, speed: 1.25), locale: english) == "Rex, 1.25×")
    }

    @Test func transcriptionSummary() {
        let english = Locale(identifier: "en_US")
        #expect(SettingsSummary.transcription(engine: .automatic, language: .automatic, locale: english) == "Parakeet")
        #expect(SettingsSummary.transcription(engine: .apple, language: .automatic, locale: english) == "Apple Speech")
        #expect(
            SettingsSummary.transcription(engine: .apple, language: .locale("fr_FR"), locale: english)
                == "Apple Speech · French")
    }

    @Test func versionSummaryReadsTheBundle() {
        #expect(SettingsSummary.version().hasPrefix("Blau "))
    }

    // MARK: Voice ID

    @Test func voiceIDStatus() {
        let current = VoiceIDConfig.calibrated.modelIdentifier
        #expect(VoiceIDStatus(embeddingModelVersion: nil).kind == .notEnrolled)
        #expect(VoiceIDStatus(embeddingModelVersion: current).kind == .enrolled)
        #expect(VoiceIDStatus(embeddingModelVersion: "older-model").kind == .needsReenrollment)
        #expect(VoiceIDStatus(profile: nil).title == "Not enrolled")
    }

    @Test func sensitivityNames() {
        #expect(VoiceIDSettingsView.levelName(0) == "Relaxed")
        #expect(VoiceIDSettingsView.levelName(0.5) == "Balanced")
        #expect(VoiceIDSettingsView.levelName(0.75) == "Somewhat strict")
        #expect(VoiceIDSettingsView.levelName(1) == "Strict")
    }

    // MARK: Privacy

    @Test func deletionWording() {
        #expect(PrivacySettingsView.buttonTitle(.everything) == "Delete All Data…")
        #expect(
            PrivacySettingsView.confirmationMessage(.conversations, count: 3)
                == "This deletes 3 conversations from this iPhone, iCloud and your other devices.")
        #expect(PrivacySettingsView.confirmationMessage(.voiceprint, count: 1).hasSuffix("enroll again for Voice ID."))
        var summary = DataEraseSummary()
        summary.conversations = 1
        #expect(PrivacySettingsView.resultMessage(.conversations, summary: summary) == "Deleted 1 conversation.")
    }

    // MARK: Wiring

    @Test func theEnvironmentHoldsTheSettingsThePipelineReads() async {
        let environment = AppEnvironment.fake(kind: .unitTest)
        // Voice ID sensitivity: what the slider writes is what the gate reads.
        environment.voiceIDSettings.level = 1
        let config = await Task.detached { [settings = environment.voiceIDSettings] in
            settings.currentConfig()
        }.value
        #expect(config == VoiceIDConfig.calibrated.adjusted(for: VoiceIDSensitivity(level: 1)))

        // The second pass toggle is read per utterance, off the main actor.
        environment.transcriptionSettings.refinesWithSecondPass = false
        #expect(!environment.transcriptionSettings.isSecondPassEnabled())
    }

    @Test func voiceIDSensitivityPersistsAcrossLaunches() {
        let suite = "blau.tests.voiceID.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = VoiceIDSettings(store: UserDefaultsVoiceIDSensitivityStore(suiteName: suite))
        first.level = 0.25
        let second = VoiceIDSettings(store: UserDefaultsVoiceIDSensitivityStore(suiteName: suite))
        #expect(second.level == 0.25)
    }

    @Test func thePerformanceHUDFollowsTheFlag() {
        // Settings → Developer's toggle writes the flag the HUD overlay reads.
        let flags = FeatureFlags.inMemory()
        #expect(!flags.isEnabled(.perfHUD))
        #expect(flags.setOverride(true, for: .perfHUD))
        #expect(flags.isEnabled(.perfHUD))
    }

    @Test func usageFormatting() {
        #expect(UsageEstimateSection.dollars(Decimal(string: "0.168")!).contains("0.168"))
        #expect(UsageEstimateSection.minutes(0).isEmpty == false)
    }
}
