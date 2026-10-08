import BlauPersistence
import SwiftData
import SwiftUI

/// Settings → Knowledge → About Me (#65): what the user tells Blau about
/// themselves, in their own words.
///
/// It is the knowledge base's `.profile` document: the name is its title,
/// the text its body. Grok finds it through `search_memory`
/// (`kinds: ["profile"]`), and it is the user-authored input the pinned
/// `ProfileBlock` summary is built from (#67), which the page shows
/// read-only once Blau has written one. See docs/knowledge-base.md for why
/// the user edits the document rather than the block.
struct AboutMeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(MemoryDocument.pages(of: .profile))
    private var profiles: [MemoryDocument]
    @Query(ProfileBlock.latest()) private var blocks: [ProfileBlock]

    var body: some View {
        let stored = profiles.first
        AboutMeEditor(
            draft: KnowledgeDraft(
                kind: .profile, documentID: stored?.id ?? UUID(), title: stored?.title ?? "", body: stored?.body ?? "",
                editor: environment.knowledgeBase, clock: environment.clock),
            stored: stored,
            summary: blocks.first?.text)
    }
}

private struct AboutMeEditor: View {
    @State var draft: KnowledgeDraft
    let stored: MemoryDocument?
    let summary: String?

    var body: some View {
        @Bindable var draft = draft
        Form {
            Section("Your Name") {
                TextField("Name", text: $draft.title)
                    .textContentType(.name)
                    .accessibilityIdentifier(KnowledgeBaseIdentifiers.profileName)
            }
            Section {
                TextField(
                    "What you do, what you're working on, what matters to you, how you like answers…",
                    text: $draft.body, axis: .vertical
                )
                .lineLimit(8...)
                .accessibilityIdentifier(KnowledgeBaseIdentifiers.profileText)
            } header: {
                Text("About You")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grok looks this up when it helps answer you. Markdown is fine.")
                    KnowledgeSaveStatus(draft: draft)
                }
            }
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(KnowledgeBaseIdentifiers.profileSummary)
                } header: {
                    Text("Blau's Summary")
                } footer: {
                    Text(
                        "Blau writes this from what you tell it and what it learns, and keeps it in mind in every conversation."
                    )
                }
            }
        }
        .navigationTitle("About Me")
        .knowledgeDraft(draft, stored: stored)
    }
}

#if DEBUG
    #Preview("About Me") {
        let environment = AppEnvironment.preview()
        NavigationStack {
            AboutMeView()
        }
        .appEnvironment(environment)
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
