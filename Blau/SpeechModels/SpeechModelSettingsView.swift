import BlauTranscription
import SwiftUI

/// Settings for the on-device speech models: network policy, automatic
/// download of the extra speech models, per-model status and disk usage, and
/// delete. Settings links here through ``SpeechModelsSettingsSection``.
struct SpeechModelSettingsView: View {
    @Environment(ModelManager.self) private var models
    @State private var pendingDeletion: ModelID?

    enum Identifier {
        static let link = "blau.models.settingsLink"
        static let wifiOnly = "blau.models.settings.wifiOnly"
        static let optional = "blau.models.settings.optional"
        static let total = "blau.models.settings.total"
        static func row(_ id: ModelID) -> String { "blau.models.row.\(id.rawValue)" }
        static func status(_ id: ModelID) -> String { "blau.models.row.\(id.rawValue).status" }
        static func download(_ id: ModelID) -> String { "blau.models.row.\(id.rawValue).download" }
        static func delete(_ id: ModelID) -> String { "blau.models.row.\(id.rawValue).delete" }
    }

    var body: some View {
        @Bindable var models = models
        Form {
            Section {
                Toggle("Download on Wi-Fi Only", isOn: wifiOnly)
                    .accessibilityIdentifier(Identifier.wifiOnly)
                Toggle("Download Extra Speech Models", isOn: $models.preferences.downloadsOptionalModels)
                    .accessibilityIdentifier(Identifier.optional)
            } footer: {
                Text(
                    "Wi-Fi only also skips Low Data Mode networks. The extra speech models add punctuation after each sentence and keep transcription light when your iPhone is hot or low on battery."
                )
            }

            Section {
                ForEach(models.manifest.models) { descriptor in
                    row(descriptor)
                }
            } header: {
                Text("Models")
            } footer: {
                storageFooter
            }
        }
        .navigationTitle("Speech Models")
        .task { await models.refreshDiskUsage() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { id in
            Button("Delete", role: .destructive) {
                Task { await models.delete(id) }
            }
        } message: { id in
            Text(id.deletionNote)
        }
    }

    private var wifiOnly: Binding<Bool> {
        Binding(
            get: { models.preferences.downloadPolicy == .wifiOnly },
            set: { models.preferences.downloadPolicy = $0 ? .wifiOnly : .anyNetwork }
        )
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "" }
        return String(localized: "Delete \(pendingDeletion.displayName)?")
    }

    private func row(_ descriptor: ModelDescriptor) -> some View {
        let id = descriptor.id
        let state = models.state(of: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(id.displayName)
                    .font(.body)
                if !id.isRequired {
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions(for: id, state: state)
            }
            Text(id.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction = state.downloadFraction {
                ProgressView(value: fraction)
            }
            Text(statusLine(descriptor, state: state))
                .font(.caption)
                .foregroundStyle(statusColor(state))
                .accessibilityIdentifier(Identifier.status(id))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Identifier.row(id))
    }

    @ViewBuilder
    private func actions(for id: ModelID, state: ModelState) -> some View {
        switch state {
        case .notDownloaded, .failed:
            Button("Download") { Task { await models.download(id) } }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(Identifier.download(id))
        case .queued, .waiting, .downloading, .preparing, .ready:
            Button("Delete", role: .destructive) { pendingDeletion = id }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(Identifier.delete(id))
        }
    }

    private func statusLine(_ descriptor: ModelDescriptor, state: ModelState) -> String {
        let onDisk = models.diskUsage[descriptor.id, default: 0]
        switch state {
        case .notDownloaded:
            return String(localized: "Not downloaded · \(descriptor.totalBytes.formattedByteCount)")
        case .queued:
            return String(localized: "Queued · \(descriptor.totalBytes.formattedByteCount)")
        case .waiting(.unmeteredNetwork):
            return String(localized: "Waiting for Wi-Fi · \(descriptor.totalBytes.formattedByteCount)")
        case .waiting(.connection):
            return String(localized: "Waiting for a connection · \(descriptor.totalBytes.formattedByteCount)")
        case .downloading(let received, let total):
            return String(localized: "Downloading \(received.formattedByteCount) of \(total.formattedByteCount)")
        case .preparing:
            return String(localized: "Preparing for this iPhone…")
        case .ready:
            return String(localized: "Ready · \(onDisk.formattedByteCount)")
        case .failed(let failure):
            return failure.message
        }
    }

    private func statusColor(_ state: ModelState) -> Color {
        if case .failed = state { return .red }
        return .secondary
    }

    private var storageFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Using \(models.totalDiskUsage.formattedByteCount) on this iPhone.")
                .accessibilityIdentifier(Identifier.total)
            if models.isExcludedFromBackup == false {
                Text("Couldn't exclude the models from backups.")
                    .foregroundStyle(.red)
            } else {
                Text(
                    "Models stay on this iPhone and aren't included in iCloud or device backups. Blau downloads them again when needed."
                )
            }
        }
    }
}

/// The Settings section that opens ``SpeechModelSettingsView``. It needs
/// a `NavigationStack` and a `ModelManager` in the environment.
struct SpeechModelsSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                SpeechModelSettingsView()
            } label: {
                Label("Speech Models", systemImage: "waveform.circle")
            }
            .accessibilityIdentifier(SpeechModelSettingsView.Identifier.link)
        } footer: {
            Text("On-device models for listening and transcription, and when they download.")
        }
    }
}

#Preview {
    let models = SpeechModels.fixtureManager()
    NavigationStack {
        SpeechModelSettingsView()
    }
    .environment(models)
    .task { await models.start() }
}
