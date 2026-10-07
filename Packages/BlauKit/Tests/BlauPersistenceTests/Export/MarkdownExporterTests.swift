import BlauCore
import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

/// An in-memory store and an export folder.
private struct ExporterFixture {
    let container: ModelContainer
    let context: ModelContext
    let folder: ExportFolder
    let fileSystem = RecordingFileSystem()

    init() throws {
        container = try BlauModelContainer.makeInMemory()
        context = ModelContext(container)
        folder = try ExportFolder()
    }

    func exporter(
        timeZone: TimeZone = losAngeles,
        destination: MarkdownExportDestination? = nil
    ) -> MarkdownExporter {
        MarkdownExporter(
            source: SwiftDataConversationExportSource(modelContainer: container),
            destination: destination ?? folder.destination,
            fileSystem: fileSystem,
            timeZone: { timeZone },
            clock: ManualClock(now: exportT0)
        )
    }
}

@Suite("Markdown exporter")
struct MarkdownExporterTests {
    @Test func writesOneFilePerConversation() async throws {
        let fixture = try ExporterFixture()
        let first = try insertConversation(into: fixture.context, title: "Hiring")
        let second = try insertConversation(
            into: fixture.context, start: 120, end: 180, topics: [("Fundraising", 120, 180)],
            utterances: [(0, 121, .user, "Seed round."), (0, 122, .agent, "How much?")])

        let report = try await fixture.exporter().exportAll()

        #expect(report.created == 2)
        #expect(report.failures.isEmpty)
        #expect(report.directory == fixture.folder.url)
        let names = try fixture.folder.names()
        #expect(
            names == [
                "2026-10-08 14.03 Hiring (\(MarkdownExportFileName.shortID(first.id))).md",
                "2026-10-08 16.03 Fundraising (\(MarkdownExportFileName.shortID(second.id))).md",
            ])
        let text = try fixture.folder.contents(of: names[1])
        #expect(text.contains("## Fundraising"))
        #expect(text.contains("**16:04:00 · You:** Seed round."))
        #expect(text.contains("**16:05:00 · Grok:** How much?"))
    }

    @Test func reExportingChangesNothing() async throws {
        let fixture = try ExporterFixture()
        try insertConversation(into: fixture.context)
        try insertConversation(into: fixture.context, start: 120, end: 180, topics: [("Later", 120, 180)])
        let exporter = fixture.exporter()
        _ = try await exporter.exportAll()
        let names = try fixture.folder.names()
        let contents = try names.map(fixture.folder.contents(of:))
        let dates = try names.map(fixture.folder.modificationDate(of:))
        fixture.fileSystem.reset()

        // Again, with the same exporter and with a fresh one.
        for exporter in [exporter, fixture.exporter()] {
            let report = try await exporter.exportAll()
            #expect(report.unchanged == 2)
            #expect(report.changedCount == 0)
        }

        #expect(fixture.fileSystem.writes.isEmpty)
        #expect(fixture.fileSystem.moves.isEmpty)
        #expect(fixture.fileSystem.removals.isEmpty)
        #expect(try fixture.folder.names() == names)
        #expect(try names.map(fixture.folder.contents(of:)) == contents)
        #expect(try names.map(fixture.folder.modificationDate(of:)) == dates)
    }

    @Test func rewritesAConversationThatChanged() async throws {
        let fixture = try ExporterFixture()
        let conversation = try insertConversation(into: fixture.context, title: "Plan")
        let exporter = fixture.exporter()
        _ = try await exporter.exportAll()

        fixture.context.insert(
            StoredUtterance(
                conversation: conversation, topic: conversation.topics?.first, role: .agent, text: "Sounds good.",
                startedAt: exportTime(2), isFinal: true, source: .grok))
        try fixture.context.save()
        let report = try await exporter.exportAll()

        #expect(report.updated == 1)
        let names = try fixture.folder.names()
        #expect(names.count == 1)
        #expect(try fixture.folder.contents(of: names[0]).contains("Sounds good."))
    }

    @Test func renamesTheFileWhenTheTitleChanges() async throws {
        let fixture = try ExporterFixture()
        let conversation = try insertConversation(into: fixture.context, title: "Draft")
        let exporter = fixture.exporter()
        _ = try await exporter.exportAll()
        let short = MarkdownExportFileName.shortID(conversation.id)

        conversation.title = "Final Plan"
        try fixture.context.save()
        let report = try await exporter.exportAll()

        #expect(report.renamed == 1)
        #expect(try fixture.folder.names() == ["2026-10-08 14.03 Final Plan (\(short)).md"])
        #expect(fixture.fileSystem.moves.map(\.0) == ["2026-10-08 14.03 Draft (\(short)).md"])
        #expect(try fixture.folder.contents(of: "2026-10-08 14.03 Final Plan (\(short)).md").contains("# Final Plan"))

        let again = try await exporter.exportAll()
        #expect(again.unchanged == 1)
    }

    @Test func removesExtraCopiesOfAConversation() async throws {
        let fixture = try ExporterFixture()
        let conversation = try insertConversation(into: fixture.context, title: "Current")
        let short = MarkdownExportFileName.shortID(conversation.id)
        // Another device exported it under an older title, twice.
        let old = ConversationMarkdownRenderer(timeZone: losAngeles).render(ConversationExportSnapshot(conversation))
        try fixture.folder.write(old, to: "2026-10-08 14.03 Old (\(short)).md")
        try fixture.folder.write(old, to: "2026-10-08 14.03 Older (\(short)).md")

        let report = try await fixture.exporter().exportAll()

        #expect(report.renamed == 1)
        #expect(report.removedDuplicates == 1)
        #expect(try fixture.folder.names() == ["2026-10-08 14.03 Current (\(short)).md"])
    }

    @Test func neverTouchesFilesItDidNotWrite() async throws {
        let fixture = try ExporterFixture()
        let conversation = try insertConversation(into: fixture.context, title: "Plan")
        let short = MarkdownExportFileName.shortID(conversation.id)
        let target = "2026-10-08 14.03 Plan (\(short)).md"
        try fixture.folder.write("My own notes", to: "Notes (\(short)).md")
        try fixture.folder.write("Something else", to: target)
        try fixture.folder.write("Shopping list", to: "List.md")

        let report = try await fixture.exporter().exportAll()

        #expect(report.created == 1)
        let longName = "2026-10-08 14.03 Plan (\(conversation.id.uuidString.lowercased())).md"
        #expect(try fixture.folder.names().sorted() == ["List.md", "Notes (\(short)).md", target, longName].sorted())
        #expect(try fixture.folder.contents(of: "Notes (\(short)).md") == "My own notes")
        #expect(try fixture.folder.contents(of: target) == "Something else")
        #expect(try fixture.folder.contents(of: "List.md") == "Shopping list")

        let again = try await fixture.exporter().exportAll()
        #expect(again.unchanged == 1)
    }

    @Test func keepsTheTimeZoneTheFileWasFirstWrittenIn() async throws {
        let fixture = try ExporterFixture()
        try insertConversation(into: fixture.context)
        _ = try await fixture.exporter(timeZone: losAngeles).exportAll()
        let names = try fixture.folder.names()

        // A device in Tokyo exports the same conversation.
        let report = try await fixture.exporter(timeZone: tokyo).exportAll()

        #expect(report.unchanged == 1)
        #expect(try fixture.folder.names() == names)
        #expect(try fixture.folder.contents(of: names[0]).contains("time-zone: America/Los_Angeles"))
    }

    @Test func skipsEmptyConversationsAndOptionallyOpenOnes() async throws {
        let fixture = try ExporterFixture()
        try insertConversation(into: fixture.context, utterances: [])
        try insertConversation(into: fixture.context, start: 100, end: nil, topics: [("Live", 100, nil)])
        try insertConversation(into: fixture.context, start: 200, end: 210, topics: [("Done", 200, 210)])

        let automatic = try await fixture.exporter().exportAll(includeOpen: false)
        #expect(automatic.created == 1)
        #expect(automatic.skippedEmpty == 1)
        #expect(automatic.skippedOpen == 1)

        let manual = try await fixture.exporter().exportAll()
        #expect(manual.created == 1)
        #expect(manual.unchanged == 1)
        #expect(try fixture.folder.names().count == 2)
    }

    @Test func oneFailingFileDoesNotStopTheRest() async throws {
        let fixture = try ExporterFixture()
        let failing = try insertConversation(into: fixture.context, title: "Broken")
        try insertConversation(into: fixture.context, title: "Fine", start: 100, end: 110)
        fixture.fileSystem.failWrites(containing: "Broken")

        let report = try await fixture.exporter().exportAll()

        #expect(report.created == 1)
        #expect(Array(report.failures.keys) == [failing.id])
        #expect(try fixture.folder.names().count == 1)
    }

    @Test func reportsAnUnavailableDestination() async throws {
        let fixture = try ExporterFixture()
        try insertConversation(into: fixture.context)
        let exporter = fixture.exporter(destination: .unavailable(.iCloudDriveUnavailable))
        await #expect(throws: MarkdownExportError.iCloudDriveUnavailable) {
            try await exporter.exportAll()
        }

        fixture.fileSystem.failListing()
        await #expect(throws: MarkdownExportError.self) {
            try await fixture.exporter().exportAll()
        }
    }

    @Test func anUnentitledBuildNeverAsksForICloudDrive() throws {
        #expect(throws: MarkdownExportError.notAvailableInThisBuild) {
            try MarkdownExportDestination.iCloudDrive(isEntitled: false).directory()
        }
    }

    @Test func exportsOnlyTheRequestedConversations() async throws {
        let fixture = try ExporterFixture()
        let wanted = try insertConversation(into: fixture.context, title: "Wanted")
        try insertConversation(into: fixture.context, title: "Other", start: 100, end: 110)

        let report = try await fixture.exporter().export(conversationIDs: [wanted.id, UUID()])

        #expect(report.created == 1)
        #expect(try fixture.folder.names().count == 1)
    }
}

@Suite("Conversation export source")
struct ConversationExportSourceTests {
    @Test func snapshotsKeepOnlyFinalTextInOrder() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let conversation = try insertConversation(
            into: context, utterances: [(0, 3, .agent, "Second"), (0, 1, .user, "First"), (nil, 2, .user, "  ")])
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "partial", startedAt: exportTime(4), isFinal: false,
                source: .parakeet))
        try context.save()

        let snapshot = try #require(
            try SwiftDataConversationExportSource(modelContainer: container).snapshot(of: conversation.id))

        #expect(snapshot.utterances.map(\.text) == ["First", "Second"])
        #expect(snapshot.utterances.map(\.role) == [.user, .agent])
        #expect(snapshot.topics.map(\.title) == ["Hiring Plan"])
        #expect(snapshot.utterances.allSatisfy { $0.topicID == snapshot.topics[0].id })
    }

    @Test func listsEachConversationOnceOldestFirst() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let later = try insertConversation(into: context, start: 100)
        let earlier = try insertConversation(into: context, start: 0)
        // The same conversation created on two devices.
        try insertConversation(into: context, id: later.id, start: 100, utterances: [])

        let source = SwiftDataConversationExportSource(modelContainer: container)
        #expect(try source.conversationIDs() == [earlier.id, later.id])
        // The copy with utterances wins.
        #expect(try source.snapshot(of: later.id)?.utterances.count == 1)
        #expect(try source.snapshot(of: UUID()) == nil)
    }

    @Test func mapsHistoryChangesToTheirConversations() async throws {
        let directory = try TemporaryDirectory()
        try directory.location.prepare()
        let container = try BlauModelContainer.makeLocal(url: directory.location.syncedStoreURL)
        let derived = try DerivedStore.open(at: directory.location.derivedStoreURL)
        let tracker = PersistentHistoryTracker(
            consumer: "export-test", container: container, cursors: HistoryCursorStore(modelContainer: derived),
            clock: ManualClock(now: exportT0))
        let context = ModelContext(container)
        let source = SwiftDataConversationExportSource(modelContainer: container)

        let first = try insertConversation(into: context, title: "One")
        let second = try insertConversation(into: context, title: "Two", start: 100)
        #expect(try source.conversationIDs(affectedBy: try await tracker.fetchNewChanges()) == [first.id, second.id])

        // A topic rename only touches the topic row.
        second.topics?.first?.title = "Renamed"
        try context.save()
        #expect(try source.conversationIDs(affectedBy: try await tracker.fetchNewChanges()) == [second.id])

        // A new utterance.
        context.insert(
            StoredUtterance(
                conversation: first, role: .user, text: "More", startedAt: exportTime(5), isFinal: true,
                source: .parakeet))
        try context.save()
        #expect(try source.conversationIDs(affectedBy: try await tracker.fetchNewChanges()).contains(first.id))

        // A deleted conversation can't be exported; it is ignored.
        context.delete(second)
        try context.save()
        #expect(try source.conversationIDs(affectedBy: try await tracker.fetchNewChanges()).isEmpty)
        // Keep the store's directory until the end.
        withExtendedLifetime(directory) {}
    }
}
