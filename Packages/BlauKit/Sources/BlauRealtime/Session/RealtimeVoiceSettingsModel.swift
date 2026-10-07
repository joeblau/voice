import Foundation
import Observation

/// Settings → Voice and Settings → Search bind to this. Each change is
/// written straight to the ``RealtimeVoiceSettingsStore``, so the next
/// `session.update` carries it.
///
/// ```swift
/// @Bindable var model: RealtimeVoiceSettingsModel
/// Picker("Voice", selection: $model.voice) { ... }
/// Slider(value: $model.speed, in: RealtimeVoiceSettings.speedRange, step: RealtimeVoiceSettings.speedStep)
/// ```
@MainActor
@Observable
public final class RealtimeVoiceSettingsModel {
    /// What the store holds.
    public private(set) var settings: RealtimeVoiceSettings

    @ObservationIgnored public let store: RealtimeVoiceSettingsStore

    public init(store: RealtimeVoiceSettingsStore) {
        self.store = store
        settings = store.settings
    }

    public var voice: RealtimeVoice {
        get { settings.voice }
        set { apply { $0.voice = newValue } }
    }

    public var speed: Double {
        get { settings.speed }
        set { apply { $0.speed = newValue } }
    }

    public var reasoningEffort: RealtimeReasoningEffort {
        get { settings.reasoningEffort }
        set { apply { $0.reasoningEffort = newValue } }
    }

    /// Whether Grok reasons before answering (`reasoning.effort` `high`) or
    /// answers straight away (`none`).
    public var thinksBeforeAnswering: Bool {
        get { settings.reasoningEffort != .disabled }
        set { reasoningEffort = newValue ? .high : .disabled }
    }

    /// The built-in server tools Grok may use (Settings → Search).
    public var builtInTools: Set<RealtimeBuiltInTool> {
        get { settings.builtInTools }
        set { apply { $0.builtInTools = newValue } }
    }

    /// Whether Grok may use `tool`.
    public func isEnabled(_ tool: RealtimeBuiltInTool) -> Bool {
        settings.builtInTools.contains(tool)
    }

    /// Lets Grok use `tool`, or stops it.
    public func setEnabled(_ tool: RealtimeBuiltInTool, _ isEnabled: Bool) {
        apply { settings in
            if isEnabled {
                settings.builtInTools.insert(tool)
            } else {
                settings.builtInTools.remove(tool)
            }
        }
    }

    /// The voices to offer: the built-in ones, plus the current voice if it
    /// is a custom one.
    public var availableVoices: [RealtimeVoice] {
        settings.voice.isBuiltIn ? RealtimeVoice.builtIn : RealtimeVoice.builtIn + [settings.voice]
    }

    /// Back to xAI's defaults.
    public func resetToDefaults() {
        apply { $0 = .default }
    }

    /// Re-reads the store, e.g. after something other than this model
    /// changed it.
    public func reload() {
        let current = store.settings
        if current != settings {
            settings = current
        }
    }

    private func apply(_ change: (inout RealtimeVoiceSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        store.set(updated)
    }
}
