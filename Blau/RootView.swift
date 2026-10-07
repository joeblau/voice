import BlauRealtime
import SwiftUI

/// Top-level view hosted by the app's window: the (still empty) main screen
/// in a navigation stack. The main screen scaffold (#40) fills it in.
///
/// It already offers the two xAI key entry points (#33): Settings (the gear,
/// bottom-left) and, while no usable key is stored (none, or an unreadable
/// one), the onboarding step. DEBUG builds add a button to the top bar that
/// opens the debug menu (feature flags, environment, lifecycle). UI and launch
/// tests anchor on `accessibilityIdentifier`.
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

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
    RootView()
        .appEnvironment(.preview())
}
