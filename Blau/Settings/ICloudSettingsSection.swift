import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import UIKit
import os

/// Settings → iCloud: sync status and exporting the conversations.
struct ICloudSettingsView: View {
    var body: some View {
        Form {
            ICloudSettingsSection()
            ConversationExportSection()
        }
        .navigationTitle("iCloud")
    }
}

/// Accessibility identifiers for Settings → iCloud → Export, shared with UI
/// tests.
enum ConversationExportIdentifiers {
    static let prepare = "settings.icloud.export.prepare"
    static let share = "settings.icloud.export.share"
}

/// Export Conversations: writes every conversation as one Markdown file
/// (`ConversationExporter`) and offers it through the share sheet, so it can
/// go to Files, iCloud Drive, Mail or another app.
struct ConversationExportSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var export: Export?
    @State private var isPreparing = false
    @State private var failed = false

    struct Export: Equatable {
        var url: URL
        var conversations: Int
    }

    var body: some View {
        Section {
            if let export {
                ShareLink(
                    item: export.url,
                    preview: SharePreview(export.url.lastPathComponent, image: Image(systemName: "doc.text"))
                ) {
                    Label(
                        export.conversations == 1
                            ? "Share 1 Conversation" : "Share \(export.conversations) Conversations",
                        systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(ConversationExportIdentifiers.share)
            } else {
                Button {
                    prepare()
                } label: {
                    HStack {
                        Label("Export Conversations", systemImage: "doc.text")
                        Spacer()
                        if isPreparing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isPreparing)
                .accessibilityIdentifier(ConversationExportIdentifiers.prepare)
            }
            if failed {
                Text("Couldn't export your conversations. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text(
                "Saves every conversation, with its topics, as a Markdown text file you can keep in Files or "
                    + "iCloud Drive."
            )
        }
    }

    private func prepare() {
        isPreparing = true
        failed = false
        defer { isPreparing = false }
        do {
            let snapshots = try ConversationExporter.snapshots(in: modelContext)
            let directory = URL.temporaryDirectory.appending(path: "Export", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try ConversationExporter().write(snapshots, exportedAt: Date(), to: directory)
            export = Export(url: url, conversations: snapshots.count)
            Log.ui.notice("Exported \(snapshots.count, privacy: .public) conversations")
        } catch {
            Log.ui.error("Conversation export failed: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }
}

/// The iCloud section of Settings: sync status, the account, and when data
/// last synced. Reads the `PersistenceController` from the environment.
struct ICloudSettingsSection: View {
    nonisolated static let statusIdentifier = "settings.icloud.status"
    nonisolated static let accountIdentifier = "settings.icloud.account"

    @Environment(PersistenceController.self) private var persistence
    @Environment(\.openURL) private var openURL

    var body: some View {
        let presentation = SyncStatusPresentation(persistence.syncState)
        Section {
            LabeledContent {
                Text(presentation.title)
                    .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
            } label: {
                Label("iCloud Sync", systemImage: presentation.systemImage)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(Self.statusIdentifier)

            if let accountStatus = persistence.accountStatus {
                LabeledContent("iCloud Account", value: accountStatus.localizedDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(Self.accountIdentifier)
            }

            if let lastSync = presentation.lastSync {
                LabeledContent("Last Synced") {
                    Text(lastSync, format: .relative(presentation: .named))
                }
            }

            if presentation.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(presentation.detail)
        }
    }
}
