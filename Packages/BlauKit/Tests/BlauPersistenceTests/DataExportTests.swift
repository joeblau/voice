import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

/// Settings → Privacy & Data → Export All Data (#79).
@Suite("Data export")
@MainActor
struct DataExportTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let start = Date(timeIntervalSince1970: 1_791_363_600)  // 2026-10-07 09:00 UTC
    var exportedAt: Date { start.addingTimeInterval(86_400) }

    let exporter = DataExporter(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

    init() throws {
        container = try BlauModelContainer.makeInMemory()
    }

    /// One conversation (a topic, a committed line each way and a partial),
    /// the user's pages, learned facts, the profile and a voiceprint.
    private func seed() throws {
        let conversation = Conversation(startedAt: start, endedAt: start.addingTimeInterval(600))
        conversation.title = "Interview prep"
        context.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: start, title: "Fundraising")
        context.insert(topic)
        let lines: [(UtteranceRole, String, Bool, TranscriptSource)] = [
            (.user, "How big is the market?", true, .parakeet),
            (.agent, "Start bottom-up.", true, .grok),
            (.user, "still talk", false, .parakeet),
        ]
        for (index, line) in lines.enumerated() {
            context.insert(
                StoredUtterance(
                    conversation: conversation, topic: topic, role: line.0, text: line.1,
                    startedAt: start.addingTimeInterval(Double(index) * 0.25), isFinal: line.2, source: line.3))
        }

        context.insert(MemoryDocument(kind: .profile, title: "About me", body: "I build voice apps.", createdAt: start))
        context.insert(MemoryDocument(kind: .company, title: "Blau", body: "A voice app.", createdAt: start))
        let questions = MemoryDocument(kind: .collection, title: "YC questions", createdAt: start)
        context.insert(questions)
        let item = CollectionItem(
            document: questions, ordinal: 0, prompt: "Why now?", referenceAnswer: "Voice\nmodels got good.",
            createdAt: start)
        context.insert(item)
        item.recordPractice(at: start, score: 0.5)

        let acme = MemoryEntity(name: "Acme", type: .organization, aliases: ["Acme Inc"], createdAt: start)
        context.insert(acme)
        context.insert(
            Fact(subject: acme, predicate: "raised", objectText: "a seed round", validFrom: start, origin: .extracted))
        let stripe = Fact(predicate: "works at", objectText: "Stripe", validFrom: start, origin: .user)
        stripe.invalidate(at: start.addingTimeInterval(3_600))
        context.insert(stripe)
        context.insert(ProfileBlock(text: "Joe builds Blau.", updatedAt: start))

        let profile = VoiceProfile(
            name: "Me", embeddingModelVersion: "wespeaker-v1", centroid: [0.25, 0.5], createdAt: start)
        context.insert(profile)
        context.insert(
            VoiceEnrollmentSet(
                profile: profile, deviceModel: "iPhone18,1", embeddings: [[0.25, 0.5]], createdAt: start))
        try context.save()
    }

    // MARK: Snapshot

    @Test func theSnapshotHoldsEveryRecord() throws {
        try seed()
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt, app: "Blau 1.0 (1)")

        #expect(export.format == DataExport.formatIdentifier)
        #expect(export.schemaVersion == "2.0.0")
        #expect(export.app == "Blau 1.0 (1)")
        let conversation = try #require(export.conversations.first)
        #expect(conversation.title == "Interview prep")
        #expect(conversation.topics.map(\.title) == ["Fundraising"])
        // Partials too, in spoken order, each tied to its topic.
        #expect(conversation.utterances.map(\.text) == ["How big is the market?", "Start bottom-up.", "still talk"])
        #expect(conversation.utterances.map(\.isFinal) == [true, true, false])
        #expect(conversation.utterances.allSatisfy { $0.topicID == conversation.topics[0].id })
        #expect(conversation.utterances.map(\.role) == ["user", "agent", "user"])
        #expect(conversation.utterances[1].source == "grok")

        #expect(export.documents.map(\.kind) == ["profile", "company", "collection"])
        let collection = try #require(export.documents.last)
        #expect(collection.collectionItems.map(\.prompt) == ["Why now?"])
        #expect(collection.collectionItems.first?.practiceCount == 1)

        #expect(export.entities.map(\.name) == ["Acme"])
        #expect(export.entities.first?.aliases == ["Acme Inc"])
        #expect(export.facts.count == 2)
        let raised = try #require(export.facts.first { $0.predicate == "raised" })
        #expect(raised.subjectID == export.entities.first?.id)
        #expect(raised.statement == "Acme raised a seed round")
        let stripe = try #require(export.facts.first { $0.object == "Stripe" })
        #expect(stripe.subjectID == nil)
        #expect(stripe.statement == "User works at Stripe")
        #expect(!stripe.isCurrent)
        #expect(stripe.origin == "user")
        #expect(export.profileBlocks.map(\.text) == ["Joe builds Blau."])

        let voiceprint = try #require(export.voiceprints.first)
        #expect(voiceprint.embeddingModelVersion == "wespeaker-v1")
        #expect(voiceprint.enrollmentSets == [.init(deviceModel: "iPhone18,1", clipCount: 1, createdAt: start)])

        #expect(export.counts.conversations == 1)
        #expect(export.counts.utterances == 3)
        #expect(!export.isEmpty)
    }

    @Test func anEmptyStoreExportsAnEmptySnapshot() throws {
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)
        #expect(export.isEmpty)
        #expect(exporter.knowledgeMarkdown(export).contains("Nothing in the knowledge base yet."))
        #expect(exporter.conversationsMarkdown(export).contains("0 conversations"))
    }

    // MARK: JSON

    @Test func theJSONRoundTripsWithMillisecondDates() throws {
        try seed()
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)
        let data = try exporter.json(export)
        let decoded = try DataExporter.decode(data)
        #expect(decoded == export)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"com.joeblau.blau.export\""))
        // A quarter second apart stays a quarter second apart.
        #expect(text.contains("2026-10-07T09:00:00.250Z"))
    }

    /// The voiceprint's vectors are a biometric template: described, never
    /// exported.
    @Test func theJSONLeavesOutTheVoiceprintVectors() throws {
        try seed()
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)
        let object = try JSONSerialization.jsonObject(with: exporter.json(export)) as? [String: Any]
        let voiceprint = try #require((object?["voiceprints"] as? [[String: Any]])?.first)
        #expect(voiceprint["centroid"] == nil)
        #expect(voiceprint["embeddings"] == nil)
        let set = try #require((voiceprint["enrollmentSets"] as? [[String: Any]])?.first)
        #expect(set["embeddings"] == nil)
        #expect(set["clipCount"] as? Int == 1)
    }

    @Test func twoExportsOfTheSameDataAreTheSameFile() throws {
        try seed()
        let first = try exporter.json(DataExport.snapshot(in: context, exportedAt: exportedAt))
        let second = try exporter.json(DataExport.snapshot(in: ModelContext(container), exportedAt: exportedAt))
        #expect(first == second)
    }

    // MARK: Markdown

    @Test func conversationsMarkdownMatchesTheConversationExport() throws {
        try seed()
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)
        let markdown = exporter.conversationsMarkdown(export)
        let direct = ConversationExporter(locale: exporter.locale, timeZone: exporter.timeZone)
            .markdown(for: try ConversationExporter.snapshots(in: context), exportedAt: exportedAt)
        #expect(markdown == direct)
        #expect(markdown.contains("\n## Interview prep\n"))
        #expect(markdown.contains("\n### Fundraising\n"))
        #expect(markdown.contains("\n**Grok:** Start bottom-up.\n"))
        #expect(!markdown.contains("still talk"))
    }

    @Test func knowledgeMarkdownHasPagesProfileAndFacts() throws {
        try seed()
        let markdown = exporter.knowledgeMarkdown(try DataExport.snapshot(in: context, exportedAt: exportedAt))
        #expect(markdown.hasPrefix("# Blau knowledge and memory\n\nExported Oct 8, 2026"))
        #expect(markdown.contains("\n## About Me\n\n### About me\n\nI build voice apps.\n"))
        #expect(markdown.contains("\n## Company\n\n### Blau\n\nA voice app.\n"))
        // A multi-line answer stays inside its list item.
        #expect(
            markdown.contains(
                "\n1. Why now?\n   - Answer: Voice models got good.\n   - Practiced 1 time, last Oct 7, 2026\n"))
        #expect(markdown.contains("\n## Profile summary\n"))
        #expect(markdown.contains("\nJoe builds Blau.\n"))
        #expect(markdown.contains("\n### Current\n\n- Acme raised a seed round (since Oct 7, 2026)\n"))
        #expect(markdown.contains("\n### No longer true\n\n- User works at Stripe (Oct 7, 2026 – Oct 7, 2026)\n"))
        #expect(markdown.contains("- **Acme** (organization), also Acme Inc\n"))
        #expect(!markdown.contains("Notes"))
    }

    @Test func theReadmeSaysWhatIsInside() throws {
        try seed()
        let readme = exporter.readme(try DataExport.snapshot(in: context, exportedAt: exportedAt, app: "Blau 1.0 (1)"))
        #expect(readme.contains("from Blau 1.0 (1)."))
        #expect(readme.contains("1 conversation as readable text"))
        #expect(readme.contains("3 knowledge base pages"))
        #expect(readme.contains("2 learned facts"))
        #expect(readme.contains("3 transcribed lines"))
        #expect(readme.contains("1 person or thing"))
        #expect(readme.contains("without its vectors"))
    }

    // MARK: Files

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "data-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func writesADatedFolderWithEveryFile() throws {
        try seed()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)

        let folder = try exporter.writeFolder(export, in: directory)

        #expect(folder.lastPathComponent == "Blau Export 2026-10-08")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["Conversations.md", "Knowledge.md", "README.md", "blau-data.json"])
        let json = try Data(contentsOf: folder.appending(path: DataExporter.jsonFileName))
        #expect(try DataExporter.decode(json) == export)

        // Writing again replaces the folder rather than failing.
        _ = try exporter.writeFolder(export, in: directory)
    }

    @Test func zipsTheExportIntoOneArchive() throws {
        try seed()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = try DataExport.snapshot(in: context, exportedAt: exportedAt)

        let archive = try exporter.writeArchive(export, in: directory)

        #expect(archive.lastPathComponent == "Blau Export 2026-10-08.zip")
        let bytes = try Data(contentsOf: archive)
        #expect(bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]))  // "PK\u{3}\u{4}": a zip file
        // Only the archive is left behind.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == [
                archive.lastPathComponent
            ])
        // Exporting again the same day replaces it.
        #expect(try exporter.writeArchive(export, in: directory) == archive)

        #if os(macOS)
            // It unzips to the folder with every file.
            let unzipped = directory.appending(path: "unzipped")
            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path(percentEncoded: false), unzipped.path(percentEncoded: false)]
            try ditto.run()
            ditto.waitUntilExit()
            #expect(ditto.terminationStatus == 0)
            let folder = unzipped.appending(path: "Blau Export 2026-10-08")
            let json = try Data(contentsOf: folder.appending(path: DataExporter.jsonFileName))
            #expect(try DataExporter.decode(json) == export)
            let knowledge = try String(
                contentsOf: folder.appending(path: DataExporter.knowledgeFileName), encoding: .utf8)
            #expect(knowledge == exporter.knowledgeMarkdown(export))
        #endif
    }

    @Test func zippingAMissingFolderThrows() {
        let missing = URL.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try DataExportArchiver.zip(missing, to: URL.temporaryDirectory.appending(path: "\(UUID().uuidString).zip"))
        }
    }
}
