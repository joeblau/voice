import BlauTranscription
import SwiftUI

/// Accessibility identifiers for Settings → Speech Recognition, shared with
/// UI tests.
enum SpeechRecognitionSettingsIdentifiers {
    static let useApple = "settings.speechRecognition.useApple"
    static let availability = "settings.speechRecognition.availability"
}

/// Settings → Speech Recognition (#31): the toggle that makes Blau always
/// transcribe with Apple's on-device speech recognizer instead of Parakeet,
/// and whether Apple's recognizer supports the user's language.
///
/// The choice is saved at once; a conversation in progress switches engines
/// at the end of what the user is saying (`TranscriberRouter`).
struct SpeechRecognitionSettingsSection: View {
    @Environment(TranscriptionSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let languageNeedsApple = settings.language.requiresAppleEngine
        Section {
            Toggle(
                "Use Apple Speech Recognition",
                isOn: languageNeedsApple ? .constant(true) : $settings.forcesAppleEngine
            )
            .disabled(
                languageNeedsApple
                    || (!settings.forcesAppleEngine && settings.appleAvailability?.isSupported == false)
            )
            .accessibilityIdentifier(SpeechRecognitionSettingsIdentifiers.useApple)
            if let availability = settings.appleAvailability, let note = Self.note(for: availability) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(SpeechRecognitionSettingsIdentifiers.availability)
            }
        } header: {
            Text("Speech Recognition")
        } footer: {
            Text(
                languageNeedsApple
                    ? "Parakeet understands English only, so Blau uses Apple's speech recognition for the language "
                        + "you chose below."
                    : "Blau transcribes you on this iPhone with Parakeet, and uses Apple's speech recognition when "
                        + "Parakeet can't run. Turn this on to always use Apple's."
            )
        }
        // Again whenever the language changes: availability is per language.
        .task(id: settings.language) { await settings.refreshAvailability() }
    }

    /// What to say about Apple's recognizer, or `nil` when it is ready.
    static func note(for availability: AppleSpeechAvailability) -> String? {
        switch availability {
        case .unsupportedDevice:
            String(localized: "This iPhone doesn't support Apple's on-device speech recognition.")
        case .unsupportedLocale:
            String(localized: "Apple's on-device speech recognition isn't available in your language.")
        case .notInstalled:
            String(localized: "Apple's speech model downloads the first time it's used.")
        case .downloading:
            String(localized: "Downloading Apple's speech model…")
        case .installed:
            nil
        }
    }
}

extension TranscriptionSettings {
    /// The app's settings, in `UserDefaults`. DEBUG UI-test runs use a
    /// separate suite so they never change the developer's own choice.
    static func make() -> TranscriptionSettings {
        #if DEBUG
            if XAIUITestStub.current != nil {
                return TranscriptionSettings(
                    store: UserDefaultsTranscriptionPreferencesStore(suiteName: "blau.uitests"),
                    options: UserDefaultsTranscriptionOptionsStore(suiteName: "blau.uitests"),
                    availability: { .installed(locale: "en_US") })
            }
        #endif
        let options = UserDefaultsTranscriptionOptionsStore()
        return TranscriptionSettings(
            store: UserDefaultsTranscriptionPreferencesStore(), options: options,
            // Apple's engine for the language chosen in Settings, which
            // `options` holds by the time the check runs.
            availability: { await AppleSpeechAssets.availability(for: options.load().language.locale) })
    }

    #if DEBUG
        /// Settings over an in-memory store, for previews.
        static func preview(
            _ preference: TranscriptionEnginePreference = .automatic,
            availability: AppleSpeechAvailability = .installed(locale: "en_US")
        ) -> TranscriptionSettings {
            TranscriptionSettings(
                store: InMemoryTranscriptionPreferencesStore(preference), availability: { availability })
        }
    #endif
}

#if DEBUG
    #Preview("Speech recognition") {
        Form {
            SpeechRecognitionSettingsSection()
        }
        .environment(TranscriptionSettings.preview(availability: .unsupportedLocale("xx_XX")))
    }
#endif
