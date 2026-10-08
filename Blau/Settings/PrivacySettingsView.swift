import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import os

/// Accessibility identifiers for Settings → Privacy & Data, shared with UI
/// tests.
enum PrivacySettingsIdentifiers {
    static func delete(_ scope: DataEraseScope) -> String { "settings.privacy.delete.\(scope.rawValue)" }
    static let confirm = "settings.privacy.confirm"
    static let result = "settings.privacy.result"
}

/// Settings → Privacy & Data: what Blau keeps and where, and deleting it.
///
/// Deleting goes through `DataEraser`, record by record, so the deletions
/// sync to iCloud and the user's other devices. Nothing is deleted while a
/// conversation is recording: the pipeline is writing to the same store.
struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @State private var pending: DataEraseScope?
    @State private var pendingCount = 0
    @State private var isErasing = false
    @State private var result: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Label(
                    "Your conversations, knowledge and voiceprint are stored on this iPhone and in your private iCloud.",
                    systemImage: "lock.icloud")
                Label(
                    "Speech is transcribed on this iPhone. Only the text of what you say is sent to xAI to get Grok's reply.",
                    systemImage: "waveform.badge.mic")
                Label("Your xAI key stays in your iCloud Keychain. There is no Blau server.", systemImage: "key")
            } header: {
                Text("Where Your Data Lives")
            }
            .font(.subheadline)

            Section {
                ForEach(DataEraseScope.allCases, id: \.self) { scope in
                    Button(Self.buttonTitle(scope), role: .destructive) {
                        confirm(scope)
                    }
                    .disabled(isErasing)
                    .accessibilityIdentifier(PrivacySettingsIdentifiers.delete(scope))
                }
                if let result {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(PrivacySettingsIdentifiers.result)
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Delete Data")
            } footer: {
                Text(
                    "Deleting removes the data from this iPhone, from iCloud and from your other devices. "
                        + "It can't be undone. Files you exported or shared aren't affected."
                )
            }
        }
        .navigationTitle("Privacy & Data")
        .confirmationDialog(
            pending.map(Self.confirmationTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { scope in
            Button(Self.buttonTitle(scope).replacingOccurrences(of: "…", with: ""), role: .destructive) {
                Task { await erase(scope) }
            }
            .accessibilityIdentifier(PrivacySettingsIdentifiers.confirm)
        } message: { scope in
            Text(Self.confirmationMessage(scope, count: pendingCount))
        }
    }

    private func confirm(_ scope: DataEraseScope) {
        result = nil
        problem = nil
        pendingCount = (try? DataEraser.count(scope, in: modelContext)) ?? 0
        pending = scope
    }

    private func erase(_ scope: DataEraseScope) async {
        isErasing = true
        defer { isErasing = false }
        if await environment.audio.isCapturing || environment.voiceLoop.phase.isActive {
            problem = String(localized: "Stop the conversation first, then delete.")
            return
        }
        do {
            let summary = try DataEraser.erase(scope, in: modelContext)
            if scope.components.contains(.conversations) {
                // The share sheet's copy holds the full text of every
                // conversation; it goes with them.
                ConversationExportFiles.removeAll()
            }
            result = Self.resultMessage(scope, summary: summary)
        } catch {
            problem = String(localized: "Couldn't delete the data. Nothing was changed. Try again.")
        }
    }

    // MARK: Wording

    static func buttonTitle(_ scope: DataEraseScope) -> String {
        switch scope {
        case .conversations: String(localized: "Delete All Conversations…")
        case .knowledge: String(localized: "Delete Knowledge Base…")
        case .voiceprint: String(localized: "Delete Voiceprint…")
        case .everything: String(localized: "Delete All Data…")
        }
    }

    static func confirmationTitle(_ scope: DataEraseScope) -> String {
        switch scope {
        case .conversations: String(localized: "Delete all conversations?")
        case .knowledge: String(localized: "Delete the knowledge base?")
        case .voiceprint: String(localized: "Delete your voiceprint?")
        case .everything: String(localized: "Delete all your data?")
        }
    }

    static func confirmationMessage(_ scope: DataEraseScope, count: Int) -> String {
        let what: String =
            switch scope {
            case .conversations:
                count == 1 ? String(localized: "1 conversation") : String(localized: "\(count) conversations")
            case .knowledge: String(localized: "\(count) items in your knowledge base")
            case .voiceprint: String(localized: "your voiceprint")
            case .everything: String(localized: "every conversation, your knowledge base and your voiceprint")
            }
        var message = String(localized: "This deletes \(what) from this iPhone, iCloud and your other devices.")
        if scope == .voiceprint || scope == .everything {
            message += " " + String(localized: "You'll need to enroll again for Voice ID.")
        }
        return message
    }

    static func resultMessage(_ scope: DataEraseScope, summary: DataEraseSummary) -> String {
        switch scope {
        case .conversations:
            summary.conversations == 1
                ? String(localized: "Deleted 1 conversation.")
                : String(localized: "Deleted \(summary.conversations) conversations.")
        case .knowledge: String(localized: "Deleted the knowledge base.")
        case .voiceprint: String(localized: "Deleted your voiceprint.")
        case .everything: String(localized: "Deleted all your data.")
        }
    }
}

#if DEBUG
    #Preview("Privacy") {
        NavigationStack {
            PrivacySettingsView()
        }
        .appEnvironment(.preview())
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
