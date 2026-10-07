import BlauRealtime
import SwiftUI

/// Accessibility identifiers for Settings → Voice, shared with UI tests.
enum VoiceSettingsIdentifiers {
    static let voice = "settings.voice.picker"
    static let speed = "settings.voice.speed"
    static let thinking = "settings.voice.thinking"
    static let reset = "settings.voice.reset"
}

/// Settings → Voice: Grok's voice, speaking speed and whether it reasons
/// before answering. Each change is saved at once and sent to a live
/// session with the next `session.update`.
struct VoiceSettingsSection: View {
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
            )
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
