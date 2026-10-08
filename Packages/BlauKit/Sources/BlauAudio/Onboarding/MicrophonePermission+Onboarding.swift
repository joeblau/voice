import BlauCore

extension MicrophonePermission {
    /// Onboarding's microphone step (#44): granted is done; undetermined
    /// (the prompt hasn't been answered) and denied (only the Settings app
    /// can turn it back on) need the user.
    public var onboardingRequirement: OnboardingRequirement {
        switch self {
        case .granted: .satisfied
        case .undetermined, .denied: .missing
        }
    }
}
