import BlauRealtime
import SwiftUI

/// Top-level view hosted by the app's window. Placeholder until the main
/// screen scaffold lands (#40); UI and launch tests anchor on its
/// accessibility identifier. It already offers the two xAI key entry points:
/// Settings (bottom-left) and, while no key is stored, the onboarding step.
struct RootView: View {
    nonisolated static let accessibilityIdentifier = "blau.root"

    @Environment(XAIAccount.self) private var account
    @State private var isShowingSettings = false
    @State private var isShowingKeyOnboarding = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Blau")
                .font(.largeTitle)
                .accessibilityIdentifier(Self.accessibilityIdentifier)

            if account.status == .noKey {
                Button("Connect Your xAI Account") {
                    isShowingKeyOnboarding = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(XAIKeyIdentifiers.openOnboarding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#if DEBUG
    #Preview {
        RootView()
            .environment(XAIAccount.preview())
    }
#endif
