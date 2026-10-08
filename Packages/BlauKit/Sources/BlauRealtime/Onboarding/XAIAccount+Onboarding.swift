import BlauCore

extension XAIAccount.Status {
    /// Onboarding's xAI step (#44): a stored key is done; no key or an
    /// unreadable one needs the user (the same cases as
    /// `XAIAccount.needsKeyEntry`). A Keychain that is locked or failing
    /// isn't known to be missing a key, so it never brings onboarding back.
    public var onboardingRequirement: OnboardingRequirement {
        switch self {
        case .unknown: .unknown
        case .connected: .satisfied
        case .noKey, .unavailable(.corruptItem): .missing
        case .unavailable: .unknown
        }
    }
}
