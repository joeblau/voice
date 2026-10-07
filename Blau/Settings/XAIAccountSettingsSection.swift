import BlauPersistence
import BlauRealtime
import SwiftUI

/// Settings → xAI account: shows whether a key is stored, lets the user add,
/// replace or remove it, and shows key problems (including ones hit during
/// a conversation, such as running out of credits).
struct XAIAccountSettingsSection: View {
    @Environment(XAIAccount.self) private var account
    @State private var isReplacing = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        Section {
            switch account.status {
            case .unknown:
                ProgressView()
            case .noKey:
                Text("Not connected. Blau needs your own xAI API key to talk with Grok.")
                    .accessibilityIdentifier(XAIKeyIdentifiers.status)
                XAIKeyEntryView()
            case .connected(let key):
                connectedRows(key)
            case .unavailable(let error) where account.needsKeyEntry:
                // The stored item is unreadable (e.g. damaged, or written in a
                // format this build doesn't accept). Reloading would fail the
                // same way, so offer to overwrite it with a new key or remove it.
                if account.problem == nil {
                    XAIProblemView(problem: XAIAccountProblem(error))
                }
                XAIKeyEntryView(connectTitle: "Replace Key")
                Button("Remove Key…", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(account.isBusy)
                .accessibilityIdentifier(XAIKeyIdentifiers.remove)
            case .unavailable(let error):
                XAIProblemView(problem: XAIAccountProblem(error))
                Button("Try Again") {
                    Task { await account.load() }
                }
            }
        } header: {
            Text("xAI account")
        } footer: {
            Text(
                "Your key is kept in your iCloud Keychain, so it's available on your other devices. "
                    + "Blau talks to xAI directly with it; there is no Blau server. "
                    + "Manage keys and credits at console.x.ai."
            )
        }
        .confirmationDialog(
            "Remove your xAI API key?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                Task { await account.removeKey() }
            }
        } message: {
            Text("This removes the key from every device that uses your iCloud Keychain.")
        }
    }

    @ViewBuilder
    private func connectedRows(_ key: XAIAccount.ConnectedKey) -> some View {
        LabeledContent("API key") {
            Text(key.redacted)
                .monospaced()
        }
        .accessibilityIdentifier(XAIKeyIdentifiers.status)
        if let name = key.name {
            LabeledContent("Name", value: name)
        }

        if isReplacing {
            XAIKeyEntryView(connectTitle: "Replace Key") {
                isReplacing = false
            }
            Button("Cancel") {
                account.dismissProblem()
                isReplacing = false
            }
            .buttonStyle(.borderless)
        } else {
            if let problem = account.problem {
                XAIProblemView(problem: problem)
            }
            Button("Replace Key…") {
                account.dismissProblem()
                isReplacing = true
            }
            .accessibilityIdentifier(XAIKeyIdentifiers.replace)
            Button("Remove Key…", role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(account.isBusy)
            .accessibilityIdentifier(XAIKeyIdentifiers.remove)
        }
    }
}

/// The settings sheet presented from the main screen. The full settings
/// screen (#43) adds its sections here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                XAIAccountSettingsSection()
                ICloudSettingsSection()
                SpeechModelsSettingsSection()
                Section("Developer") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                    .accessibilityIdentifier(DiagnosticsView.Identifier.open)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
    #Preview("No key") {
        SettingsView()
            .environment(XAIAccount.preview())
            .environment(PersistenceController.preview())
            .environment(AppDiagnostics(store: nil))
            .environment(SpeechModels.fixtureManager())
    }
#endif
