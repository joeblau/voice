import BlauTranscription
import Foundation
import Testing

@testable import Blau

@Suite("Settings → Speech Recognition")
@MainActor
struct SpeechRecognitionSettingsAppTests {
    @Test func nonLiveEnvironmentsKeepTheChoiceInMemory() async {
        let first = AppEnvironment.fake(kind: .unitTest)
        #expect(first.transcriptionSettings.enginePreference == .automatic)
        first.transcriptionSettings.forcesAppleEngine = true

        // Another environment starts from the default: nothing was saved
        // to the device.
        let second = AppEnvironment.fake(kind: .unitTest)
        #expect(second.transcriptionSettings.forcesAppleEngine == false)

        await second.transcriptionSettings.refreshAvailability()
        #expect(second.transcriptionSettings.appleAvailability == .installed(locale: "en_US"))
    }

    @Test func theToggleReachesARouterFollowingTheSettings() async throws {
        let environment = AppEnvironment.preview()
        var changes = environment.transcriptionSettings.preferenceChanges().makeAsyncIterator()
        #expect(await changes.next() == .automatic)
        environment.transcriptionSettings.forcesAppleEngine = true
        #expect(await changes.next() == .apple)
    }

    @Test func availabilityNotes() {
        #expect(SpeechRecognitionSettingsSection.note(for: .installed(locale: "en_US")) == nil)
        for availability: AppleSpeechAvailability in [
            .unsupportedDevice, .unsupportedLocale("xx_XX"), .notInstalled(locale: "en_US"),
            .downloading(locale: "en_US"),
        ] {
            #expect(SpeechRecognitionSettingsSection.note(for: availability)?.isEmpty == false)
        }
    }
}
