import BlauCore
import BlauTranscription
import SwiftUI

/// Accessibility identifiers for Settings → Transcription, shared with UI
/// tests. The engine toggle keeps `SpeechRecognitionSettingsIdentifiers`.
enum TranscriptionSettingsIdentifiers {
    static let secondPass = "settings.transcription.secondPass"
    static let language = "settings.transcription.language"
}

/// Settings → Transcription: the engine (Parakeet, or always Apple's), the
/// second pass that punctuates and corrects each finished sentence, and the
/// language spoken.
///
/// Every choice is saved at once. The engine and language reach a
/// conversation in progress at the end of what the user is saying
/// (`TranscriberRouter` follows `preferenceChanges()`); the second pass is
/// read for every utterance.
struct TranscriptionSettingsView: View {
    @Environment(TranscriptionSettings.self) private var settings
    @State private var supportedLocales: [Locale] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            SpeechRecognitionSettingsSection()

            Section {
                Toggle("Refine Each Sentence", isOn: $settings.refinesWithSecondPass)
                    .accessibilityIdentifier(TranscriptionSettingsIdentifiers.secondPass)
            } header: {
                Text("Second Pass")
            } footer: {
                Text(
                    "After each sentence, Blau transcribes it again with a larger model to add punctuation and fix "
                        + "words. It uses the extra speech models and pauses while your iPhone is hot or low on power."
                )
            }

            Section {
                Picker("Language", selection: $settings.language) {
                    Text("Automatic").tag(TranscriptionLanguage.automatic)
                    ForEach(languageChoices, id: \.self) { language in
                        Text(Self.name(of: language)).tag(language)
                    }
                }
                .accessibilityIdentifier(TranscriptionSettingsIdentifiers.language)
            } header: {
                Text("Language")
            } footer: {
                Text(
                    "Automatic transcribes English with Parakeet, and your iPhone's language when Apple's speech "
                        + "recognition is used. Other languages always use Apple's."
                )
            }
        }
        .navigationTitle("Transcription")
        .task {
            supportedLocales = await AppleSpeechAssets.supportedLocales()
        }
    }

    /// Apple's supported languages by name, plus the chosen one if Apple's
    /// list doesn't have it (or hasn't loaded).
    private var languageChoices: [TranscriptionLanguage] {
        var choices = supportedLocales.map { TranscriptionLanguage.locale($0.identifier) }
        if case .locale = settings.language, !choices.contains(settings.language) {
            choices.append(settings.language)
        }
        return choices.sorted { Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending }
    }

    /// "French (France)".
    static func name(of language: TranscriptionLanguage, in locale: Locale = .current) -> String {
        switch language {
        case .automatic: String(localized: "Automatic")
        case .locale(let identifier): locale.localizedString(forIdentifier: identifier) ?? identifier
        }
    }
}

#if DEBUG
    #Preview("Transcription") {
        NavigationStack {
            TranscriptionSettingsView()
        }
        .environment(TranscriptionSettings.preview())
    }
#endif
