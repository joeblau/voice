import BlauPersistence
import BlauRealtime
import BlauTelemetry
import SwiftData
import SwiftUI
import os

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
            ConnectionTestRows()
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

/// Accessibility identifiers for Settings → xAI Account beyond the key
/// entry's (`XAIKeyIdentifiers`), shared with UI tests.
enum XAIAccountSettingsIdentifiers {
    static let testConnection = "settings.account.testConnection"
    static let connectionResult = "settings.account.connectionResult"
    static let usage = "settings.account.usage"
    static let cost = "settings.account.cost"
}

/// Test Connection: checks the stored key with xAI again and says how it
/// went, without touching the key.
private struct ConnectionTestRows: View {
    @Environment(XAIAccount.self) private var account

    var body: some View {
        Button {
            Task { await account.testConnection() }
        } label: {
            HStack {
                Text("Test Connection")
                Spacer()
                if account.connectionCheck == .testing {
                    ProgressView()
                }
            }
        }
        .disabled(account.isBusy)
        .accessibilityIdentifier(XAIAccountSettingsIdentifiers.testConnection)

        switch account.connectionCheck {
        case .notTested, .testing:
            EmptyView()
        case .succeeded(let date, let realtimeVerified):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(realtimeVerified ? "Connected to xAI" : "Key accepted")
                    Text(
                        realtimeVerified
                            ? "Checked \(date.formatted(.relative(presentation: .named)))."
                            : "xAI accepted the key, but couldn't confirm voice access. Blau checks again when you start talking."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: realtimeVerified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(realtimeVerified ? .green : .orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(XAIAccountSettingsIdentifiers.connectionResult)
        case .failed(let problem):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title)
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(XAIAccountSettingsIdentifiers.connectionResult)
        }
    }
}

/// Settings → xAI Account → Usage: this month's Grok speaking time and
/// turns from the stored conversations, and what they likely cost at
/// xAI's speech-to-speech rates (`RealtimeUsageEstimator`).
struct UsageEstimateSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var estimate: RealtimeUsageEstimate?
    @State private var failed = false

    private let pricing = RealtimePricing.grokVoiceThinkFast

    var body: some View {
        Section {
            if let estimate {
                LabeledContent("Grok speaking", value: Self.minutes(estimate.agentMinutes))
                    .accessibilityIdentifier(XAIAccountSettingsIdentifiers.usage)
                LabeledContent("Turns", value: estimate.textInputs.formatted())
                LabeledContent("Conversations", value: estimate.conversations.formatted())
                LabeledContent("Estimated cost") {
                    Text(Self.dollars(estimate.cost(at: pricing)))
                        .monospacedDigit()
                }
                .accessibilityIdentifier(XAIAccountSettingsIdentifiers.cost)
            } else if failed {
                Text("Couldn't read your conversations.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("This month")
        } footer: {
            Text(
                "An estimate from your saved conversations at xAI's voice rates "
                    + "(\(Self.dollars(pricing.audioPerMinute)) a minute of Grok speaking, "
                    + "\(Self.dollars(pricing.perTextInput)) a turn). Searches and voice previews are extra. "
                    + "Your exact usage is at console.x.ai."
            )
        }
        .task { refresh() }
    }

    private func refresh() {
        do {
            estimate = try RealtimeUsageEstimator.estimate(
                in: modelContext, period: RealtimeUsageEstimator.month(containing: Date()))
            failed = false
        } catch {
            Log.ui.error("Usage estimate failed: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }

    static func minutes(_ minutes: Double) -> String {
        Duration.seconds(Int64((minutes * 60).rounded())).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func dollars(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2...3)))
    }
}

/// Settings → xAI Account: the key, Test Connection and the usage estimate.
struct XAIAccountSettingsView: View {
    @Environment(XAIAccount.self) private var account

    var body: some View {
        Form {
            XAIAccountSettingsSection()
            if account.hasKey {
                UsageEstimateSection()
            }
        }
        .navigationTitle("xAI Account")
    }
}

#if DEBUG
    #Preview("Connected") {
        NavigationStack {
            XAIAccountSettingsView()
        }
        .environment(
            XAIAccount.preview(key: try? XAIAPIKey(validating: "xai-" + String(repeating: "Preview0", count: 6)))
        )
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
