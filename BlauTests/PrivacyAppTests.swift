import BlauCore
import BlauMemory
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import Blau

/// Privacy, data controls and the privacy manifest (#79): the bundled
/// manifests, what Settings → Privacy & Data says and exports, and what a
/// delete removes beyond the synced records. `DataEraser` and `DataExport`
/// themselves are covered by `swift test` in BlauKit.
@Suite("Privacy and data controls", .serialized)
@MainActor
struct PrivacyAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Privacy manifests

    private func manifest(in bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appending(path: "PrivacyInfo.xcprivacy"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func reasons(_ manifest: [String: Any]) -> [String: [String]] {
        let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        return Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                (entry["NSPrivacyAccessedAPIType"] as? String).map {
                    ($0, entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
                }
            })
    }

    /// The app ships its manifest at the bundle's root, where App Store
    /// Connect and Xcode's privacy report look for it.
    @Test func theAppBundlesItsPrivacyManifest() throws {
        let manifest = try manifest(in: Bundle.main.bundleURL)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect(
            reasons(manifest) == [
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
                "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
                "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            ])
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.count == 1)
        let content = try #require(collected.first)
        #expect(content["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeOtherUserContent")
        #expect(content["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        #expect(
            content["NSPrivacyCollectedDataTypePurposes"] as? [String] == [
                "NSPrivacyCollectedDataTypePurposeAppFunctionality"
            ])
    }

    @Test func theWidgetExtensionBundlesItsPrivacyManifest() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let manifest = try manifest(in: plugins.appending(path: "BlauWidgets.appex"))
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect(reasons(manifest).isEmpty)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    // MARK: Wording

    @Test func learnedFactsWording() {
        #expect(PrivacySettingsView.buttonTitle(.learnedFacts) == "Delete Learned Facts…")
        #expect(PrivacySettingsView.confirmationTitle(.learnedFacts) == "Delete what Blau learned?")
        #expect(
            PrivacySettingsView.confirmationMessage(.learnedFacts, count: 12)
                == "This deletes 12 learned facts and the profile summary built from them from this iPhone, "
                + "iCloud and your other devices. Your About Me, company, notes and collections stay.")
        var summary = DataEraseSummary()
        summary.facts = 1
        #expect(PrivacySettingsView.resultMessage(.learnedFacts, summary: summary) == "Deleted 1 learned fact.")
        // Every scope has its own button.
        let titles = DataEraseScope.allCases.map(PrivacySettingsView.buttonTitle)
        #expect(Set(titles).count == DataEraseScope.allCases.count)
    }

    /// What the pane says is sent to xAI matches what the pipeline sends:
    /// text only, the pinned memory and tool results, the learning
    /// transcripts; audio comes back.
    @Test func theSentToXAIListCoversWhatTheAppSends() {
        let text = SentToXAISection.items.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        #expect(SentToXAISection.items.count == 4)
        #expect(text.contains("Your audio is never sent"))
        #expect(text.contains("Voice ID"))
        #expect(text.contains("memory searches"))
        #expect(text.contains("Learn From Conversations"))
        #expect(text.contains("Grok's reply as audio"))
    }

    @Test func exportSummary() {
        let counts = DataExport.Counts(
            conversations: 3, utterances: 40, documents: 1, facts: 12, entities: 4, voiceprints: 1)
        #expect(DataExportSection.summary(counts) == "3 conversations, 1 page and 12 learned facts")
    }

    // MARK: Deleting

    /// A store with a learned fact, a profile block and a page, and a
    /// `ProfileMemory` whose log has a consolidation and a waiting note.
    private struct Fixture {
        let persistence: PersistenceController
        let context: ModelContext
        let log: InMemoryProfileConsolidationLogStore
        let notes: InMemoryProfileConsolidationNoteStore
        let pinned: PinnedMemoryProvider
        let profile: ProfileMemory
    }

    private func makeFixture() async throws -> Fixture {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let context = container.mainContext
        context.insert(Fact(predicate: "lives in", objectText: "Lisbon", validFrom: Self.t0, origin: .extracted))
        context.insert(ProfileBlock(text: "Background: The user lives in Lisbon.", updatedAt: Self.t0))
        context.insert(MemoryDocument(kind: .company, title: "Blau", body: "A voice app.", createdAt: Self.t0))
        try context.save()

        let store = DeferredProfileMemoryStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let record = ProfileConsolidationRecord(
            date: Self.t0, reason: .manual, before: "", after: "Background: The user lives in Lisbon.")
        let log = InMemoryProfileConsolidationLogStore(ProfileConsolidationLog(lastRunAt: Self.t0, records: [record]))
        let notes = InMemoryProfileConsolidationNoteStore([
            ProfileConsolidationNote(topicID: UUID(), date: Self.t0, summary: "The user moved to Lisbon.")
        ])
        let pinned = PinnedMemoryProvider(store: store)
        let consolidator = ProfileConsolidator(
            generator: NeverCalledGenerator(), store: store, log: log, notes: notes, signposter: .disabled(.memory))
        let profile = ProfileMemory(consolidator: consolidator, pinned: pinned, schedulesBackgroundWork: false)
        return Fixture(
            persistence: persistence, context: context, log: log, notes: notes, pinned: pinned, profile: profile)
    }

    @Test func deletingLearnedFactsClearsThisDevicesCopies() async throws {
        let fixture = try await makeFixture()
        // The next session's instructions would carry the fact and profile.
        let before = await fixture.pinned.pinnedMemory()
        #expect(before.facts.map(\.text) == ["User lives in Lisbon"])
        #expect(before.profile?.contains("Lisbon") == true)
        // An export made earlier holds them too.
        try FileManager.default.createDirectory(at: DataExportFiles.directory, withIntermediateDirectories: true)
        try Data("export".utf8).write(to: DataExportFiles.directory.appending(path: "Blau Export.zip"))

        let summary = try await PrivacyDataEraser.erase(
            .learnedFacts, in: fixture.context, profileMemory: fixture.profile, isConversationRunning: false)

        #expect(summary.facts == 1)
        #expect(summary.profileBlocks == 1)
        // The pinned cache was dropped: nothing learned reaches Grok.
        let after = await fixture.pinned.pinnedMemory()
        #expect(after.facts.isEmpty)
        #expect(after.profile?.contains("Lisbon") != true)
        // This device's log and notes held the same text.
        #expect(fixture.log.load().records.isEmpty)
        #expect(fixture.notes.load().isEmpty)
        #expect(fixture.profile.log.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DataExportFiles.directory.path(percentEncoded: false)))
        // The user's own page stays.
        #expect(try fixture.context.fetchCount(FetchDescriptor<MemoryDocument>()) == 1)
    }

    @Test func deletingConversationsLeavesTheLearnedMemory() async throws {
        let fixture = try await makeFixture()
        _ = try await PrivacyDataEraser.erase(
            .conversations, in: fixture.context, profileMemory: fixture.profile, isConversationRunning: false)
        #expect(fixture.log.load().records.count == 1)
        #expect(fixture.notes.load().count == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
    }

    @Test func nothingIsDeletedWhileAConversationRuns() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: PrivacyDataEraser.Refusal.conversationRunning) {
            try await PrivacyDataEraser.erase(
                .everything, in: fixture.context, profileMemory: fixture.profile, isConversationRunning: true)
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
        #expect(fixture.log.load().records.count == 1)
    }

    // MARK: Exporting

    @Test func exportFilesAreReplacedAndRemoved() throws {
        let export = DataExport(exportedAt: Self.t0, schemaVersion: "2.0.0")
        let first = try DataExportFiles.write(export)
        #expect(first.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        let second = try DataExportFiles.write(export)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: DataExportFiles.directory.path(percentEncoded: false))
                == [second.lastPathComponent])
        DataExportFiles.removeAll()
        #expect(!FileManager.default.fileExists(atPath: DataExportFiles.directory.path(percentEncoded: false)))
    }
}

/// A text model the tests never reach: nothing here consolidates.
private struct NeverCalledGenerator: TextGenerator {
    struct Unexpected: Error {}

    func isAvailable() async -> Bool { false }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        throw Unexpected()
    }
}
