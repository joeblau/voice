import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app-side wiring of the Markdown export (#78): the Info.plist that
/// makes the folder show in Files, the environment's controller and what
/// Settings says. The export itself is covered by `swift test` in BlauKit.
@Suite("Markdown export wiring")
@MainActor
struct MarkdownExportAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theContainerIsPublishedToICloudDriveAsBlau() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let containers = try #require(info["NSUbiquitousContainers"] as? [String: Any])
        let blau = try #require(containers[BlauCloud.containerIdentifier] as? [String: Any])
        #expect(blau["NSUbiquitousContainerIsDocumentScopePublic"] as? Bool == true)
        #expect(blau["NSUbiquitousContainerName"] as? String == "Blau")
        #expect(blau["NSUbiquitousContainerSupportedFolderLevels"] as? String == "Any")
    }

    @Test func nonLiveEnvironmentsExportToATemporaryFolder() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        await environment.persistence.start()
        let context = try #require(environment.modelContainer).mainContext
        let conversation = Conversation(startedAt: Self.t0, endedAt: Self.t0.addingTimeInterval(60), title: "Plan")
        context.insert(conversation)
        context.insert(
            StoredUtterance(
                conversation: conversation, role: .user, text: "Hello", startedAt: Self.t0, isFinal: true,
                source: .parakeet))
        try context.save()

        await environment.markdownExport.exportNow()

        guard case .success(let report) = environment.markdownExport.lastOutcome?.result else {
            Issue.record(
                "Expected a successful export, got \(String(describing: environment.markdownExport.lastOutcome))")
            return
        }
        #expect(report.created == 1)
        #expect(
            report.directory.path(percentEncoded: false).hasPrefix(URL.temporaryDirectory.path(percentEncoded: false)))
        let files = try FileManager.default.contentsOfDirectory(atPath: report.directory.path(percentEncoded: false))
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("(\(MarkdownExportFileName.shortID(conversation.id))).md") == true)
        #expect(!environment.markdownExport.isAutoExportEnabled)
        try? FileManager.default.removeItem(at: report.directory)
    }

    @Test func anUnsignedBuildSaysItCannotExport() async throws {
        let persistence = PersistenceController.inMemory()
        let export = MarkdownExportController.live(persistence: persistence)
        try #require(!persistence.options.cloudKitEntitled)

        await export.exportNow()

        #expect(export.lastOutcome?.result == .failure(.notAvailableInThisBuild))
        let status = try #require(MarkdownExportStatus(outcome: export.lastOutcome, lastExportedAt: nil))
        #expect(status.isWarning)
        #expect(status.message.contains("isn't signed for iCloud"))
    }

    @Test func settingsDescribesEveryOutcome() throws {
        #expect(MarkdownExportStatus(outcome: nil, lastExportedAt: nil) == nil)
        #expect(MarkdownExportStatus(outcome: nil, lastExportedAt: Self.t0)?.isWarning == false)

        let errors: [MarkdownExportError] = [
            .iCloudDriveUnavailable, .notAvailableInThisBuild, .storeUnavailable, .folderUnavailable("x"),
        ]
        for error in errors {
            let outcome = MarkdownExportController.Outcome(
                trigger: .manual, finishedAt: Self.t0, result: .failure(error))
            let status = try #require(MarkdownExportStatus(outcome: outcome, lastExportedAt: nil))
            #expect(status.isWarning)
            #expect(!status.message.isEmpty)
        }

        var report = MarkdownExportReport(directory: URL.temporaryDirectory)
        report.unchanged = 3
        #expect(MarkdownExportStatus.summary(of: report).contains("all up to date"))
        report.created = 1
        report.renamed = 1
        #expect(MarkdownExportStatus.summary(of: report).contains("1 new, 1 updated"))

        report.failures = [UUID(): "disk full"]
        let partial = MarkdownExportController.Outcome(
            trigger: .automatic, finishedAt: Self.t0, result: .success(report))
        #expect(MarkdownExportStatus(outcome: partial, lastExportedAt: nil)?.isWarning == true)
    }
}
