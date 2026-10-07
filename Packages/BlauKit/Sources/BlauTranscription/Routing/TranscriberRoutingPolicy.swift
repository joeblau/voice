/// Why `TranscriberRouter` runs the engine it runs.
public enum TranscriberRoutingReason: String, CaseIterable, Hashable, Sendable {
    /// Parakeet, the primary engine, can run: the normal case.
    case primary
    /// The user chose Apple's engine in Settings.
    case userPreference
    /// Parakeet can't run: its model isn't installed or failed to load.
    case primaryUnavailable
    /// `BackgroundInferenceMonitor` moved the speech-to-text stage to
    /// `InferenceBackend.systemSpeech` off screen (#26: the shipping
    /// mitigation says so, or Parakeet kept failing or falling behind).
    case background
    /// The system reported critical memory pressure; Apple's engine runs
    /// its model outside Blau's process.
    case memoryPressure
    /// The preferred engine couldn't run, so the other one does.
    case fallback
}

/// Everything the engine choice depends on.
public struct TranscriberRoutingInputs: Hashable, Sendable {
    public var preference: TranscriptionEnginePreference
    /// Whether `BackgroundInferenceMonitor` asked for the system
    /// transcriber (`switchInferenceBackend(to: .systemSpeech)`).
    public var systemSpeechRequested: Bool
    public var isUnderMemoryPressure: Bool
    /// Whether each engine can run right now (installed, supported, not
    /// failed).
    public var parakeetAvailable: Bool
    public var appleAvailable: Bool

    public init(
        preference: TranscriptionEnginePreference = .automatic,
        systemSpeechRequested: Bool = false,
        isUnderMemoryPressure: Bool = false,
        parakeetAvailable: Bool = true,
        appleAvailable: Bool = true
    ) {
        self.preference = preference
        self.systemSpeechRequested = systemSpeechRequested
        self.isUnderMemoryPressure = isUnderMemoryPressure
        self.parakeetAvailable = parakeetAvailable
        self.appleAvailable = appleAvailable
    }
}

/// The engine choice, separate from the router so every rule is tested on
/// its own.
public enum TranscriberRoutingPolicy {
    /// The engine to run for `inputs` and why, or `nil` when neither can
    /// run. In order:
    ///
    /// 1. the user's choice of Apple's engine;
    /// 2. Apple's engine when Parakeet isn't available;
    /// 3. Apple's engine when the background inference monitor asked for
    ///    the system transcriber;
    /// 4. Apple's engine under critical memory pressure;
    /// 5. otherwise Parakeet.
    ///
    /// When the chosen engine isn't available the other one runs
    /// (`fallback`).
    public static func choose(_ inputs: TranscriberRoutingInputs) -> (
        engine: TranscriptionEngine, reason: TranscriberRoutingReason
    )? {
        let preferred: (TranscriptionEngine, TranscriberRoutingReason) =
            if inputs.preference == .apple {
                (.apple, .userPreference)
            } else if !inputs.parakeetAvailable {
                (.apple, .primaryUnavailable)
            } else if inputs.systemSpeechRequested {
                (.apple, .background)
            } else if inputs.isUnderMemoryPressure {
                (.apple, .memoryPressure)
            } else {
                (.parakeet, .primary)
            }
        if isAvailable(preferred.0, inputs) {
            return preferred
        }
        let other: TranscriptionEngine = preferred.0 == .apple ? .parakeet : .apple
        return isAvailable(other, inputs) ? (other, .fallback) : nil
    }

    private static func isAvailable(_ engine: TranscriptionEngine, _ inputs: TranscriberRoutingInputs) -> Bool {
        switch engine {
        case .parakeet: inputs.parakeetAvailable
        case .apple: inputs.appleAvailable
        }
    }
}
