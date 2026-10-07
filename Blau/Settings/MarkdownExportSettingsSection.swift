import BlauPersistence
import SwiftUI

/// Accessibility identifiers for Settings → Markdown Export, shared with UI
/// tests.
enum MarkdownExportIdentifiers {
    static let exportNow = "settings.export.now"
    static let automatic = "settings.export.automatic"
    static let status = "settings.export.status"
}

/// Settings → Markdown Export (#78): export every conversation to iCloud
/// Drive → Blau now, or keep the files up to date automatically, and what
/// the last export did.
struct MarkdownExportSettingsSection: View {
    @Environment(MarkdownExportController.self) private var export

    var body: some View {
        @Bindable var export = export
        Section {
            Button {
                Task { await export.exportNow() }
            } label: {
                HStack {
                    Label("Export Now", systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if export.isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(export.isExporting)
            .accessibilityIdentifier(MarkdownExportIdentifiers.exportNow)

            Toggle("Export Automatically", isOn: $export.isAutoExportEnabled)
                .accessibilityIdentifier(MarkdownExportIdentifiers.automatic)

            if let status = MarkdownExportStatus(outcome: export.lastOutcome, lastExportedAt: export.lastExportedAt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.message)
                        .foregroundStyle(status.isWarning ? Color.orange : Color.secondary)
                    if let date = status.lastExportedAt {
                        Text("Last exported \(date, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(MarkdownExportIdentifiers.status)
            }
        } header: {
            Text("Markdown Export")
        } footer: {
            Text(
                "Saves each conversation as a Markdown file, with its topics and timestamps, in iCloud Drive → Blau. "
                    + "Automatic export updates a file when its conversation ends or changes. Blau replaces its "
                    + "files on every export, so keep your own notes in other files."
            )
        }
    }
}

/// What Settings says about the last export.
struct MarkdownExportStatus: Equatable {
    let message: String
    let isWarning: Bool
    let lastExportedAt: Date?

    /// `nil` until something has been exported or tried.
    init?(outcome: MarkdownExportController.Outcome?, lastExportedAt: Date?) {
        self.lastExportedAt = lastExportedAt
        switch outcome?.result {
        case nil:
            guard lastExportedAt != nil else { return nil }
            message = String(localized: "Your conversations are in iCloud Drive → Blau.")
            isWarning = false
        case .success(let report) where !report.failures.isEmpty:
            message = String(
                localized: "\(report.failures.count) conversations couldn't be exported. Blau will try again.")
            isWarning = true
        case .success(let report):
            message = Self.summary(of: report)
            isWarning = false
        case .failure(let error):
            message = Self.message(for: error)
            isWarning = true
        }
    }

    static func summary(of report: MarkdownExportReport) -> String {
        if report.changedCount == 0 {
            return String(localized: "\(report.exportedCount) conversations, all up to date.")
        }
        return String(
            localized:
                "\(report.exportedCount) conversations exported: \(report.created) new, \(report.updated + report.renamed) updated."
        )
    }

    static func message(for error: MarkdownExportError) -> String {
        switch error {
        case .iCloudDriveUnavailable:
            String(
                localized:
                    "iCloud Drive isn't available. Sign in to iCloud and turn on iCloud Drive for Blau in the Settings app."
            )
        case .notAvailableInThisBuild:
            String(localized: "This build isn't signed for iCloud, so it can't export to iCloud Drive.")
        case .storeUnavailable:
            String(localized: "Your conversations couldn't be read. Try again.")
        case .folderUnavailable:
            String(localized: "The Blau folder in iCloud Drive couldn't be opened. Try again.")
        }
    }
}
