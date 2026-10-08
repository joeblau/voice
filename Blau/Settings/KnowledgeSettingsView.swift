import BlauCore
import BlauMemory
import BlauPersistence
import BlauTelemetry
import SwiftData
import SwiftUI
import os

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
    @Environment(\.modelContext) private var modelContext
    @State private var counts: Counts?

    /// What the summary shows. Counted in the store (`fetchCount`) rather
    /// than with `@Query`, which would load every document, entity and fact
    /// on the main thread just to count them.
    struct Counts: Equatable {
        var hasProfile: Bool
        var documents: Int
        var entities: Int
        var facts: Int

        @MainActor
        init(in context: ModelContext) throws {
            var profile = FetchDescriptor<ProfileBlock>()
            profile.fetchLimit = 1
            hasProfile = try context.fetchCount(profile) > 0
            documents = try context.fetchCount(FetchDescriptor<MemoryDocument>())
            entities = try context.fetchCount(FetchDescriptor<MemoryEntity>())
            facts = try context.fetchCount(FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil }))
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("About you", value: counts.map { $0.hasProfile ? "Saved" : "Empty" } ?? "—")
                LabeledContent("Notes and documents", value: counts?.documents.formatted() ?? "—")
                LabeledContent("People and things", value: counts?.entities.formatted() ?? "—")
                LabeledContent("Facts", value: counts?.facts.formatted() ?? "—")
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
        .task { refreshCounts() }
    }

    private func refreshCounts() {
        do {
            counts = try Counts(in: modelContext)
        } catch {
            Log.ui.error("Couldn't count the knowledge base: \(String(describing: error), privacy: .public)")
        }
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
