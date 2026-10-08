import BlauCore

extension ModelSetupStatus {
    /// Onboarding's speech model step (#44).
    ///
    /// A download that is running, queued or waiting for the network is
    /// under way without the user (it resumes on its own); only a model that
    /// isn't scheduled (deleted in Settings, or never started) or that failed
    /// needs them.
    public var onboardingRequirement: OnboardingRequirement {
        switch phase {
        case .checking: .unknown
        case .needsDownload, .failed: .missing
        case .downloading, .waiting, .preparing: .inProgress
        case .ready: .satisfied
        }
    }
}
