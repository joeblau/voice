/// A switch for a feature that is still being built, tuned or measured.
///
/// Every flag has a compiled-in default: the value users get. DEBUG builds
/// can override any flag from the debug menu or a launch argument (see
/// `FeatureFlags`). Add a case here, give it a title, a summary and a
/// default, and read it through `FeatureFlags.isEnabled(_:)`.
public enum FeatureFlag: String, CaseIterable, Identifiable, Sendable {
    /// Gate user speech on the enrolled voiceprint, so only the enrolled
    /// speaker reaches Grok (BlauVoiceID). Off means every recognized
    /// utterance is committed.
    case voiceIDEnabled

    /// Re-transcribe finished utterances with Parakeet TDT v3 for punctuation
    /// and accuracy before they are stored (BlauTranscription).
    case secondPassASR

    /// Confirm and title candidate topic boundaries with the on-device
    /// Foundation Models LLM instead of trusting the depth score alone
    /// (BlauTopics).
    case topicLLMConfirm

    /// Expose the memory tools (`search_memory`, `remember`, ...) to Grok
    /// during a realtime session (BlauMemory, BlauRealtime).
    case memoryTools

    /// Show the debug performance HUD overlay (BlauTelemetry).
    case perfHUD

    public var id: String { rawValue }

    /// The value used unless a DEBUG override is set. These are the shipping
    /// values: the product features default on, diagnostics default off.
    public var defaultValue: Bool {
        switch self {
        case .voiceIDEnabled, .secondPassASR, .topicLLMConfirm, .memoryTools: true
        case .perfHUD: false
        }
    }

    /// A short name for the debug menu and Settings → Developer.
    public var title: String {
        switch self {
        case .voiceIDEnabled: "Voice ID gate"
        case .secondPassASR: "Second-pass ASR"
        case .topicLLMConfirm: "LLM topic confirmation"
        case .memoryTools: "Memory tools"
        case .perfHUD: "Performance HUD"
        }
    }

    /// One line describing what the flag changes.
    public var summary: String {
        switch self {
        case .voiceIDEnabled: "Only the enrolled speaker's speech is sent to Grok."
        case .secondPassASR: "Re-transcribe finished utterances with Parakeet TDT v3."
        case .topicLLMConfirm: "Confirm and title topic boundaries with Foundation Models."
        case .memoryTools: "Let Grok search and update memory with tools."
        case .perfHUD: "Overlay live pipeline metrics on the screen."
        }
    }

    /// The `UserDefaults` key that holds this flag's override, for example
    /// `blau.featureFlag.perfHUD`.
    ///
    /// Because `UserDefaults.standard` includes the launch arguments, a DEBUG
    /// run can also override a flag from the scheme or a UI test:
    /// `-blau.featureFlag.perfHUD YES`.
    public var defaultsKey: String { FeatureFlag.defaultsKeyPrefix + rawValue }

    /// Prefix shared by every flag's `defaultsKey`.
    public static let defaultsKeyPrefix = "blau.featureFlag."
}

extension FeatureFlag: CustomStringConvertible {
    public var description: String { rawValue }
}
