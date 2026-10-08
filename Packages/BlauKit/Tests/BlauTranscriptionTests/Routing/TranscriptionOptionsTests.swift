import Foundation
import Testing

@testable import BlauTranscription

/// Settings → Transcription: the second pass and the language, beside the
/// engine toggle `TranscriptionSettingsTests` covers.
@Suite("Transcription options")
@MainActor
struct TranscriptionOptionsTests {
    private func makeSettings(
        preference: TranscriptionEnginePreference = .automatic, options: TranscriptionOptions = .default
    ) -> (TranscriptionSettings, InMemoryTranscriptionOptionsStore) {
        let store = InMemoryTranscriptionOptionsStore(options)
        let settings = TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(preference), options: store,
            availability: { .installed(locale: "en_US") })
        return (settings, store)
    }

    @Test func theSecondPassIsOnByDefaultAndSaved() {
        let (settings, store) = makeSettings()
        #expect(settings.refinesWithSecondPass)
        #expect(settings.isSecondPassEnabled())

        settings.refinesWithSecondPass = false
        #expect(!settings.isSecondPassEnabled())
        #expect(store.load().refinesWithSecondPass == false)

        // A new model reads what was saved.
        let reloaded = TranscriptionSettings(store: InMemoryTranscriptionPreferencesStore(), options: store)
        #expect(!reloaded.refinesWithSecondPass)
        #expect(!reloaded.isSecondPassEnabled())
    }

    @Test func theSecondPassSwitchIsReadableOffTheMainActor() async {
        let (settings, _) = makeSettings()
        settings.refinesWithSecondPass = false
        let isEnabled: @Sendable () -> Bool = { [settings] in settings.isSecondPassEnabled() }
        let value = await Task.detached { isEnabled() }.value
        #expect(value == false)
    }

    @Test func englishKeepsTheUsersEngine() {
        #expect(!TranscriptionLanguage.automatic.requiresAppleEngine)
        #expect(!TranscriptionLanguage.locale("en_GB").requiresAppleEngine)
        #expect(TranscriptionLanguage.locale("fr_FR").requiresAppleEngine)
        #expect(TranscriptionLanguage.locale("de_DE").locale.identifier == "de_DE")
        #expect(TranscriptionLanguage.automatic.locale == .current)
    }

    @Test func anotherLanguageSwitchesTheRouterToApple() async {
        let (settings, store) = makeSettings()
        var changes = settings.preferenceChanges().makeAsyncIterator()
        #expect(await changes.next() == .automatic)

        settings.language = .locale("fr_FR")
        #expect(settings.effectiveEnginePreference == .apple)
        #expect(settings.enginePreference == .automatic)  // The user's own choice is kept.
        #expect(store.load().language == .locale("fr_FR"))
        #expect(await changes.next() == .apple)

        // Forcing Apple while French already uses it publishes nothing...
        settings.forcesAppleEngine = true
        settings.forcesAppleEngine = false
        // ...and going back to English restores the user's choice.
        settings.language = .locale("en_US")
        #expect(await changes.next() == .automatic)
    }

    @Test func aSavedLanguageAppliesAtLaunch() async {
        let (settings, _) = makeSettings(options: TranscriptionOptions(language: .locale("es_ES")))
        var changes = settings.preferenceChanges().makeAsyncIterator()
        #expect(await changes.next() == .apple)
    }

    @Test func changingTheLanguageForgetsTheOldAvailability() async {
        let (settings, _) = makeSettings()
        await settings.refreshAvailability()
        #expect(settings.appleAvailability != nil)
        settings.language = .locale("it_IT")
        #expect(settings.appleAvailability == nil)
    }

    @Test func aSlowCheckForTheOldLanguageIsDropped() async {
        // The check waits until the test releases it, so the language can
        // change while it is in flight.
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let settings = TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(), options: InMemoryTranscriptionOptionsStore(),
            availability: {
                startedContinuation.yield()
                for await _ in release { break }
                return .installed(locale: "en_US")
            })

        let check = Task { await settings.refreshAvailability() }
        for await _ in started { break }
        settings.language = .locale("fr_FR")
        releaseContinuation.yield()
        await check.value
        #expect(settings.appleAvailability == nil)

        // A check for the current language still lands.
        let current = Task { await settings.refreshAvailability() }
        releaseContinuation.yield()
        await current.value
        #expect(settings.appleAvailability == .installed(locale: "en_US"))
    }

    @Test func optionsDecodeLeniently() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(TranscriptionOptions.self, from: Data("{}".utf8)) == .default)
        let garbled = Data(#"{"second_pass":"yes","language":42}"#.utf8)
        #expect(try decoder.decode(TranscriptionOptions.self, from: garbled) == .default)
        let options = TranscriptionOptions(refinesWithSecondPass: false, language: .locale("ja_JP"))
        #expect(try decoder.decode(TranscriptionOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test func userDefaultsKeepsTheOptions() {
        let suite = "blau.tests.transcription.options.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTranscriptionOptionsStore(suiteName: suite)
        #expect(store.load() == .default)
        let options = TranscriptionOptions(refinesWithSecondPass: false, language: .locale("pt_BR"))
        store.save(options)
        #expect(UserDefaultsTranscriptionOptionsStore(suiteName: suite).load() == options)
        store.save(.default)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "blau.transcription.options") == nil)
    }
}
