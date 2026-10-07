import BlauCore
import BlauMemory
import BlauPersistence
import SwiftData
import SwiftUI

/// Accessibility identifiers for Settings → Knowledge, shared with UI tests.
enum KnowledgeSettingsIdentifiers {
    static let view = "settings.knowledge.view"
    static let memoryTools = "settings.knowledge.memoryTools"
}

/// Settings → Knowledge: what Blau knows about the user (the knowledge
/// base: profile, notes, collections, people and facts), read from the
/// synced store, whether Grok may search it while they talk, whether Blau
/// learns from conversations and what it learned (`MemorySettingsSection`,
/// #66), and the on-device search index over it
/// (`MemoryIndexSettingsSection`, #63).
///
/// This is where the knowledge base screen opens. Viewing and editing each
/// item is that screen's job (#65); until it ships, this page shows what is
/// stored and says what's coming.
struct KnowledgeSettingsView: View {
    @Environment(FeatureFlags.self) private var flags
    @Query private var documents: [MemoryDocument]
    @Query private var profileBlocks: [ProfileBlock]
    @Query private var entities: [MemoryEntity]
    @Query(filter: #Predicate<Fact> { $0.invalidatedAt == nil }) private var facts: [Fact]

    var body: some View {
        Form {
            Section {
                LabeledContent("About you", value: profileBlocks.isEmpty ? "Empty" : "Saved")
                LabeledContent("Notes and documents", value: documents.count.formatted())
                LabeledContent("People and things", value: entities.count.formatted())
                LabeledContent("Facts", value: facts.count.formatted())
            } header: {
                Text("What Blau Knows")
            } footer: {
                Text(
                    "Blau remembers what matters from your conversations and syncs it through iCloud. "
                        + "Browsing and editing your knowledge base is coming in an update; "
                        + "you can delete it in Privacy & Data."
                )
            }

            Section {
                LabeledContent(
                    "Grok Can Search Memory", value: flags.isEnabled(.memoryTools) ? "On" : "Off"
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(KnowledgeSettingsIdentifiers.memoryTools)
            } footer: {
                Text("Grok looks things up in what Blau knows when it helps answer you.")
            }

            MemorySettingsSection()
            MemoryIndexSettingsSection()
        }
        .accessibilityIdentifier(KnowledgeSettingsIdentifiers.view)
        .navigationTitle("Knowledge")
    }
}

#if DEBUG
    #Preview("Knowledge") {
        NavigationStack {
            KnowledgeSettingsView()
        }
        .environment(FeatureFlags.inMemory())
        .environment(MemoryIndexingController(persistence: .preview(), embedder: nil, performance: nil))
        .environment(MemoryLearningSettings(store: InMemoryMemoryLearningPreferenceStore()))
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
