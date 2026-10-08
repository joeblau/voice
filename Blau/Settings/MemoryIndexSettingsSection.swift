import BlauMemory
import BlauPersistence
import SwiftUI

/// Settings → Knowledge → Search Index: the on-device search index (#63). Shows whether it is
/// up to date, the progress of a rebuild or of embedding, how much is
/// indexed and when it was last rebuilt, and offers a rebuild.
struct MemoryIndexSettingsSection: View {
    nonisolated static let statusIdentifier = "settings.memory.status"
    nonisolated static let progressIdentifier = "settings.memory.progress"
    nonisolated static let rebuildIdentifier = "settings.memory.rebuild"

    @Environment(MemoryIndexingController.self) private var indexing

    var body: some View {
        let presentation = MemoryIndexPresentation(indexing.status)
        Section {
            LabeledContent {
                Text(presentation.title)
                    .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
            } label: {
                Label("Search Index", systemImage: presentation.systemImage)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(Self.statusIdentifier)

            if let job = presentation.job {
                ProgressView(value: job.fractionCompleted) {
                    Text(job.label)
                } currentValueLabel: {
                    Text(job.count)
                }
                .accessibilityIdentifier(Self.progressIdentifier)
            }

            if let indexed = presentation.indexed {
                LabeledContent("Passages", value: indexed)
            }

            if let lastRebuild = presentation.lastRebuild {
                LabeledContent("Last Rebuilt") {
                    Text(lastRebuild, format: .relative(presentation: .named))
                }
            }

            if indexing.status != nil {
                Button("Rebuild Index") { indexing.rebuild() }
                    .disabled(!presentation.canRebuild)
                    .accessibilityIdentifier(Self.rebuildIdentifier)
            }
        } header: {
            Text("Search Index")
        } footer: {
            Text(presentation.detail)
        }
    }
}

#if DEBUG
    #Preview {
        Form {
            MemoryIndexSettingsSection()
        }
        .environment(
            MemoryIndexingController(
                persistence: PersistenceController.preview(), embedder: nil, performance: nil))
    }
#endif
