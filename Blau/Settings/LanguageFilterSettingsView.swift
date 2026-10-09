import BlauTranscription
import BlauVoiceID
import SwiftUI

/// Accessibility identifiers for Settings → Voice ID → Languages (#50),
/// shared with UI tests.
enum LanguageFilterSettingsIdentifiers {
    static let toggle = "settings.voiceID.languages.enabled"
    static let languages = "settings.voiceID.languages"
    static let modelStatus = "settings.voiceID.languages.model"
    static let useDefault = "settings.voiceID.languages.default"
    static let list = "settings.voiceID.languages.list"

    static func row(_ language: SpokenLanguage) -> String { "settings.voiceID.languages.\(language.code)" }
}

/// The Languages section of Settings → Voice ID: whether speech in other
/// languages is ignored, and which languages Blau answers.
struct LanguageFilterSection: View {
    @Environment(AppEnvironment.self) private var environment
    let settings: LanguageFilterSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Ignore Other Languages", isOn: $settings.isEnabled)
                .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.toggle)
            if settings.isEnabled {
                NavigationLink {
                    AllowedLanguagesView(settings: settings)
                } label: {
                    LabeledContent("Languages", value: Self.summary(settings.allowedLanguages))
                }
                .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.languages)
                if let status = Self.modelStatus(environment.speechModels.state(of: .languageID)) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.modelStatus)
                }
            }
        } header: {
            Text("Languages")
        } footer: {
            Text(
                "Blau doesn't answer speech in other languages, such as a TV show in another language, even when "
                    + "it sounds like you. Turning this on applies from your next conversation; the languages apply "
                    + "from the next thing you say."
            )
        }
    }

    /// "English", "English and French", "English, French and 2 more".
    static func summary(_ languages: Set<SpokenLanguage>, locale: Locale = .current) -> String {
        let names = languages.map { $0.localizedName(in: locale) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        switch names.count {
        case 0: return String(localized: "None")
        case 1, 2: return names.formatted(.list(type: .and).locale(locale))
        default:
            let shown = names.prefix(2).joined(separator: ", ")
            return String(localized: "\(shown) and \(names.count - 2) more")
        }
    }

    /// What to tell the user while the filter can't run yet: the model is
    /// downloaded with the other optional models.
    static func modelStatus(_ state: ModelState) -> String? {
        switch state {
        case .ready, .preparing: nil
        case .failed: String(localized: "The language model couldn't be installed. See Speech Models.")
        default: String(localized: "Waiting for the language model to download.")
        }
    }
}

/// Settings → Voice ID → Languages: the languages Blau answers. The
/// default follows the iPhone's languages (and English, which Blau's
/// speech recognition transcribes) until the user picks.
struct AllowedLanguagesView: View {
    let settings: LanguageFilterSettings
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Button {
                    settings.useDefaultLanguages()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Use iPhone Languages")
                                .foregroundStyle(.primary)
                            Text(LanguageFilterSection.summary(settings.defaultAllowedLanguages))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.usesDefaultLanguages {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.useDefault)
                .accessibilityAddTraits(settings.usesDefaultLanguages ? .isSelected : [])
            } footer: {
                Text("Blau answers speech in these languages and ignores the rest. At least one stays selected.")
            }

            Section {
                ForEach(Self.languages(matching: query), id: \.self) { language in
                    let isAllowed = settings.allowedLanguages.contains(language)
                    Button {
                        settings.setAllowed(language, !isAllowed)
                    } label: {
                        HStack {
                            Text(language.localizedName())
                                .foregroundStyle(.primary)
                            Spacer()
                            if isAllowed {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.row(language))
                    .accessibilityAddTraits(isAllowed ? .isSelected : [])
                }
            }
        }
        .accessibilityIdentifier(LanguageFilterSettingsIdentifiers.list)
        .searchable(text: $query, prompt: "Search Languages")
        .navigationTitle("Languages")
    }

    /// Every language the model knows, by name in `locale`, filtered by
    /// `query`.
    static func languages(matching query: String, locale: Locale = .current) -> [SpokenLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return SpokenLanguage.all
            .filter { trimmed.isEmpty || $0.localizedName(in: locale).localizedStandardContains(trimmed) }
            .sorted {
                $0.localizedName(in: locale).localizedStandardCompare($1.localizedName(in: locale)) == .orderedAscending
            }
    }
}

extension LanguageFilterSettings {
    /// The app's language filter settings, in `UserDefaults` (`suiteName`
    /// `nil` for the standard defaults). The default languages are the
    /// iPhone's plus the one Blau transcribes, read from the same
    /// Settings → Transcription choice the speech pipeline follows.
    static func make(suiteName: String?) -> LanguageFilterSettings {
        let options = UserDefaultsTranscriptionOptionsStore(suiteName: suiteName)
        return LanguageFilterSettings(
            store: UserDefaultsLanguageFilterPreferencesStore(suiteName: suiteName),
            defaultLanguages: { defaultLanguages(transcribing: options.load().language) })
    }

    /// The iPhone's preferred languages, plus the language Blau
    /// transcribes: English when the language is Automatic (Parakeet only
    /// understands English), or the one chosen in Settings → Transcription.
    /// So the default never filters out what Blau is set up to hear.
    nonisolated static func defaultLanguages(
        transcribing language: TranscriptionLanguage, preferred: [String] = Locale.preferredLanguages
    ) -> Set<SpokenLanguage> {
        var languages = Set(SpokenLanguage.preferred(preferred))
        switch language {
        case .automatic:
            languages.insert(.english)
        case .locale(let identifier):
            if let chosen = SpokenLanguage(identifier: identifier) { languages.insert(chosen) }
        }
        return languages
    }
}
