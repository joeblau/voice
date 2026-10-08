import BlauCore

extension SyncState {
    /// Onboarding's iCloud step (#44): sync running is done; anything else
    /// (signed out, restricted, failing, not saving) is worth showing. iCloud
    /// isn't a requirement of a conversation (everything is kept on the
    /// device), so this only decides whether the step appears during setup.
    public var onboardingRequirement: OnboardingRequirement {
        switch self {
        case .checking: .unknown
        case .syncing, .upToDate: .satisfied
        case .failing, .off, .notSaved: .missing
        }
    }
}
