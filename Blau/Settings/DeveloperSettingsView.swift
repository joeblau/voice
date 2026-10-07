import BlauCore
import BlauTelemetry
import SwiftUI
import os

/// Accessibility identifiers for Settings → Developer, shared with UI tests.
enum DeveloperSettingsIdentifiers {
    static let resetFlags = "settings.developer.resetFlags"
    static let exportLogs = "settings.developer.exportLogs"
    static let shareLogs = "settings.developer.shareLogs"
}

/// Settings → Developer: the performance HUD, feature flags, MetricKit
/// diagnostics and a log export.
///
/// The HUD toggle is `PerformanceHUDToggle` (#71), available in every
/// build; it applies at once: the HUD appears over the main screen as soon
/// as it is switched on. Flags can only be changed where overrides are
/// allowed, which is DEBUG builds (`FeatureFlags.allowsOverrides`); release
/// builds show the shipping values, disabled.
struct DeveloperSettingsView: View {
    @Environment(FeatureFlags.self) private var flags
    @State private var logExport: URL?
    @State private var isExportingLogs = false
    @State private var logExportFailed = false

    var body: some View {
        Form {
            Section {
                PerformanceHUDToggle()
            } footer: {
                PerformanceHUDToggle.footer
            }

            Section {
                FeatureFlagToggles(flags: flags, excluding: [.perfHUD])
                if flags.allowsOverrides {
                    Button("Reset All Overrides", role: .destructive) {
                        flags.resetOverrides()
                    }
                    .disabled(flags.overriddenFlags.isEmpty)
                    .accessibilityIdentifier(DeveloperSettingsIdentifiers.resetFlags)
                }
            } header: {
                Text("Feature Flags")
            } footer: {
                Text(
                    flags.allowsOverrides
                        ? "Overrides are stored on this device and apply to development builds only."
                        : "This build runs every feature at its shipping setting."
                )
            }

            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                .accessibilityIdentifier(DiagnosticsView.Identifier.open)

                if let logExport {
                    ShareLink(
                        item: logExport,
                        preview: SharePreview(logExport.lastPathComponent, image: Image(systemName: "doc.plaintext"))
                    ) {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(DeveloperSettingsIdentifiers.shareLogs)
                } else {
                    Button {
                        Task { await exportLogs() }
                    } label: {
                        HStack {
                            Label("Export Logs", systemImage: "doc.plaintext")
                            Spacer()
                            if isExportingLogs {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExportingLogs)
                    .accessibilityIdentifier(DeveloperSettingsIdentifiers.exportLogs)
                }
                if logExportFailed {
                    Text("Couldn't read the log. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Exports Blau's log messages from the last hour of this run as a text file to share with a "
                        + "developer. Blau logs what you say as private, so it is redacted."
                )
            }
        }
        .navigationTitle("Developer")
    }

    private func exportLogs() async {
        isExportingLogs = true
        logExportFailed = false
        defer { isExportingLogs = false }
        let header = SettingsSummary.version()
        let directory = URL.temporaryDirectory.appending(path: "Logs", directoryHint: .isDirectory)
        do {
            // Reading the unified log can take a few seconds; keep it off
            // the main actor.
            logExport = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try LogExporter().export(to: directory, header: header)
            }.value
        } catch {
            Log.ui.error("Log export failed: \(String(describing: error), privacy: .public)")
            logExportFailed = true
        }
    }
}

#if DEBUG
    #Preview("Developer") {
        NavigationStack {
            DeveloperSettingsView()
        }
        .appEnvironment(.preview(flags: [.perfHUD: true]))
        .environment(AppDiagnostics(store: nil))
    }
#endif
