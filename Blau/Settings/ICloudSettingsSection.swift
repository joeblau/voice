import BlauPersistence
import SwiftUI
import UIKit

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
