import BlauCore
import BlauTranscription
import BlauVoiceID
import Foundation
import Testing

@testable import Blau

/// Settings → Voice ID → Languages (#50): the defaults, the wording and the
/// settings the gate's language filter reads.
@Suite("Language filter settings in the app")
@MainActor
struct LanguageFilterAppTests {
    static let english = Locale(identifier: "en_US")
    static let french = SpokenLanguage(code: "fr")!
    static let german = SpokenLanguage(code: "de")!

    /// The default never filters out the language Blau transcribes:
    /// English for Parakeet (Automatic), or the language chosen in
    /// Settings → Transcription; plus the iPhone's languages.
    @Test func theDefaultIsTheIPhonesLanguagesAndTheTranscribedOne() {
        #expect(
            LanguageFilterSettings.defaultLanguages(transcribing: .automatic, preferred: ["de-DE"])
                == [.english, Self.german])
        #expect(
            LanguageFilterSettings.defaultLanguages(transcribing: .locale("fr_FR"), preferred: ["fr-FR"])
                == [Self.french])
        #expect(
            LanguageFilterSettings.defaultLanguages(transcribing: .automatic, preferred: ["en-US", "fr-CA", "xx"])
                == [.english, Self.french])
    }

    @Test func theAppSettingsPersistAndFollowTheTranscriptionLanguage() {
        let suite = "blau.tests.languages.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UserDefaultsTranscriptionOptionsStore(suiteName: suite).save(TranscriptionOptions(language: .locale("de_DE")))

        let first = LanguageFilterSettings.make(suiteName: suite)
        #expect(first.usesDefaultLanguages)
        #expect(first.allowedLanguages.contains(Self.german))
        first.setAllowed(Self.french, true)
        first.isEnabled = false

        let second = LanguageFilterSettings.make(suiteName: suite)
        #expect(!second.isEnabled)
        #expect(second.allowedLanguages.contains(Self.french))
        #expect(second.currentAllowedLanguages() == nil)
    }

    @Test func theEnvironmentsVoiceIDSettingsCarryTheFilter() {
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(environment.voiceIDSettings.languageFilter.isEnabled)
        #expect(environment.voiceIDSettings.languageFilter.currentAllowedLanguages()?.isEmpty == false)
    }

    @Test func summaries() {
        #expect(LanguageFilterSection.summary([.english], locale: Self.english) == "English")
        #expect(LanguageFilterSection.summary([.english, Self.french], locale: Self.english) == "English and French")
        #expect(
            LanguageFilterSection.summary(
                [.english, Self.french, Self.german, SpokenLanguage(code: "es")!], locale: Self.english)
                == "English, French and 2 more")
    }

    @Test func theModelStatusSaysWhyTheFilterIsntRunning() {
        #expect(LanguageFilterSection.modelStatus(.ready) == nil)
        #expect(LanguageFilterSection.modelStatus(.preparing) == nil)
        #expect(LanguageFilterSection.modelStatus(.notDownloaded) != nil)
        #expect(LanguageFilterSection.modelStatus(.downloading(bytesReceived: 1, totalBytes: 2)) != nil)
        #expect(LanguageFilterSection.modelStatus(.failed(.loadFailed("x")))?.contains("Speech Models") == true)
    }

    @Test func theLanguageListIsSortedAndSearchable() {
        let all = AllowedLanguagesView.languages(matching: "", locale: Self.english)
        #expect(all.count == 107)
        #expect(all.first?.localizedName(in: Self.english) == "Abkhazian")
        #expect(AllowedLanguagesView.languages(matching: "fren", locale: Self.english) == [Self.french])
        #expect(AllowedLanguagesView.languages(matching: "  ", locale: Self.english).count == 107)
    }
}
