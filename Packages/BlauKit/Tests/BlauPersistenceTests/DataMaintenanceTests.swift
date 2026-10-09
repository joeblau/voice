import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

/// Settings → Privacy (delete data) and Settings → iCloud (export).
@Suite("Data maintenance")
@MainActor
struct DataMaintenanceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let start = Date(timeIntervalSince1970: 1_791_363_600)  // 2026-10-07 09:00 UTC

    init() throws {
        container = try BlauModelContainer.makeInMemory()
    }

    /// Two conversations with topics and utterances, a knowledge base and a
    /// voiceprint.
    private func seed() throws {
        for index in 0..<2 {
            let conversation = Conversation(
                startedAt: start.addingTimeInterval(Double(index) * 3_600),
                endedAt: start.addingTimeInterval(Double(index) * 3_600 + 600))
            context.insert(conversation)
            let topic = Topic(conversation: conversation, startedAt: conversation.startedAt, title: "Topic \(index)")
            context.insert(topic)
            for line in 0..<3 {
                let utterance = StoredUtterance(
                    conversation: conversation, topic: topic, role: line.isMultiple(of: 2) ? .user : .agent,
                    text: "Line \(line)", startedAt: conversation.startedAt.addingTimeInterval(Double(line) * 10),
                    isFinal: true, source: line.isMultiple(of: 2) ? .parakeet : .grok)
                context.insert(utterance)
            }
        }
        let document = MemoryDocument(kind: .company, title: "Blau", body: "A voice app", createdAt: start)
        context.insert(document)
        context.insert(CollectionItem(document: document, ordinal: 0, prompt: "Why now?", createdAt: start))
        let entity = MemoryEntity(name: "Joe", type: .person, createdAt: start)
        context.insert(entity)
        context.insert(Fact(subject: entity, predicate: "builds", objectText: "Blau", validFrom: start, origin: .user))
        context.insert(ProfileBlock(text: "Joe builds Blau.", updatedAt: start))
        let profile = VoiceProfile(name: "Me", embeddingModelVersion: "test", centroid: [0.1, 0.2], createdAt: start)
        context.insert(profile)
        context.insert(
            VoiceEnrollmentSet(profile: profile, deviceModel: "iPhone18,1", embeddings: [[0.1, 0.2]], createdAt: start))
        try context.save()
    }

    private func count<Model: PersistentModel>(_ type: Model.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<Model>())
    }

    // MARK: Erasing

    @Test func erasingConversationsKeepsKnowledgeAndVoiceprint() throws {
        try seed()
        #expect(try DataEraser.count(.conversations, in: context) == 2)

        let summary = try DataEraser.erase(.conversations, in: context)

        #expect(summary.conversations == 2)
        #expect(summary.topics == 2)
        #expect(summary.utterances == 6)
        #expect(summary.total == 10)
        #expect(try count(Conversation.self) == 0)
        #expect(try count(Topic.self) == 0)
        #expect(try count(StoredUtterance.self) == 0)
        #expect(try count(MemoryDocument.self) == 1)
        #expect(try count(Fact.self) == 1)
        #expect(try count(VoiceProfile.self) == 1)
    }

    @Test func erasingKnowledgeKeepsConversations() throws {
        try seed()
        let summary = try DataEraser.erase(.knowledge, in: context)
        #expect(summary.documents == 1)
        #expect(summary.collectionItems == 1)
        #expect(summary.entities == 1)
        #expect(summary.facts == 1)
        #expect(summary.profileBlocks == 1)
        #expect(try count(MemoryDocument.self) == 0)
        #expect(try count(CollectionItem.self) == 0)
        #expect(try count(ProfileBlock.self) == 0)
        #expect(try count(Conversation.self) == 2)
        #expect(try count(VoiceProfile.self) == 1)
    }

    @Test func erasingLearnedFactsKeepsTheUsersPages() throws {
        try seed()
        // A fact about the user (no entity) as well as one about an entity.
        context.insert(Fact(predicate: "lives in", objectText: "Austin", validFrom: start, origin: .extracted))
        try context.save()
        #expect(try DataEraser.count(.learnedFacts, in: context) == 2)

        let summary = try DataEraser.erase(.learnedFacts, in: context)

        #expect(summary.facts == 2)
        #expect(summary.entities == 1)
        #expect(summary.profileBlocks == 1)
        #expect(summary.documents == 0)
        #expect(try count(Fact.self) == 0)
        #expect(try count(MemoryEntity.self) == 0)
        #expect(try count(ProfileBlock.self) == 0)
        // What the user wrote, the conversations and the voiceprint stay.
        #expect(try count(MemoryDocument.self) == 1)
        #expect(try count(CollectionItem.self) == 1)
        #expect(try count(Conversation.self) == 2)
        #expect(try count(VoiceProfile.self) == 1)
    }

    @Test func whichScopesEraseTheLearnedFacts() {
        #expect(DataEraseScope.learnedFacts.erasesLearnedFacts)
        #expect(DataEraseScope.knowledge.erasesLearnedFacts)
        #expect(DataEraseScope.everything.erasesLearnedFacts)
        #expect(!DataEraseScope.conversations.erasesLearnedFacts)
        #expect(!DataEraseScope.voiceprint.erasesLearnedFacts)
    }

    @Test func erasingTheVoiceprintRemovesItsEnrollmentSets() throws {
        try seed()
        #expect(try DataEraser.count(.voiceprint, in: context) == 1)
        let summary = try DataEraser.erase(.voiceprint, in: context)
        #expect(summary.voiceProfiles == 1)
        #expect(summary.enrollmentSets == 1)
        #expect(try count(VoiceProfile.self) == 0)
        #expect(try count(VoiceEnrollmentSet.self) == 0)
        #expect(try count(Conversation.self) == 2)
    }

    @Test func erasingEverythingEmptiesTheStore() throws {
        try seed()
        #expect(try DataEraser.count(.everything, in: context) == 7)
        try DataEraser.erase(.everything, in: context)
        #expect(try count(Conversation.self) == 0)
        #expect(try count(Topic.self) == 0)
        #expect(try count(StoredUtterance.self) == 0)
        #expect(try count(MemoryDocument.self) == 0)
        #expect(try count(CollectionItem.self) == 0)
        #expect(try count(MemoryEntity.self) == 0)
        #expect(try count(Fact.self) == 0)
        #expect(try count(ProfileBlock.self) == 0)
        #expect(try count(VoiceProfile.self) == 0)
        #expect(try count(VoiceEnrollmentSet.self) == 0)
        // Every model in the schema is covered above.
        #expect(CurrentSchema.models.count == 10)
        #expect(try DataEraser.count(.everything, in: context) == 0)
    }

    @Test func erasingAnEmptyStoreDeletesNothing() throws {
        let summary = try DataEraser.erase(.everything, in: context)
        #expect(summary == DataEraseSummary())
    }

    @Test func everythingCoversEveryOtherScope() {
        #expect(DataEraseScope.everything.components == [.conversations, .knowledge, .voiceprint])
        #expect(DataEraseScope.conversations.components == [.conversations])
    }

    @Test func deletionsAreSavedToTheStore() throws {
        try seed()
        try DataEraser.erase(.conversations, in: context)
        // A fresh context reads the saved store, not the main context's
        // pending changes.
        let other = ModelContext(container)
        #expect(try other.fetchCount(FetchDescriptor<Conversation>()) == 0)
        #expect(try other.fetchCount(FetchDescriptor<StoredUtterance>()) == 0)
    }

    // MARK: Exporting

    private var exporter: ConversationExporter {
        ConversationExporter(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func exportsConversationsAsMarkdown() throws {
        try seed()
        let snapshots = try ConversationExporter.snapshots(in: context)
        #expect(snapshots.count == 2)
        #expect(snapshots[0].startedAt < snapshots[1].startedAt)
        #expect(snapshots[0].lines.map(\.text) == ["Line 0", "Line 1", "Line 2"])

        let markdown = exporter.markdown(for: snapshots, exportedAt: start.addingTimeInterval(86_400))
        #expect(markdown.hasPrefix("# Blau conversations\n\nExported Oct 8, 2026"))
        #expect(markdown.contains("· 2 conversations"))
        #expect(markdown.contains("\n### Topic 0\n"))
        #expect(markdown.contains("\n**You:** Line 0\n"))
        #expect(markdown.contains("\n**Grok:** Line 1\n"))
        // The topic heading appears once per run of its utterances.
        #expect(markdown.components(separatedBy: "### Topic 1").count == 2)
    }

    @Test func exportUsesTheTitleOrTheDateAndSkipsBlankLines() {
        let conversations = [
            ConversationExporter.Snapshot(
                title: "Interview\nprep", startedAt: start, endedAt: nil,
                lines: [
                    .init(role: .user, text: "  Hello  ", startedAt: start),
                    .init(role: .agent, text: "   ", startedAt: start),
                    .init(role: .system, text: "Reconnected", startedAt: start),
                ]),
            ConversationExporter.Snapshot(title: nil, startedAt: start, endedAt: nil, lines: []),
        ]
        let markdown = exporter.markdown(for: conversations, exportedAt: start)
        #expect(markdown.contains("\n## Interview prep\n"))
        #expect(markdown.contains("\n**You:** Hello\n"))
        #expect(!markdown.contains("**Grok:**"))
        #expect(markdown.contains("\n**Blau:** Reconnected\n"))
        #expect(markdown.contains("\n## Oct 7, 2026"))
    }

    @Test func exportLeavesOutPartials() throws {
        let conversation = Conversation(startedAt: start)
        context.insert(conversation)
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "still talk", startedAt: start, isFinal: false,
                source: .parakeet))
        try context.save()
        let snapshots = try ConversationExporter.snapshots(in: context)
        #expect(snapshots.first?.lines.isEmpty == true)
    }

    @Test func writesTheExportToADatedFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try exporter.write([], exportedAt: start, to: directory)
        #expect(url.lastPathComponent == "Blau Conversations 2026-10-07.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("0 conversations"))
    }
}
