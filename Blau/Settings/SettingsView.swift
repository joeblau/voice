import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTranscription
import BlauVoiceID
import SwiftData
import SwiftUI

/// One page of Settings, reached from a row of the root list.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case account
    case voice
    case voiceID
    case transcription
    case knowledge
    case iCloud
    case models
    case privacy
    case developer

    var id: String { rawValue }

    /// The root list's groups, top to bottom: talking with Grok, what Blau
    /// keeps, and housekeeping.
    static let groups: [[SettingsPane]] = [
        [.account, .voice, .voiceID, .transcription],
        [.knowledge, .iCloud, .models],
        [.privacy, .developer],
    ]

    var title: String {
        switch self {
        case .account: String(localized: "xAI Account")
        case .voice: String(localized: "Voice")
        case .voiceID: String(localized: "Voice ID")
        case .transcription: String(localized: "Transcription")
        case .knowledge: String(localized: "Knowledge")
        case .iCloud: String(localized: "iCloud")
        case .models: String(localized: "Speech Models")
        case .privacy: String(localized: "Privacy & Data")
        case .developer: String(localized: "Developer")
        }
    }

    var systemImage: String {
        switch self {
        case .account: "key.fill"
        case .voice: "waveform"
        case .voiceID: "person.wave.2.fill"
        case .transcription: "text.bubble.fill"
        case .knowledge: "books.vertical.fill"
        case .iCloud: "icloud.fill"
        case .models: "cpu.fill"
        case .privacy: "hand.raised.fill"
        case .developer: "hammer.fill"
        }
    }

    var tint: Color {
        switch self {
        case .account: .blue
        case .voice: .indigo
        case .voiceID: .teal
        case .transcription: .green
        case .knowledge: .brown
        case .iCloud: .cyan
        case .models: .gray
        case .privacy: .red
        case .developer: .orange
        }
    }

    /// The root row's accessibility identifier. Speech Models keeps the
    /// identifier its link had before the panes existed.
    var identifier: String {
        self == .models ? SpeechModelSettingsView.Identifier.link : "settings.pane.\(rawValue)"
    }
}

/// Accessibility identifiers for the Settings sheet, shared with UI tests.
enum SettingsIdentifiers {
    static let list = "settings.list"
    static let done = "settings.done"
}

/// The settings sheet presented from the main screen's bottom-left button
/// (#43).
///
/// The root is a short list of panes, one per area, each with a one-line
/// summary of where it stands. It opens at the medium detent; opening a
/// pane grows the sheet to the large detent, and the user can drag it
/// between the two. Every control writes straight to the model behind it
/// (`XAIAccount`, `RealtimeVoiceSettingsModel`, `VoiceIDSettings`,
/// `TranscriptionSettings`, `ModelManager`, `FeatureFlags`...), so changes
/// take effect live: the next `session.update`, the next utterance, the
/// HUD overlay at once.
struct SettingsView: View {
    /// The zoom transition's source id: the bottom-bar Settings button.
    static let transitionSourceID = "settings"

    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPane] = []
    @State private var detent: PresentationDetent = .medium

    /// Opens on `pane` instead of the root list (for previews).
    var initialPane: SettingsPane?

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier(SettingsIdentifiers.done)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootList()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: SettingsPane.self) { pane in
                    // Done on every page closes the sheet. `dismiss` is read
                    // here, outside the stack: inside a pushed page it would
                    // pop the page instead.
                    SettingsPaneView(pane: pane)
                        .toolbar { doneButton }
                }
                .toolbar { doneButton }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: path) { _, path in
            // A pane is a full page of controls: give it the room.
            if !path.isEmpty {
                withAnimation { detent = .large }
            }
        }
        .onAppear {
            if let initialPane, path.isEmpty {
                path = [initialPane]
            }
        }
    }
}

/// The root list: one row per `SettingsPane`, grouped.
private struct SettingsRootList: View {
    @Query(sort: \VoiceProfile.updatedAt, order: .reverse) private var voiceProfiles: [VoiceProfile]

    var body: some View {
        let voiceID = VoiceIDStatus(profile: voiceProfiles.first)
        List {
            ForEach(SettingsPane.groups.indices, id: \.self) { index in
                Section {
                    ForEach(SettingsPane.groups[index]) { pane in
                        NavigationLink(value: pane) {
                            SettingsPaneRow(pane: pane, voiceID: voiceID)
                        }
                        .accessibilityIdentifier(pane.identifier)
                    }
                } footer: {
                    if index == SettingsPane.groups.count - 1 {
                        Text(SettingsSummary.version())
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityIdentifier(SettingsIdentifiers.list)
    }
}

/// A root row: the pane's icon and title, and its summary on the right.
private struct SettingsPaneRow: View {
    let pane: SettingsPane
    let voiceID: VoiceIDStatus

    @Environment(XAIAccount.self) private var account
    @Environment(RealtimeVoiceSettingsModel.self) private var voice
    @Environment(TranscriptionSettings.self) private var transcription
    @Environment(PersistenceController.self) private var persistence
    @Environment(ModelManager.self) private var models
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        LabeledContent {
            if let summary {
                Text(summary)
                    .lineLimit(1)
            }
        } label: {
            Label {
                Text(pane.title)
            } icon: {
                Image(systemName: pane.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(pane.tint.gradient, in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
            }
        }
    }

    private var summary: String? {
        switch pane {
        case .account: SettingsSummary.account(account.status)
        case .voice: SettingsSummary.voice(voice.settings)
        case .voiceID: voiceID.title
        case .transcription:
            SettingsSummary.transcription(
                engine: transcription.effectiveEnginePreference, language: transcription.language)
        case .iCloud: SyncStatusPresentation(persistence.syncState).title
        case .models: models.hasCheckedInstalledModels ? models.totalDiskUsage.formattedByteCount : nil
        case .developer: environment.performanceHUD.isVisible ? String(localized: "HUD on") : nil
        case .knowledge, .privacy: nil
        }
    }
}

/// The page for one pane.
private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .account: XAIAccountSettingsView()
        case .voice: VoiceSettingsView()
        case .voiceID: VoiceIDSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .knowledge: KnowledgeSettingsView()
        case .iCloud: ICloudSettingsView()
        case .models: SpeechModelSettingsView()
        case .privacy: PrivacySettingsView()
        case .developer: DeveloperSettingsView()
        }
    }
}

/// The root rows' one-line summaries. Pure, so unit tests cover them.
@MainActor
enum SettingsSummary {
    static func account(_ status: XAIAccount.Status) -> String {
        switch status {
        case .unknown: String(localized: "Checking…")
        case .noKey: String(localized: "Not connected")
        case .connected: String(localized: "Connected")
        case .unavailable(.corruptItem): String(localized: "Needs a new key")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    /// "Eve, 1.0×".
    static func voice(_ settings: RealtimeVoiceSettings, locale: Locale = .current) -> String {
        "\(settings.voice.displayName), \(VoiceSettingsSection.speedLabel(settings.speed, locale: locale))"
    }

    /// The engine, and the language when one is chosen: "Parakeet",
    /// "Apple Speech · French".
    static func transcription(
        engine: TranscriptionEnginePreference, language: TranscriptionLanguage, locale: Locale = .current
    ) -> String {
        let name = engine == .apple ? TranscriptionEngine.apple.displayName : TranscriptionEngine.parakeet.displayName
        guard case .locale(let identifier) = language else { return name }
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return "\(name) · \(locale.localizedString(forLanguageCode: code) ?? identifier)"
    }

    /// "Blau 1.0 (42)" from the bundle.
    static func version(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "Blau \(version) (\(build))"
    }
}

#if DEBUG
    #Preview("Settings") {
        let environment = AppEnvironment.preview()
        Color.clear
            .sheet(isPresented: .constant(true)) {
                SettingsView()
            }
            .appEnvironment(environment)
            .environment(AppDiagnostics(store: nil))
            .modelContainer(PersistenceController.previewContainer())
    }
#endif
