/// One page of onboarding (#44), in the order a first run shows them.
///
/// The raw values are stable: they are saved in ``OnboardingProgress`` so an
/// interrupted onboarding resumes where it stopped.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// What Blau is and what setting it up takes.
    case welcome
    /// The user's xAI API key, checked with xAI before it is stored (#33).
    case xaiAccount
    /// Microphone permission, with the way back from a denial (Settings.app).
    case microphone
    /// The on-device speech models (#27): progress and the Wi-Fi notice.
    case speechModels
    /// Whether iCloud sync is on, and how to turn it on.
    case iCloud
    /// Recording the voiceprint so Blau answers only the user (#46).
    case voiceEnrollment
    /// "Tell Blau about you": seeds the knowledge base with a profile
    /// document (M3).
    case aboutYou
    /// Setup is done: how to start talking, and what is still missing.
    case ready

    public var description: String { rawValue }

    /// Whether a conversation needs this step's prerequisite. Only these
    /// bring onboarding back after it finished, when they go missing
    /// (``OnboardingFlow/presentRecoveryIfNeeded(isConversationRunning:)``).
    public var isRequirement: Bool {
        switch self {
        case .xaiAccount, .microphone, .speechModels: true
        case .welcome, .iCloud, .voiceEnrollment, .aboutYou, .ready: false
        }
    }

    /// The steps whose prerequisite a conversation needs, in order.
    public static let requirements: [OnboardingStep] = allCases.filter(\.isRequirement)
}

/// Where one prerequisite of a working conversation stands, as onboarding
/// sees it. Each module maps its own state to this (for example
/// `MicrophonePermission.onboardingRequirement`).
public enum OnboardingRequirement: String, Sendable, Hashable, CaseIterable {
    /// Not known yet (the key, the models or iCloud are still being read).
    /// Never treated as missing, so a slow launch can't bring onboarding
    /// back by mistake.
    case unknown
    /// The user has to do something: enter a key, allow the microphone,
    /// start a download that isn't scheduled or failed.
    case missing
    /// Under way without the user, such as a model download.
    case inProgress
    /// Done.
    case satisfied
}

/// A snapshot of every onboarding step's prerequisite.
///
/// The app builds it from the live services (the xAI account, microphone
/// permission, the model manager, the store's sync state and its contents);
/// ``OnboardingFlow`` reads a fresh one each time it picks the next step.
public struct OnboardingPrerequisites: Sendable, Hashable {
    public var xaiAccount: OnboardingRequirement
    public var microphone: OnboardingRequirement
    public var speechModels: OnboardingRequirement
    public var iCloud: OnboardingRequirement
    public var voiceEnrollment: OnboardingRequirement
    public var aboutYou: OnboardingRequirement

    public init(
        xaiAccount: OnboardingRequirement = .unknown,
        microphone: OnboardingRequirement = .unknown,
        speechModels: OnboardingRequirement = .unknown,
        iCloud: OnboardingRequirement = .unknown,
        voiceEnrollment: OnboardingRequirement = .unknown,
        aboutYou: OnboardingRequirement = .unknown
    ) {
        self.xaiAccount = xaiAccount
        self.microphone = microphone
        self.speechModels = speechModels
        self.iCloud = iCloud
        self.voiceEnrollment = voiceEnrollment
        self.aboutYou = aboutYou
    }

    /// Everything done.
    public static let satisfied = OnboardingPrerequisites(
        xaiAccount: .satisfied, microphone: .satisfied, speechModels: .satisfied, iCloud: .satisfied,
        voiceEnrollment: .satisfied, aboutYou: .satisfied)

    /// The prerequisite behind `step`. The welcome and ready pages have none
    /// and read as `.missing`, so they are never skipped as already done.
    public subscript(step: OnboardingStep) -> OnboardingRequirement {
        get {
            switch step {
            case .xaiAccount: xaiAccount
            case .microphone: microphone
            case .speechModels: speechModels
            case .iCloud: iCloud
            case .voiceEnrollment: voiceEnrollment
            case .aboutYou: aboutYou
            case .welcome, .ready: .missing
            }
        }
        set {
            switch step {
            case .xaiAccount: xaiAccount = newValue
            case .microphone: microphone = newValue
            case .speechModels: speechModels = newValue
            case .iCloud: iCloud = newValue
            case .voiceEnrollment: voiceEnrollment = newValue
            case .aboutYou: aboutYou = newValue
            case .welcome, .ready: break
            }
        }
    }

    /// The requirement steps whose prerequisite is missing, in order.
    public var missingRequirements: [OnboardingStep] {
        OnboardingStep.requirements.filter { self[$0] == .missing }
    }
}
