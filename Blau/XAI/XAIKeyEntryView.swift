import BlauRealtime
import SwiftUI

/// Accessibility identifiers shared by the xAI key screens and their UI tests.
enum XAIKeyIdentifiers {
    static let field = "xai.apiKey.field"
    static let connect = "xai.apiKey.connect"
    static let problem = "xai.apiKey.problem"
    static let problemTitle = "xai.apiKey.problem.title"
    static let saveAnyway = "xai.apiKey.saveAnyway"
    static let status = "xai.account.status"
    static let replace = "xai.account.replace"
    static let remove = "xai.account.remove"
    static let openOnboarding = "xai.onboarding.open"
    static let skip = "xai.onboarding.skip"
    static let openSettings = "blau.settings.open"
}

/// Key entry used by both Settings → xAI account and onboarding: a secure
/// field, a Connect button that checks the key with xAI before storing it,
/// and the problem to fix when that fails.
///
/// Failures are recoverable in place: the field keeps what was typed so the
/// user can correct it and try again, and editing it clears the error.
struct XAIKeyEntryView: View {
    @Environment(XAIAccount.self) private var account

    var connectTitle: LocalizedStringKey = "Connect"
    var onConnected: () -> Void = {}

    @State private var input = ""
    @FocusState private var isFieldFocused: Bool

    private var canSubmit: Bool {
        !account.isBusy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("xAI API key", text: $input, prompt: Text("Paste your xAI API key"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .submitLabel(.go)
                .focused($isFieldFocused)
                .onSubmit(connect)
                .disabled(account.isBusy)
                .accessibilityIdentifier(XAIKeyIdentifiers.field)
                .onChange(of: input) {
                    if account.problem != nil {
                        account.dismissProblem()
                    }
                }

            if let problem = account.problem {
                XAIProblemView(problem: problem) {
                    Task {
                        if await account.saveWithoutVerifying() {
                            input = ""
                            onConnected()
                        }
                    }
                }
            }

            Button(action: connect) {
                HStack(spacing: 8) {
                    if account.activity == .validating || account.activity == .saving {
                        ProgressView()
                        Text("Checking with xAI…")
                    } else {
                        Text(connectTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .brandProminentButtonStyle()
            .disabled(!canSubmit)
            .accessibilityIdentifier(XAIKeyIdentifiers.connect)
        }
    }

    private func connect() {
        guard canSubmit else { return }
        isFieldFocused = false
        Task {
            if await account.connect(apiKey: input) {
                input = ""
                onConnected()
            }
        }
    }
}

/// A key problem and how to recover from it.
struct XAIProblemView: View {
    let problem: XAIAccountProblem
    var onSaveAnyway: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(problem.title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier(XAIKeyIdentifiers.problemTitle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(problem.message)
                .font(.footnote)
                .foregroundStyle(Color.brand(.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
            if problem.canSaveAnyway {
                Button("Save Without Checking", action: onSaveAnyway)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier(XAIKeyIdentifiers.saveAnyway)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(XAIKeyIdentifiers.problem)
    }
}

#if DEBUG
    extension XAIAccount {
        /// An account for previews: in-memory store, every key accepted.
        static func preview(key: XAIAPIKey? = nil) -> XAIAccount {
            XAIAccount(store: InMemoryAPIKeyStore(key: key), validator: PreviewValidator())
        }

        private struct PreviewValidator: XAIKeyValidating {
            func validate(_ key: XAIAPIKey) async throws(XAIError) -> XAIKeyStatus {
                XAIKeyStatus(name: "Preview key")
            }
        }
    }

    #Preview {
        Form {
            XAIKeyEntryView()
        }
        .environment(XAIAccount.preview())
    }
#endif
