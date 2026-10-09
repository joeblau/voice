import BlauCore
import BlauMemory
import BlauPersistence
import BlauTopics
import Foundation
import SwiftData
import Synchronization
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
    /// text only, the pinned memory (the About Me page, the profile summary
    /// and facts) and tool results, the learning
    /// transcripts; audio comes back.
    @Test func theSentToXAIListCoversWhatTheAppSends() {
        let text = SentToXAISection.items.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        #expect(SentToXAISection.items.count == 4)
        #expect(text.contains("Your audio is never sent"))
        #expect(text.contains("Voice ID"))
        #expect(text.contains("About Me"))
        #expect(text.contains("memory searches"))
        #expect(text.contains("Learn From Conversations"))
        #expect(text.contains("Grok's reply as audio"))
    }

    /// With Markdown copies in iCloud Drive (#78), deleting conversations
    /// says they stay (#149 review).
    @Test func deletingConversationsMentionsTheMarkdownCopies() {
        let without = PrivacySettingsView.confirmationMessage(.conversations, count: 3)
        #expect(!without.contains("Markdown"))
        let with = PrivacySettingsView.confirmationMessage(.conversations, count: 3, keepsMarkdownCopies: true)
        #expect(
            with
                == "This deletes 3 conversations from this iPhone, iCloud and your other devices. "
                + "The Markdown copies in iCloud Drive → Blau aren't deleted; remove them in Files.")
        #expect(
            PrivacySettingsView.confirmationMessage(.everything, count: 0, keepsMarkdownCopies: true)
                .contains("Markdown copies"))
        // Nothing about Markdown where no conversation is deleted.
        #expect(
            !PrivacySettingsView.confirmationMessage(.learnedFacts, count: 2, keepsMarkdownCopies: true)
                .contains("Markdown"))
    }

    @Test func aDeleteSaysWhatItIsWaitingFor() {
        #expect(PrivacySettingsView.progressMessage(.conversations) == "Deleting…")
        #expect(PrivacySettingsView.progressMessage(.voiceprint) == "Deleting…")
        for scope in [DataEraseScope.learnedFacts, .knowledge, .everything] {
            #expect(PrivacySettingsView.progressMessage(scope) == "Finishing Blau's memory update, then deleting…")
        }
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
            .learnedFacts, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
            conversation: .idle)

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
            .conversations, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
            conversation: .idle)
        #expect(fixture.log.load().records.count == 1)
        #expect(fixture.notes.load().count == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
    }

    /// The consolidation log keeps the topic summaries each run rewrote:
    /// the titles and summaries of conversations. Deleting the
    /// conversations removes them from the change history too, while the
    /// profile's own history stays (#67 review).
    @Test func deletingConversationsRemovesTheirSummariesFromTheChangeHistory() async throws {
        let fixture = try await makeFixture()
        let change = TopicSummaryChange(
            topicID: UUID(), title: "Moving to Lisbon", before: nil, after: "Joe plans the move to Lisbon.")
        var log = fixture.log.load()
        log.records[0].topicChanges = [change]
        let topicOnly = ProfileConsolidationRecord(
            date: Self.t0.addingTimeInterval(60), reason: .weekly, before: "Background: The user lives in Lisbon.",
            after: "Background: The user lives in Lisbon.", topicChanges: [change])
        log.insert(topicOnly)
        fixture.log.save(log)

        _ = try await PrivacyDataEraser.erase(
            .conversations, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
            conversation: .idle)

        let records = fixture.log.load().records
        #expect(records.count == 1)
        #expect(records.first?.after == "Background: The user lives in Lisbon.")
        #expect(records.allSatisfy { $0.topicChanges.isEmpty })
        // What Settings → Memory → Profile → Changes shows.
        #expect(fixture.profile.log.records == records)
        #expect(fixture.notes.load().count == 1)
        #expect(await fixture.pinned.pinnedMemory().facts.map(\.text) == ["User lives in Lisbon"])
    }

    @Test func nothingIsDeletedWhileAConversationRuns() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: PrivacyDataEraser.Refusal.conversationRunning) {
            try await PrivacyDataEraser.erase(
                .everything, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
                conversation: .init(isActive: { true }))
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
        #expect(fixture.log.load().records.count == 1)
    }

    /// Answers `false` the first `falseCount` times it is asked, then
    /// `true`: a conversation that starts while the delete waits.
    @MainActor
    private final class StartsLater {
        private var asked = 0
        private let falseCount: Int

        init(after falseCount: Int) { self.falseCount = falseCount }

        func next() -> Bool {
            asked += 1
            return asked > falseCount
        }
    }

    /// A conversation started while the delete waited for the memory update
    /// (the user dismissed Settings and tapped Record): nothing is deleted,
    /// here or on this device (#149 review).
    @Test(arguments: [DataEraseScope.learnedFacts, .knowledge, .everything])
    func aConversationStartedDuringTheWaitStopsTheDelete(_ scope: DataEraseScope) async throws {
        let fixture = try await makeFixture()
        let recording = StartsLater(after: 1)

        await #expect(throws: PrivacyDataEraser.Refusal.conversationRunning) {
            try await PrivacyDataEraser.erase(
                scope, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
                conversation: .init(isActive: { recording.next() }))
        }

        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<ProfileBlock>()) == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<MemoryDocument>()) == 1)
        #expect(fixture.log.load().records.count == 1)
        #expect(fixture.notes.load().count == 1)
        #expect(await fixture.pinned.pinnedMemory().facts.map(\.text) == ["User lives in Lisbon"])
    }

    /// The microphone, read with an `await`, is asked again too.
    @Test func aMicrophoneTurnedOnDuringTheWaitStopsTheDelete() async throws {
        let fixture = try await makeFixture()
        let capturing = StartsLater(after: 1)

        await #expect(throws: PrivacyDataEraser.Refusal.conversationRunning) {
            try await PrivacyDataEraser.erase(
                .conversations, in: fixture.context, profileMemory: fixture.profile, exports: DataExportModel(),
                conversation: .init(isActive: { false }, isCapturing: { capturing.next() }))
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<Fact>()) == 1)
    }

    // MARK: Exporting

    @Test func exportFilesAreReplacedAndRemoved() throws {
        let export = DataExport(exportedAt: Self.t0, schemaVersion: "2.0.0")
        let first = try DataExportFiles.write(export)
        #expect(first.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        let second = try DataExportFiles.write(export)
        // The zip keeps its readable name, in a folder of its own.
        #expect(second.lastPathComponent == first.lastPathComponent)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: DataExportFiles.directory.path(percentEncoded: false))
                == [second.deletingLastPathComponent().lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        DataExportFiles.removeAll()
        #expect(!FileManager.default.fileExists(atPath: DataExportFiles.directory.path(percentEncoded: false)))
    }

    /// `remove(_:)` takes one export's folder; a later export stays.
    @Test func removingOneExportLeavesALaterOne() throws {
        let export = DataExport(exportedAt: Self.t0, schemaVersion: "2.0.0")
        let first = try DataExportFiles.write(export)
        // A later export replaced it; removing the first again is harmless.
        let second = try DataExportFiles.write(export)
        DataExportFiles.remove(first)
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
        DataExportFiles.remove(second)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: DataExportFiles.directory.path(percentEncoded: false))
                .isEmpty)
        DataExportFiles.removeAll()
    }

    /// Leaving Privacy & Data drops its export model; the zip it offered
    /// goes with it, not at the next export or launch (#149 review).
    @Test func leavingPrivacyRemovesTheExportItOffered() async throws {
        let fixture = try await makeFixture()
        var exports: DataExportModel? = DataExportModel()
        await exports?.prepare(DataExportModel.writer(for: fixture.context.container, app: "test"))
        let url = try #require(exports?.export?.url)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        exports = nil

        try await waitFor { !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        #expect(
            !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)))
    }

    /// After a delete, Share Export no longer offers the zip the delete
    /// removed (#149 review).
    @Test func deletingWithdrawsAnEarlierExport() async throws {
        let fixture = try await makeFixture()
        let exports = DataExportModel()
        await exports.prepare(DataExportModel.writer(for: fixture.context.container, app: "test"))
        let export = try #require(exports.export)
        #expect(export.counts.facts == 1)
        #expect(FileManager.default.fileExists(atPath: export.url.path(percentEncoded: false)))

        _ = try await PrivacyDataEraser.erase(
            .everything, in: fixture.context, profileMemory: fixture.profile, exports: exports,
            conversation: .idle)

        #expect(exports.export == nil)
        #expect(!exports.failed)
        #expect(!FileManager.default.fileExists(atPath: export.url.path(percentEncoded: false)))
    }

    /// An export still being written when data is deleted holds the deleted
    /// data: it is thrown away, not offered, and its zip doesn't outlive the
    /// delete.
    @Test func anExportFinishingAfterADeleteIsDiscarded() async throws {
        let fixture = try await makeFixture()
        let exports = DataExportModel()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, doRelease) = AsyncStream<Void>.makeStream()
        let container = fixture.context.container
        let exportedAt = Self.t0
        let preparing = Task {
            await exports.prepare {
                // Read before the delete, written after it.
                let snapshot = try DataExport.snapshot(in: ModelContext(container), exportedAt: exportedAt)
                didStart.yield()
                for await _ in release { break }
                return (try DataExportFiles.write(snapshot), snapshot.counts)
            }
        }
        for await _ in started { break }
        #expect(exports.isPreparing)

        _ = try await PrivacyDataEraser.erase(
            .everything, in: fixture.context, profileMemory: fixture.profile, exports: exports,
            conversation: .idle)
        doRelease.yield()
        await preparing.value

        #expect(!exports.isPreparing)
        #expect(exports.export == nil)
        #expect(!exports.failed)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                atPath: DataExportFiles.directory.path(percentEncoded: false))) ?? []
        #expect(files.isEmpty)
    }
}

// MARK: - An extraction during a delete

/// Delete Learned Facts while fact extraction (#66) is talking to xAI: the
/// request is cancelled and nothing it would have learned, neither facts
/// nor a note for the profile, appears after the delete (#149 review).
@Suite("Privacy: extraction during a delete", .serialized)
@MainActor
struct PrivacyExtractionAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    nonisolated private static let lisbonReply = #"""
        {"entities":[{"name":"Lisbon","type":"place","aliases":[],"summary":""}],
         "facts":[{"subject":"user","predicate":"lives in","object":"Lisbon","confidence":0.9,"source":1,"replaces":[]}],
         "summary":"The user moved to Lisbon."}
        """#

    /// The first request takes a minute unless it is cancelled, like an
    /// xAI request on URLSession; later ones answer at once.
    private final class SlowFirstRequest: TextGenerator {
        let requests = Mutex(0)
        let cancelled = Mutex(false)

        func isAvailable() async -> Bool { true }

        func generate(_ request: TextGenerationRequest) async throws -> String {
            let index = requests.withLock { count in
                count += 1
                return count
            }
            if index == 1 {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
            }
            return PrivacyExtractionAppTests.lisbonReply
        }
    }

    private struct Harness {
        let persistence: PersistenceController
        let container: ModelContainer
        let generator: SlowFirstRequest
        let pipeline: FactExtractionPipeline
        let notes: InMemoryProfileConsolidationNoteStore
        let profile: ProfileMemory
    }

    /// Records a conversation whose topic closes and goes to extraction,
    /// and returns once its request is in flight.
    private func extractionInFlight() async throws -> Harness {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let topics = TopicLifecycle.offline(transcript: recorder)
        let transcript = TopicTrackingTranscript(base: recorder, topics: topics)

        let preference = InMemoryMemoryLearningPreferenceStore()
        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let generator = SlowFirstRequest()
        let pipeline = FactExtractionPipeline(
            generator: generator,
            transcripts: DeferredTopicTranscriptSource { try await recorder.conversationStore() },
            store: facts, isEnabled: { preference.load() }, signposter: .disabled(.memory))
        let learning = MemoryLearning(
            settings: MemoryLearningSettings(store: preference), pipeline: pipeline, facts: facts)

        let store = DeferredProfileMemoryStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let notes = InMemoryProfileConsolidationNoteStore()
        let profile = ProfileMemory(
            consolidator: ProfileConsolidator(
                generator: NeverCalledGenerator(), store: store, notes: notes, signposter: .disabled(.memory)),
            pinned: PinnedMemoryProvider(store: store), schedulesBackgroundWork: false)
        learning.start(following: topics)
        profile.start(learning: learning)

        let conversation = ConversationID()
        try await transcript.beginConversation(conversation, at: Self.t0)
        try await transcript.record(
            BlauCore.Utterance(
                conversationID: conversation, speaker: .user, text: "I moved to Lisbon last month.",
                timeRange: TimeRange(start: .zero, duration: .seconds(3)), startedAt: Self.t0,
                speakerDecision: .accept))
        try await transcript.finishConversation(conversation, at: Self.t0.addingTimeInterval(30))
        await topics.waitUntilIdle()
        try await waitFor { generator.requests.withLock { $0 } == 1 }
        return Harness(
            persistence: persistence, container: container, generator: generator, pipeline: pipeline, notes: notes,
            profile: profile)
    }

    @Test func anExtractionRunningDuringTheDeleteLeavesNothingBehind() async throws {
        let harness = try await extractionInFlight()
        let clock = ContinuousClock()
        let started = clock.now

        let summary = try await PrivacyDataEraser.erase(
            .learnedFacts, in: harness.container.mainContext, profileMemory: harness.profile, exports: nil,
            conversation: .idle)

        // The minute-long request was cancelled, not waited out.
        #expect(clock.now - started < .seconds(30))
        #expect(harness.generator.cancelled.withLock { $0 })
        #expect(summary.facts == 0)
        // The topic closed before the delete isn't learned again.
        await harness.pipeline.waitUntilIdle()
        #expect(await harness.pipeline.pendingTopicIDs.isEmpty)
        #expect(!(await harness.pipeline.isSuspended))
        #expect(harness.generator.requests.withLock { $0 } == 1)
        #expect(try ModelContext(harness.container).fetchCount(FetchDescriptor<Fact>()) == 0)
        #expect(harness.notes.load().isEmpty)
        #expect(await harness.profile.consolidator.pendingNotes().isEmpty)
    }

    /// A delete that never happened leaves extraction where it was: the
    /// topic runs again and is learned.
    @Test func aFailedDeleteLetsExtractionCarryOn() async throws {
        let harness = try await extractionInFlight()
        await harness.profile.prepareToErase()
        #expect(await harness.pipeline.isSuspended)
        #expect(await harness.pipeline.pendingTopicIDs.count == 1)

        await harness.profile.eraseFailed()

        try await waitFor {
            await harness.pipeline.waitUntilIdle()
            return (try? ModelContext(harness.container).fetchCount(FetchDescriptor<Fact>())) == 1
        }
        #expect(harness.generator.requests.withLock { $0 } == 2)
        try await waitFor { await harness.profile.consolidator.pendingNotes().count == 1 }
    }

    /// A conversation that starts while the delete is preparing (here: as
    /// soon as extraction is suspended) stops the delete, and extraction
    /// carries on: the topic is learned (#149 review).
    @Test func aConversationStartedWhilePreparingLetsExtractionCarryOn() async throws {
        let harness = try await extractionInFlight()
        let pipeline = harness.pipeline

        await #expect(throws: PrivacyDataEraser.Refusal.conversationRunning) {
            try await PrivacyDataEraser.erase(
                .learnedFacts, in: harness.container.mainContext, profileMemory: harness.profile, exports: nil,
                conversation: .init(isActive: { false }, isCapturing: { await pipeline.isSuspended }))
        }

        #expect(!(await pipeline.isSuspended))
        try await waitFor {
            await pipeline.waitUntilIdle()
            return (try? ModelContext(harness.container).fetchCount(FetchDescriptor<Fact>())) == 1
        }
        #expect(harness.generator.cancelled.withLock { $0 })
        try await waitFor { await harness.profile.consolidator.pendingNotes().count == 1 }
    }
}

/// Polls `condition` for up to five seconds of real time.
@MainActor
private func waitFor(_ condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
    async throws
{
    for _ in 0..<500 {
        if (try? await condition()) == true { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
}

/// A text model the tests never reach: nothing here consolidates.
private struct NeverCalledGenerator: TextGenerator {
    struct Unexpected: Error {}

    func isAvailable() async -> Bool { false }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        throw Unexpected()
    }
}
