import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import UIKit
import os

/// Settings → iCloud: sync status, the Markdown copy of every conversation
/// in iCloud Drive → Blau (`MarkdownExportSettingsSection`, #78), and a
/// one-off export through the share sheet.
struct ICloudSettingsView: View {
    var body: some View {
        Form {
            ICloudSettingsSection()
            MarkdownExportSettingsSection()
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
    static let again = "settings.icloud.export.again"
}

/// The share sheet's copy of the conversations: one Markdown file in the
/// app's temporary directory.
///
/// It holds the full text of every conversation, so it never outlives what
/// it copies for long: each export replaces the last one, and deleting
/// conversations in Privacy & Data removes it (`removeAll()`).
enum ConversationExportFiles {
    static var directory: URL {
        URL.temporaryDirectory.appending(path: "Export", directoryHint: .isDirectory)
    }

    /// Formats and writes `snapshots`, replacing earlier exports. Runs off
    /// the main actor: a long history takes a while to format.
    static func write(_ snapshots: [ConversationExporter.Snapshot], exportedAt date: Date) throws -> URL {
        removeAll()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ConversationExporter().write(snapshots, exportedAt: date, to: directory)
    }

    /// Removes every exported file.
    static func removeAll() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was exported.
        } catch {
            Log.ui.error("Couldn't remove exported conversations: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Export Conversations: writes every conversation as one Markdown file
/// (`ConversationExporter`) and offers it through the share sheet, so it can
/// go to Files, iCloud Drive, Mail or another app.
///
/// The conversations are read on the main context, then formatted and
/// written off the main actor. The file is a snapshot: "Export Again" makes
/// a new one with the conversations recorded since.
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
            }
            Button {
                Task { await prepare() }
            } label: {
                HStack {
                    Label(
                        export == nil ? "Export Conversations" : "Export Again",
                        systemImage: export == nil ? "doc.text" : "arrow.clockwise")
                    Spacer()
                    if isPreparing {
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparing)
            .accessibilityIdentifier(
                export == nil ? ConversationExportIdentifiers.prepare : ConversationExportIdentifiers.again)
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

    private func prepare() async {
        isPreparing = true
        failed = false
        defer { isPreparing = false }
        do {
            let snapshots = try ConversationExporter.snapshots(in: modelContext)
            let url = try await Task.detached(priority: .userInitiated) {
                try ConversationExportFiles.write(snapshots, exportedAt: Date())
            }.value
            export = Export(url: url, conversations: snapshots.count)
            Log.ui.notice("Exported \(snapshots.count, privacy: .public) conversations")
        } catch {
            Log.ui.error("Conversation export failed: \(String(describing: error), privacy: .public)")
            export = nil
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

#if DEBUG
    #Preview("iCloud") {
        NavigationStack {
            ICloudSettingsView()
        }
        .environment(PersistenceController.preview())
        .environment(MarkdownExportController.local(persistence: .preview()))
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
