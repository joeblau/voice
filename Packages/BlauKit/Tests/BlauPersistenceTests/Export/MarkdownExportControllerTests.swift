import BlauCore
import Foundation
import SwiftData
import Testing

@testable import BlauPersistence

/// A local, on-disk persistence controller (history needs SQLite) and an
/// export controller writing to a temporary folder.
@MainActor
private final class ControllerFixture {
    let storeDirectory: TemporaryDirectory
    let folder: ExportFolder
    let clock = ManualClock(now: exportT0)
    let preferences: InMemoryMarkdownExportPreferences
    let persistence: PersistenceController
    var destination: MarkdownExportDestination
    private(set) var controller: MarkdownExportController!

    init(autoExport: Bool = false, destination: MarkdownExportDestination? = nil) async throws {
        storeDirectory = try TemporaryDirectory()
        folder = try ExportFolder()
        preferences = InMemoryMarkdownExportPreferences(isAutoExportEnabled: autoExport)
        persistence = PersistenceController(
            options: PersistenceOptions(
                location: storeDirectory.location, cloudKitEntitled: false, storeOverride: .local),
            accountProvider: nil,
            clock: clock,
            notificationCenter: NotificationCenter()
        )
        self.destination = destination ?? folder.destination
        await persistence.start()
        controller = makeController()
    }

    func makeController() -> MarkdownExportController {
        MarkdownExportController(
            persistence: persistence,
            destination: destination,
            preferences: preferences,
            autoExportDelay: .seconds(5),
            timeZone: { losAngeles },
            clock: clock
        )
    }

    var context: ModelContext {
        get throws { try #require(persistence.stack).container.mainContext }
    }

    var report: MarkdownExportReport? {
        guard case .success(let report) = controller.lastOutcome?.result else { return nil }
        return report
    }
}

/// Polls `condition` on the main actor for up to five seconds of real time.
@MainActor
private func waitFor(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<5_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
}

@Suite("Markdown export controller")
@MainActor
struct MarkdownExportControllerTests {
    @Test func exportNowWritesEveryConversation() async throws {
        let fixture = try await ControllerFixture()
        try insertConversation(into: fixture.context)
        try insertConversation(into: fixture.context, start: 100, end: nil, topics: [("Live", 100, nil)])
        #expect(fixture.controller.lastOutcome == nil)

        await fixture.controller.exportNow()

        #expect(fixture.report?.created == 2)
        #expect(fixture.controller.lastOutcome?.trigger == .manual)
        #expect(fixture.controller.lastExportedAt == exportT0)
        #expect(fixture.preferences.lastExportedAt == exportT0)
        #expect(!fixture.controller.isExporting)
        #expect(try fixture.folder.names().count == 2)

        // Idempotent from the controller too.
        await fixture.controller.exportNow()
        #expect(fixture.report?.unchanged == 2)
    }

    @Test func remembersTheToggle() async throws {
        let fixture = try await ControllerFixture()
        #expect(!fixture.controller.isAutoExportEnabled)

        fixture.controller.isAutoExportEnabled = true
        #expect(fixture.preferences.isAutoExportEnabled)
        #expect(fixture.makeController().isAutoExportEnabled)
        await fixture.controller.waitUntilIdle()

        fixture.controller.isAutoExportEnabled = false
        #expect(!fixture.preferences.isAutoExportEnabled)
    }

    @Test func turningAutoExportOnExportsEndedConversations() async throws {
        let fixture = try await ControllerFixture()
        try insertConversation(into: fixture.context, title: "Done")
        try insertConversation(into: fixture.context, title: "Live", start: 100, end: nil)

        fixture.controller.isAutoExportEnabled = true
        try await waitFor { fixture.controller.lastOutcome != nil }
        await fixture.controller.waitUntilIdle()

        #expect(fixture.controller.lastOutcome?.trigger == .automatic)
        #expect(fixture.report?.created == 1)
        #expect(fixture.report?.skippedOpen == 1)
        #expect(try fixture.folder.names().map { $0.contains("Done") } == [true])
    }

    @Test func exportsChangedConversationsAfterTheyEnd() async throws {
        let fixture = try await ControllerFixture(autoExport: true)
        let run = Task { await fixture.controller.run() }
        defer { run.cancel() }
        // After the launch catch-up (nothing to export yet).
        try await waitFor { fixture.controller.isFollowingChanges }
        #expect(fixture.controller.lastOutcome == nil)

        let live = try insertConversation(into: fixture.context, title: "Standup", end: nil)
        await fixture.persistence.processHistory()
        await fixture.clock.waitForSleepers()
        fixture.clock.advance(by: .seconds(5))
        try await waitFor { fixture.controller.lastOutcome != nil }
        await fixture.controller.waitUntilIdle()
        // Still being recorded: left for later.
        #expect(fixture.report?.skippedOpen == 1)
        #expect(try fixture.folder.names().isEmpty)

        live.endedAt = exportTime(30)
        try fixture.context.save()
        await fixture.persistence.processHistory()
        await fixture.clock.waitForSleepers()
        fixture.clock.advance(by: .seconds(5))
        try await waitFor { fixture.report?.created == 1 }
        #expect(try fixture.folder.names().count == 1)
    }

    @Test func debouncesBurstsOfChanges() async throws {
        let fixture = try await ControllerFixture(autoExport: true)
        await fixture.controller.flushAutoExport()  // Nothing yet.

        for index in 0..<3 {
            try insertConversation(into: fixture.context, title: "Burst \(index)", start: Double(index) * 100)
            fixture.controller.scheduleAutoExport(after: fixture.controller.autoExportDelay)
            await fixture.clock.waitForSleepers()
            fixture.clock.advance(by: .seconds(2))
        }
        #expect(fixture.controller.lastOutcome == nil)
        #expect(fixture.clock.sleeperCount == 1)
        fixture.clock.advance(by: .seconds(3))
        try await waitFor { fixture.report != nil }
        await fixture.controller.waitUntilIdle()
        #expect(fixture.report?.created == 3)
        #expect(try fixture.folder.names().count == 3)
    }

    @Test func flushExportsWithoutWaiting() async throws {
        let fixture = try await ControllerFixture(autoExport: true)
        try insertConversation(into: fixture.context)

        await fixture.controller.flushAutoExport()

        #expect(fixture.report?.created == 1)
    }

    @Test func doesNothingAutomaticallyWhenOff() async throws {
        let fixture = try await ControllerFixture()
        try insertConversation(into: fixture.context)

        await fixture.controller.flushAutoExport()

        #expect(fixture.controller.lastOutcome == nil)
        #expect(try fixture.folder.names().isEmpty)
    }

    @Test func aFailedAutomaticExportIsRetriedInFull() async throws {
        let fixture = try await ControllerFixture(
            autoExport: true, destination: .unavailable(.iCloudDriveUnavailable))
        try insertConversation(into: fixture.context)

        await fixture.controller.flushAutoExport()
        #expect(fixture.controller.lastOutcome?.result == .failure(.iCloudDriveUnavailable))
        #expect(fixture.preferences.needsFullExport)
        #expect(fixture.controller.lastExportedAt == nil)

        // iCloud Drive is back (a new launch). The history the failed export
        // read is gone, but the full export still writes the file.
        fixture.destination = fixture.folder.destination
        let relaunched = fixture.makeController()
        await relaunched.flushAutoExport()

        guard case .success(let report) = relaunched.lastOutcome?.result else {
            Issue.record("Expected a successful export")
            return
        }
        #expect(report.created == 1)
        #expect(!fixture.preferences.needsFullExport)
    }
}
