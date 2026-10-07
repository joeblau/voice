import BlauRealtime
import BlauTranscription
import SwiftUI

/// Top-level view hosted by the app's window: the (still empty) main screen
/// in a navigation stack. The main screen scaffold (#40) fills it in.
///
/// It already offers the two xAI key entry points (#33): Settings (the gear,
/// bottom-left) and, while no usable key is stored (none, or an unreadable
/// one), the onboarding step. Until onboarding (#44) exists it also shows the
/// speech-model setup card while the required models aren't ready; Settings
/// links to the speech-model settings. DEBUG builds add a button to the top
/// bar that opens the debug menu (feature flags, environment, lifecycle). UI
/// and launch tests anchor on `accessibilityIdentifier`.
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

    @Environment(ModelManager.self) private var models
    @State private var isShowingSettings = false
    @State private var isShowingKeyOnboarding = false

    var body: some View {
        NavigationStack {
            MainScreen(onConnectAccount: { isShowingKeyOnboarding = true })
                .overlay(alignment: .bottomLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .padding()
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier(XAIKeyIdentifiers.openSettings)
                }
                .toolbar {
                    #if DEBUG
                        ToolbarItem(placement: .topBarTrailing) {
                            DebugMenuButton()
                        }
                    #endif
                }
        }
        // Outside the gear's overlay, so the card takes its own space below
        // the content and the gear sits above it instead of under it.
        .safeAreaInset(edge: .bottom) {
            // Hidden while checking, so an offline launch with every
            // model installed doesn't flash the card.
            if !models.isReady && models.setupStatus.phase != .checking {
                SpeechModelSetupView()
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: models.isReady)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isShowingKeyOnboarding) {
            XAIKeyOnboardingStep {
                isShowingKeyOnboarding = false
            }
        }
    }
}

/// The empty main screen, plus the xAI onboarding button while no usable key
/// is stored.
struct MainScreen: View {
    /// Opens the xAI key onboarding step.
    var onConnectAccount: () -> Void = {}

    @Environment(XAIAccount.self) private var account

    var body: some View {
        VStack(spacing: 24) {
            Text("Blau")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(RootView.accessibilityIdentifier)

            if account.needsKeyEntry {
                Button("Connect Your xAI Account", action: onConnectAccount)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(XAIKeyIdentifiers.openOnboarding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Main screen") {
    let environment = AppEnvironment.preview()
    RootView()
        .appEnvironment(environment)
        .environment(AppDiagnostics(store: nil))
        .task { await environment.speechModels.start() }
}
