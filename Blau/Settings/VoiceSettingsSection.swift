import BlauRealtime
import SwiftUI

/// Accessibility identifiers for Settings → Voice, shared with UI tests.
enum VoiceSettingsIdentifiers {
    static let voice = "settings.voice.picker"
    static let speed = "settings.voice.speed"
    static let thinking = "settings.voice.thinking"
    static let reset = "settings.voice.reset"
    static let preview = "settings.voice.preview"
    static let previewProblem = "settings.voice.preview.problem"
}

/// Settings → Voice: Grok's voice (with a spoken preview), speaking speed
/// and reasoning effort, and the search tools. Each change is saved at once
/// and sent to a live session with the next `session.update`.
struct VoiceSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var preview: VoicePreviewPlayer?

    var body: some View {
        Form {
            VoiceSettingsSection(preview: preview)
            SearchToolsSettingsSection()
        }
        .navigationTitle("Voice")
        .onAppear {
            if preview == nil {
                preview = VoicePreviewPlayer(previewer: environment.xai.voicePreviewer, audio: environment.audio)
            }
        }
        .onDisappear { preview?.stop() }
    }
}

/// Settings → Voice's main section: Grok's voice, speaking speed and
/// whether it reasons before answering (`reasoning.effort`).
struct VoiceSettingsSection: View {
    /// Plays the chosen voice; `nil` hides the preview button.
    var preview: VoicePreviewPlayer?

    @Environment(RealtimeVoiceSettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Voice", selection: $model.voice) {
                ForEach(model.availableVoices) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            .accessibilityIdentifier(VoiceSettingsIdentifiers.voice)
            .onChange(of: model.voice) {
                preview?.stop()
            }

            if let preview {
                previewRow(preview)
            }

            VStack(alignment: .leading) {
                LabeledContent("Speaking speed") {
                    Text(Self.speedLabel(model.speed))
                        .monospacedDigit()
                }
                Slider(
                    value: $model.speed,
                    in: RealtimeVoiceSettings.speedRange,
                    step: RealtimeVoiceSettings.speedStep
                ) {
                    Text("Speaking speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                        .accessibilityLabel("Slower")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                        .accessibilityLabel("Faster")
                }
                .accessibilityValue(Self.speedLabel(model.speed))
                .accessibilityIdentifier(VoiceSettingsIdentifiers.speed)
            }

            Toggle("Think Before Answering", isOn: $model.thinksBeforeAnswering)
                .accessibilityIdentifier(VoiceSettingsIdentifiers.thinking)

            if model.settings != .default {
                Button("Reset to Defaults") {
                    model.resetToDefaults()
                }
                .accessibilityIdentifier(VoiceSettingsIdentifiers.reset)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text(
                "Changes apply from Grok's next reply. Thinking first gives more considered answers; "
                    + "turn it off for quicker replies."
                    + (preview == nil ? "" : " Previews come from xAI and count toward your xAI usage.")
            )
        }
    }

    @ViewBuilder
    private func previewRow(_ preview: VoicePreviewPlayer) -> some View {
        let voice = model.voice
        Button {
            if preview.isActive(voice) {
                preview.stop()
            } else {
                preview.play(voice, speed: model.speed)
            }
        } label: {
            HStack {
                Label(
                    preview.isActive(voice) ? "Stop Preview" : "Preview \(voice.displayName)",
                    systemImage: preview.state == .playing(voice) ? "stop.circle" : "play.circle")
                Spacer()
                if preview.state == .loading(voice) {
                    ProgressView()
                }
            }
        }
        .accessibilityIdentifier(VoiceSettingsIdentifiers.preview)
        if case .failed(let message) = preview.state {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(VoiceSettingsIdentifiers.previewProblem)
        }
    }

    /// "1.0×", "1.25×" (with the locale's decimal separator).
    static func speedLabel(_ speed: Double, locale: Locale = .current) -> String {
        speed.formatted(.number.precision(.fractionLength(1...2)).locale(locale)) + "×"
    }
}

#if DEBUG
    extension RealtimeVoiceSettingsModel {
        /// A model over an in-memory store, for previews.
        static func preview(_ settings: RealtimeVoiceSettings = .default) -> RealtimeVoiceSettingsModel {
            RealtimeVoiceSettingsModel(
                store: RealtimeVoiceSettingsStore(persistence: InMemoryVoiceSettingsPersistence(settings)))
        }
    }

    #Preview {
        Form {
            VoiceSettingsSection()
        }
        .environment(RealtimeVoiceSettingsModel.preview(RealtimeVoiceSettings(voice: .ara, speed: 1.15)))
    }
#endif
