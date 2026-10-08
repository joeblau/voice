import BlauCore
import BlauPersistence
import SwiftUI

/// Accessibility identifiers for onboarding, shared with its UI tests.
enum OnboardingIdentifiers {
    static let view = "blau.onboarding"
    static let back = "blau.onboarding.back"
    static let progress = "blau.onboarding.progress"
    static let notNow = "blau.onboarding.notNow"
    /// Each page: `blau.onboarding.step.<step>`.
    static func step(_ step: OnboardingStep) -> String { "blau.onboarding.step.\(step.rawValue)" }
    /// The page's main button (Get Started, Continue, Allow Microphone...).
    static let primary = "blau.onboarding.primary"
    /// The page's skip button.
    static let skip = "blau.onboarding.skip"
    static let openSettings = "blau.onboarding.openSettings"
    static let microphoneStatus = "blau.onboarding.microphone.status"
    static let iCloudStatus = "blau.onboarding.iCloud.status"
    static let aboutYouField = "blau.onboarding.aboutYou.field"
    static let stillMissing = "blau.onboarding.ready.missing"
}

/// Onboarding (#44): one page per `OnboardingStep`, from first launch to a
/// working conversation. `RootView` shows it instead of the main screen
/// while the flow is presented.
///
/// The top bar has Back (during setup, after the first page), the progress
/// through the steps still ahead, and Not Now when it came back because a
/// requirement went missing (recovery). Each page has its own Continue and
/// Skip, so no step can trap the user.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let onboarding = environment.onboarding
        let flow = onboarding.flow
        VStack(spacing: 0) {
            OnboardingTopBar(onboarding: onboarding)
            if let step = flow.step {
                page(for: step, onboarding: onboarding)
                    .id(step)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity))
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(OnboardingIdentifiers.step(step))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(reduceMotion ? .default : .snappy, value: flow.step)
        // A container, so its identifier doesn't replace the pages' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(OnboardingIdentifiers.view)
        // The user may have changed the microphone permission in the
        // Settings app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { onboarding.refreshMicrophone() }
        }
    }

    @ViewBuilder
    private func page(for step: OnboardingStep, onboarding: OnboardingController) -> some View {
        switch step {
        case .welcome:
            WelcomeOnboardingPage(onContinue: onboarding.advance)
        case .xaiAccount:
            XAIKeyOnboardingStep(onFinish: onboarding.advance)
        case .microphone:
            MicrophoneOnboardingPage(onboarding: onboarding)
        case .speechModels:
            SpeechModelsOnboardingPage(onContinue: onboarding.advance)
        case .iCloud:
            ICloudOnboardingPage(onContinue: onboarding.advance)
        case .voiceEnrollment:
            VoiceEnrollmentOnboardingPage(onContinue: onboarding.advance)
        case .aboutYou:
            AboutYouOnboardingPage(onContinue: onboarding.advance)
        case .ready:
            ReadyOnboardingPage(prerequisites: onboarding.prerequisites, onFinish: onboarding.advance)
        }
    }
}

/// Back, the progress through the steps, and Not Now in recovery.
private struct OnboardingTopBar: View {
    let onboarding: OnboardingController

    var body: some View {
        let flow = onboarding.flow
        let total = flow.completedCount + flow.remainingSteps.count
        HStack(spacing: 12) {
            if flow.canGoBack {
                Button {
                    flow.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(OnboardingIdentifiers.back)
            } else {
                Color.clear.frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }

            if total > 1 {
                ProgressView(value: Double(flow.completedCount + 1), total: Double(total))
                    .tint(.brand(.accent))
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("Step \(flow.completedCount + 1) of \(total)")
                    .accessibilityIdentifier(OnboardingIdentifiers.progress)
            } else {
                Spacer()
            }

            if flow.mode == .recovery {
                Button("Not Now", action: onboarding.dismissRecovery)
                    .accessibilityIdentifier(OnboardingIdentifiers.notNow)
            } else {
                Color.clear.frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// The layout every page shares: a symbol, a title and a message at the
/// top, the page's own content below, and its buttons pinned at the
/// bottom. The content scrolls when Dynamic Type makes it tall.
struct OnboardingPage<Content: View, Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                actions()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// The page's main button, full width.
struct OnboardingPrimaryButton: View {
    let title: LocalizedStringKey
    var isDisabled = false
    var identifier = OnboardingIdentifiers.primary
    let action: () -> Void

    init(
        _ title: LocalizedStringKey, isDisabled: Bool = false, identifier: String = OnboardingIdentifiers.primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isDisabled = isDisabled
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .brandProminentButtonStyle()
        .controlSize(.large)
        .disabled(isDisabled)
        .accessibilityIdentifier(identifier)
    }
}

/// The page's skip button.
struct OnboardingSkipButton: View {
    var title: LocalizedStringKey = "Skip for Now"
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(OnboardingIdentifiers.skip)
    }
}

#if DEBUG
    #Preview("Onboarding") {
        let environment = AppEnvironment.preview()
        OnboardingView()
            .appEnvironment(environment)
            .modelContainer(PersistenceController.previewContainer())
            .task {
                environment.onboarding.restart()
                await environment.speechModels.start()
            }
    }
#endif
