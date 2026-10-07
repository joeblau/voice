import BlauRealtime
import Foundation
import Testing

@testable import Blau

/// The app's wiring of Settings → Voice to the session configurator (#35):
/// what the Settings section writes is what the next `session.update`
/// carries, and it survives a relaunch.
@Suite("Voice settings in the app")
@MainActor
struct VoiceSettingsAppTests {
    @Test func settingsChangesReachTheNextSessionUpdate() async throws {
        let suite = "blau.tests.voice.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let services = RealtimeSessionServices(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))

        let before = await services.configurator.currentSession()
        #expect(before.voice == "eve")
        #expect(before.audio?.output?.speed == 1.0)
        #expect(before.turnDetection == .manual)

        // What VoiceSettingsSection's picker and slider do.
        services.voiceSettings.voice = .ara
        services.voiceSettings.speed = 1.2

        let after = await services.configurator.currentSession()
        #expect(after.voice == "ara")
        #expect(after.audio?.output?.speed == 1.2)

        // A relaunch reads the saved settings.
        let relaunched = RealtimeSessionServices(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        #expect(relaunched.voiceSettings.voice == .ara)
        #expect(await relaunched.configurator.currentSession().audio?.output?.speed == 1.2)
    }

    @Test func speedLabels() {
        let english = Locale(identifier: "en_US")
        #expect(VoiceSettingsSection.speedLabel(1.0, locale: english) == "1.0×")
        #expect(VoiceSettingsSection.speedLabel(1.25, locale: english) == "1.25×")
        #expect(VoiceSettingsSection.speedLabel(0.7, locale: english) == "0.7×")
        #expect(VoiceSettingsSection.speedLabel(1.25, locale: Locale(identifier: "de_DE")) == "1,25×")
    }
}
