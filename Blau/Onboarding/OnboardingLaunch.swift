import BlauAudio
import BlauCore
import Foundation

/// Decides, per launch, whether onboarding (#44) can show and which
/// microphone permission it asks.
///
/// - The real app (`live`, launched by the user or from Xcode) keeps its
///   progress in `UserDefaults.standard`.
/// - Tests, previews and test-driven launches (fixture models or any
///   `BLAU_UI_TEST_*` stub) open straight on the main screen, so the UI
///   tests that don't care about onboarding aren't stopped by it.
/// - `BLAU_UI_TEST_ONBOARDING` turns it on for a UI test, with progress in
///   the `blau.uitests` suite: `fresh` starts setup over, `resume` keeps what
///   the previous launch saved, `finished` starts with setup done (to test
///   recovery).
enum OnboardingLaunch {
    /// Launch environment variable that turns onboarding on in a UI test.
    static let environmentKey = "BLAU_UI_TEST_ONBOARDING"

    /// Launch environment variable for the stub microphone permission (DEBUG
    /// builds): `granted`, `denied`, `undetermined` (the prompt allows) or
    /// `undetermined-deny` (the prompt denies).
    static let microphoneEnvironmentKey = "BLAU_UI_TEST_MICROPHONE"

    /// The suite UI-test progress lives in, apart from the developer's own.
    static let uiTestSuite = "blau.uitests"

    enum Start: String, Sendable {
        case fresh
        case resume
        case finished
    }

    enum Mode: Equatable, Sendable {
        /// The app's own progress.
        case standard
        /// Never shown.
        case disabled
        /// A UI test's progress.
        case uiTest(Start)
    }

    static func mode(kind: AppEnvironment.Kind, environment: [String: String]) -> Mode {
        if let raw = environment[environmentKey] {
            return Start(rawValue: raw).map(Mode.uiTest) ?? .disabled
        }
        guard kind == .live, !SpeechModels.usesFixtures(environment) else { return .disabled }
        return .standard
    }

    /// The progress store for `mode`, or `nil` when onboarding is off.
    static func progressStore(for mode: Mode) -> (any OnboardingProgressStore)? {
        switch mode {
        case .disabled:
            return nil
        case .standard:
            return UserDefaultsOnboardingProgressStore()
        case .uiTest(let start):
            let store = UserDefaultsOnboardingProgressStore(suiteName: uiTestSuite)
            switch start {
            case .fresh:
                store.reset()
            case .finished:
                store.save(OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date()))
            case .resume:
                break
            }
            return store
        }
    }

    static func progressStore(
        kind: AppEnvironment.Kind, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any OnboardingProgressStore)? {
        progressStore(for: mode(kind: kind, environment: environment))
    }

    /// The microphone permission onboarding asks: the system's in the live
    /// app, unless a DEBUG UI test picks a stub; a stub that is already
    /// granted everywhere else, so fakes never prompt.
    static func microphonePermission(
        live: Bool, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any MicrophonePermissionProvider {
        #if DEBUG
            if let stub = environment[microphoneEnvironmentKey].flatMap(stubPermission) {
                return stub
            }
        #endif
        return live ? SystemMicrophonePermission() : StubMicrophonePermission(.granted)
    }

    /// The stub `BLAU_UI_TEST_MICROPHONE` names.
    static func stubPermission(_ value: String) -> StubMicrophonePermission? {
        switch value {
        case "granted": StubMicrophonePermission(.granted)
        case "denied": StubMicrophonePermission(.denied)
        case "undetermined": StubMicrophonePermission(.undetermined, answer: true)
        case "undetermined-deny": StubMicrophonePermission(.undetermined, answer: false)
        default: nil
        }
    }
}
