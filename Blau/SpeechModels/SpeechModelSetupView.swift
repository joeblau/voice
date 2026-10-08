import BlauTranscription
import SwiftUI

/// Shows the required speech models getting ready: download progress, the
/// one-time preparation (the Neural Engine compile), and what to do when
/// the download is waiting or failed. Onboarding's models page (#44) embeds
/// it, and the main screen shows it while the models aren't ready.
struct SpeechModelSetupView: View {
    @Environment(ModelManager.self) private var models

    enum Identifier {
        static let container = "blau.models.setup"
        static let progress = "blau.models.progress"
        static let status = "blau.models.status"
        static let action = "blau.models.action"
    }

    var body: some View {
        let status = models.setupStatus
        VStack(alignment: .leading, spacing: 12) {
            Label("Speech models", systemImage: "waveform")
                .font(.headline)

            switch status.phase {
            case .checking:
                ProgressView()
                    .accessibilityIdentifier(Identifier.progress)
                statusText("Checking speech models…")
            case .needsDownload:
                statusText(
                    "Blau needs \(status.totalBytes.formattedByteCount) of speech models to listen. They stay on this iPhone."
                )
                actionButton("Download") { await downloadRequired() }
            case .downloading:
                ProgressView(value: status.fractionCompleted)
                    .accessibilityIdentifier(Identifier.progress)
                    .accessibilityValue(
                        Text(status.fractionCompleted.formatted(.percent.precision(.fractionLength(0)))))
                statusText(
                    "Downloading \(status.bytesReceived.formattedByteCount) of \(status.totalBytes.formattedByteCount)")
            case .waiting(.unmeteredNetwork):
                ProgressView(value: status.fractionCompleted)
                    .accessibilityIdentifier(Identifier.progress)
                statusText(
                    "Waiting for Wi-Fi to download \((status.totalBytes - status.bytesReceived).formattedByteCount).")
                actionButton("Download Using Cellular Data") { models.allowExpensiveNetworkThisSession() }
            case .waiting(.connection):
                ProgressView(value: status.fractionCompleted)
                    .accessibilityIdentifier(Identifier.progress)
                statusText("Waiting for an internet connection. The download resumes on its own.")
            case .preparing:
                ProgressView()
                    .accessibilityIdentifier(Identifier.progress)
                statusText("Preparing the models for this iPhone. This takes a few seconds the first time.")
            case .failed(let id, let failure):
                statusText("\(id.displayName): \(failure.message)")
                actionButton("Try Again") { await models.download(id) }
            case .ready:
                statusText("Ready.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Identifier.container)
        .animation(.default, value: status.phase)
    }

    private func statusText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(Identifier.status)
    }

    private func actionButton(_ title: LocalizedStringKey, action: @escaping @MainActor () async -> Void) -> some View {
        Button(title) {
            Task { await action() }
        }
        .brandProminentButtonStyle()
        .accessibilityIdentifier(Identifier.action)
    }

    private func downloadRequired() async {
        for descriptor in models.manifest.required {
            await models.download(descriptor.id)
        }
    }
}

#Preview("Downloading") {
    let models = SpeechModels.fixtureManager(delayPerChunk: .milliseconds(60))
    SpeechModelSetupView()
        .environment(models)
        .padding()
        .task { await models.start() }
}
