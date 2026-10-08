import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The knowledge base UI's app side (#65): the composition root's write
/// path reaches the open store (and what the views read with `@Query`),
/// the Knowledge page's rows, and the pure pieces of the screens. The store,
/// parsing and autosave are covered by `swift test` in BlauKit.
@Suite("Knowledge base")
@MainActor
struct KnowledgeBaseAppTests {
    private func openEnvironment() async throws -> (AppEnvironment, ModelContainer) {
        let environment = AppEnvironment.fake(kind: .unitTest)
        await environment.persistence.start()
        return (environment, try #require(environment.modelContainer))
    }

    @Test func theEnvironmentWritesToTheOpenStore() async throws {
        let (environment, container) = try await openEnvironment()
        let collectionID = UUID()
        _ = try await environment.knowledgeBase.saveDocument(
            collectionID, kind: .collection, title: "YC interview questions", body: "")
        let parsed = CollectionImport(parsing: (1...30).map { "\($0). Question \($0)?" }.joined(separator: "\n"))
        let added = try await environment.knowledgeBase.addItems(parsed.items, to: collectionID)
        #expect(added.addedIDs.count == 30)

        // The main context (what `@Query` reads) sees the background save.
        let main = container.mainContext
        let collection = try #require(try main.fetch(MemoryDocument.pages(of: .collection)).first)
        #expect(collection.title == "YC interview questions")
        #expect(collection.uniqueOrderedItems.count == 30)
        #expect(collection.uniqueOrderedItems.first?.prompt == "Question 1?")
        #expect(CollectionDetailView.unique(collection.collectionItems ?? []).map(\.ordinal) == Array(0..<30))
    }

    @Test func theKnowledgePageCountsWhatIsStored() async throws {
        let (environment, container) = try await openEnvironment()
        var counts = try KnowledgeSettingsView.Counts(in: container.mainContext)
        #expect(counts.profileSummary == "Not Set")
        #expect(counts.companySummary == "Not Set")
        #expect(counts.notes == 0)

        let knowledgeBase = environment.knowledgeBase
        _ = try await knowledgeBase.saveDocument(UUID(), kind: .profile, title: "", body: "I build voice apps.")
        _ = try await knowledgeBase.saveDocument(UUID(), kind: .company, title: "Larderly", body: "")
        _ = try await knowledgeBase.saveDocument(UUID(), kind: .note, title: "Pricing", body: "")
        _ = try await knowledgeBase.saveDocument(UUID(), kind: .note, title: "Hiring", body: "")
        _ = try await knowledgeBase.saveDocument(UUID(), kind: .collection, title: "YC", body: "")

        counts = try KnowledgeSettingsView.Counts(in: container.mainContext)
        #expect(counts.profileSummary == "Saved")
        #expect(counts.companySummary == "Larderly")
        #expect(counts.notes == 2)
        #expect(counts.collections == 1)
    }

    @Test func aDraftSavesThroughTheEnvironment() async throws {
        let (environment, container) = try await openEnvironment()
        let draft = KnowledgeDraft(
            kind: .note, documentID: UUID(), editor: environment.knowledgeBase, clock: environment.clock)
        draft.title = "Pricing"
        draft.body = "Two tiers."
        await draft.flush()
        let note = try #require(try container.mainContext.fetch(MemoryDocument.pages(of: .note)).first)
        #expect(note.id == draft.documentID)
        #expect(note.body == "Two tiers.")
        #expect(note.excerpt == "Two tiers.")
    }

    @Test func listsShowOneRowPerDocument() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let copies = (0..<2).map { _ in MemoryDocument(id: id, kind: .note, title: "Copy", createdAt: date) }
        let other = MemoryDocument(kind: .note, title: "Other", createdAt: date)
        for document in copies + [other] { context.insert(document) }
        #expect((copies + [other]).uniqued().map(\.title) == ["Copy", "Other"])
    }

    @Test func collectionSummaries() {
        #expect(CollectionSummary.line(prompts: 30, practiced: 0) == "30 questions")
        #expect(CollectionSummary.line(prompts: 1, practiced: 0) == "1 question")
        #expect(CollectionSummary.line(prompts: 30, practiced: 4) == "30 questions · 4 practiced")
        #expect(CollectionSummary.practice(count: 0, score: nil) == nil)
        #expect(CollectionSummary.practice(count: 1, score: nil) == "Practiced once")
        #expect(CollectionSummary.practice(count: 3, score: 0.8)?.hasPrefix("Practiced 3 times · 80") == true)
    }

    @Test func markdownPreviewBlocks() {
        let blocks = MarkdownPreview.blocks(
            """
            # Pricing
            Two tiers,
            **annual** billing.

            - Starter
            2. Pro
            > Ask about volume.
            ```
            # not a heading
            ```
            #hashtag
            """)
        #expect(
            blocks == [
                .heading(level: 1, text: "Pricing"),
                .paragraph("Two tiers,\n**annual** billing."),
                .bullet(marker: "•", text: "Starter"),
                .bullet(marker: "2.", text: "Pro"),
                .quote("Ask about volume."),
                .code("# not a heading"),
                .paragraph("#hashtag"),
            ])
    }

    @Test func companyFieldsHaveLabelsAndPrompts() {
        for field in CompanyProfile.Field.allCases {
            #expect(!field.label.isEmpty)
            #expect(!field.prompt.isEmpty)
        }
    }

    @Test func failureMessages() {
        #expect(KnowledgeBaseFailure.message(for: KnowledgeBaseError.emptyPrompt) == "A question can't be empty.")
        #expect(
            KnowledgeBaseFailure.message(for: CocoaError(.fileWriteUnknown)) == "The change couldn't be saved.")
    }
}
