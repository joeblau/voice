import BlauRealtime
import SwiftUI

/// The onboarding step that connects the user's xAI account. The full
/// onboarding flow (#44) hosts it between its other steps.
///
/// The user can skip it; features that need xAI stay unavailable until a key
/// is added here or in Settings.
struct XAIKeyOnboardingStep: View {
    @Environment(XAIAccount.self) private var account

    /// Called when the step is done, connected or skipped.
    var onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "key.horizontal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Connect your xAI account")
                    .font(.title.bold())

                Text(
                    "Blau talks with Grok using your own xAI API key. "
                        + "It's stored in your iCloud Keychain, so you only enter it once for all your devices, "
                        + "and it's only ever sent to xAI."
                )
                .foregroundStyle(.secondary)

                if let consoleURL = URL(string: "https://console.x.ai") {
                    Link(destination: consoleURL) {
                        Label("Get a key at console.x.ai", systemImage: "arrow.up.right.square")
                    }
                }

                if case .connected(let key) = account.status {
                    Label("Connected (\(key.redacted))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier(XAIKeyIdentifiers.status)
                    Button("Continue", action: onFinish)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    XAIKeyEntryView(onConnected: onFinish)
                    Button("Skip for Now", action: onFinish)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(XAIKeyIdentifiers.skip)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

#if DEBUG
    #Preview {
        XAIKeyOnboardingStep(onFinish: {})
            .environment(XAIAccount.preview())
    }
#endif
