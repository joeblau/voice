import BlauCore
import BlauMemory
import BlauPersistence
import BlauTelemetry
import Combine
import SwiftData
import SwiftUI
import os

/// Accessibility identifiers for Settings → Knowledge, shared with UI tests.
enum KnowledgeSettingsIdentifiers {
    static let view = "settings.knowledge.view"
    static let memoryTools = "settings.knowledge.memoryTools"
}

/// Settings → Knowledge: the knowledge base (#65: About Me, Company, Notes
/// and Collections, each a page of its own), what Blau learned from
/// conversations, whether Grok may search it while the user talks, whether
/// Blau learns from conversations and what it learned
/// (`MemorySettingsSection`, #66), and the on-device search index over it
/// (`MemoryIndexSettingsSection`, #63).
struct KnowledgeSettingsView: View {
    @Environment(FeatureFlags.self) private var flags
    @Environment(\.modelContext) private var modelContext
    @State private var counts: Counts?

    /// What the rows show. Counted in the store (`fetchCount`) rather than
    /// with `@Query`, which would load every document, entity and fact on
    /// the main thread just to count them.
    struct Counts: Equatable {
        /// The About Me page's name, "" when it has none; `nil` when there
        /// is no page.
        var profileName: String?
        /// The company page's name; `nil` when there is no page.
        var companyName: String?
        var notes: Int
        var collections: Int
        var entities: Int
        var facts: Int

        @MainActor
        init(in context: ModelContext) throws {
            profileName = try Self.latest("profile", in: context)?.title
            companyName = try Self.latest("company", in: context)?.title
            notes = try context.fetchCount(
                FetchDescriptor<MemoryDocument>(predicate: #Predicate { $0.kindRaw == "note" }))
            collections = try context.fetchCount(
                FetchDescriptor<MemoryDocument>(predicate: #Predicate { $0.kindRaw == "collection" }))
            entities = try context.fetchCount(FetchDescriptor<MemoryEntity>())
            facts = try context.fetchCount(FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil }))
        }

        @MainActor
        private static func latest(_ kind: String, in context: ModelContext) throws -> MemoryDocument? {
            var descriptor = FetchDescriptor<MemoryDocument>(
                predicate: #Predicate { $0.kindRaw == kind }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }

        /// The About Me row's value.
        var profileSummary: String {
            guard let profileName else { return String(localized: "Not Set") }
            return profileName.isEmpty ? String(localized: "Saved") : profileName
        }

        /// The Company row's value.
        var companySummary: String {
            guard let companyName else { return String(localized: "Not Set") }
            return companyName.isEmpty ? String(localized: "Saved") : companyName
        }
    }

    var body: some View {
        Form {
            Section {
                row("About Me", systemImage: "person.text.rectangle", value: counts?.profileSummary) {
                    AboutMeView()
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.aboutMe)
                row("Company", systemImage: "building.2", value: counts?.companySummary) {
                    CompanyView()
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.company)
                row("Notes", systemImage: "note.text", value: counts?.notes.formatted()) {
                    NotesListView()
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.notes)
                row("Collections", systemImage: "list.bullet.rectangle", value: counts?.collections.formatted()) {
                    CollectionsListView()
                }
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.collections)
            } header: {
                Text("Knowledge Base")
            } footer: {
                Text(
                    "What you'd like Blau to know. It syncs through iCloud, and Grok looks things up in it when it "
                        + "helps. In a conversation, say “Remember that…” to add a fact."
                )
            }

            Section {
                LabeledContent("People and Things", value: counts?.entities.formatted() ?? "—")
                LabeledContent("Facts", value: counts?.facts.formatted() ?? "—")
            } header: {
                Text("Learned From Conversations")
            } footer: {
                Text("You can delete everything Blau knows in Privacy & Data.")
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
        // A page was saved, here or by iCloud: a row's value may have changed.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { _ in
            refreshCounts()
        }
    }

    private func row<Destination: View>(
        _ title: LocalizedStringKey, systemImage: String, value: String?,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                Text(value ?? "—").lineLimit(1)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
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
        .appEnvironment(AppEnvironment.preview())
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
