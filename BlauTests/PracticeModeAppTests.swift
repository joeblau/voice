import BlauCore
import BlauPersistence
import BlauRealtime
import Foundation
import SwiftData
import Testing

@testable import Blau

/// Practice mode's app side (#69): the live session declares the practice
/// tools and they drill the collections in the store the app has open,
/// "Practice with Grok" becomes the user's turn, and the Collections
/// screen's practice record. The tools, scheduling, topics and the full
/// ten-question run are covered by `swift test` in BlauKit.
@Suite("Practice mode in the app")
@MainActor
struct PracticeModeAppTests {
    private func live() throws -> (AppEnvironment, UserDefaults, String) {
        let suite = "com.joeblau.blau.tests.practice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let environment = AppEnvironment.live(config: .fallback, defaults: defaults, persistence: .inMemory())
        return (environment, defaults, suite)
    }

    @Test func theLiveSessionDeclaresThePracticeToolsAndTeachesThem() async throws {
        let (environment, defaults, suite) = try live()
        defer { defaults.removePersistentDomain(forName: suite) }
        for name in PracticeTools.names {
            #expect(environment.realtimeSession.toolRegistry.tool(named: name) != nil)
        }
        let session = await environment.realtimeSession.configurator.currentSession()
        let declared = session.tools ?? []
        #expect(declared.contains(NextPracticeQuestionTool.definition))
        #expect(declared.contains(RecordPracticeResultTool.definition))
        #expect(session.instructions?.contains("# Practice") == true)
    }

    @Test func theToolsDrillTheCollectionsInTheOpenStore() async throws {
        let (environment, defaults, suite) = try live()
        defer { defaults.removePersistentDomain(forName: suite) }
        await environment.persistence.start()
        let collectionID = UUID()
        _ = try await environment.knowledgeBase.saveDocument(
            collectionID, kind: .collection, title: "YC interview questions", body: "")
        _ = try await environment.knowledgeBase.addItems(
            [.init(prompt: "What are you building?", referenceAnswer: "Inventory software for restaurants.")],
            to: collectionID)

        let next = try #require(environment.realtimeSession.toolRegistry.tool(named: NextPracticeQuestionTool.name))
        let output = try await next.call(Data(#"{"collection":"YC questions"}"#.utf8))
        #expect(output.contains("What are you building?"))
        #expect(output.contains("Inventory software for restaurants."))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let id = try #require((object["question"] as? [String: Any])?["id"] as? String)

        let record = try #require(
            environment.realtimeSession.toolRegistry.tool(named: RecordPracticeResultTool.name))
        _ = try await record.call(Data(#"{"item_id":"\#(id)","score":0.75,"notes":"Name the customer."}"#.utf8))
        let container = try #require(environment.modelContainer)
        let item = try #require(try container.mainContext.fetch(FetchDescriptor<CollectionItem>()).first)
        #expect(item.practiceCount == 1)
        #expect(item.score == 0.75)
    }

    @Test func practiceWithGrokBecomesTheUsersTurn() async throws {
        let launcher = PracticeLauncher()
        launcher.practice(collectionTitle: "YC interview questions")
        let request = try #require(launcher.request)
        #expect(launcher.take(UUID()) == nil)
        #expect(launcher.take(request.id) == request)
        #expect(launcher.request == nil)

        let realtime = FakeRealtimeService(isConnected: true)
        let idle = FakeConversationSession()
        #expect(!(await launcher.send(request, conversation: idle, realtime: realtime, clock: SystemClock())))
        #expect(realtime.sentUtterances.isEmpty)

        let running = FakeConversationSession()
        try await running.start()
        #expect(await launcher.send(request, conversation: running, realtime: realtime, clock: SystemClock()))
        let sent = try #require(realtime.sentUtterances.first)
        #expect(sent.text == PracticeTools.startRequest(collectionTitle: "YC interview questions"))
        #expect(sent.speaker == .user)
        #expect(sent.speakerDecision == .accept)
        #expect(launcher.failureMessage == nil)

        let offline = FakeRealtimeService(isConnected: false)
        #expect(!(await launcher.send(request, conversation: running, realtime: offline, clock: SystemClock())))
        #expect(launcher.failureMessage != nil)
    }

    @Test func theCollectionScreenSummarizesThePracticeRecord() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let collection = MemoryDocument(kind: .collection, title: "YC", createdAt: now)
        context.insert(collection)
        let items = ["What are you building?", "Why now?", "Who are your users?"].enumerated().map { index, prompt in
            let item = CollectionItem(ordinal: index, prompt: prompt, createdAt: now)
            context.insert(item)
            item.document = collection
            return item
        }
        var stats = CollectionSummary.Stats(items: items, collectionID: collection.id, now: now)
        #expect(stats.practiced == 0)
        #expect(stats.averageLine == nil)
        #expect(stats.upNext == "What are you building?")

        items[0].recordPractice(at: now.addingTimeInterval(-86_400), score: 0.9)
        items[1].recordPractice(at: now.addingTimeInterval(-3_600), score: 0.5)
        stats = CollectionSummary.Stats(items: items, collectionID: collection.id, now: now)
        #expect(stats.practiced == 2)
        #expect(stats.total == 3)
        #expect(stats.practicedLine == "2 of 3")
        #expect(stats.averageLine == 0.7.formatted(.percent.precision(.fractionLength(0))))
        #expect(stats.lastPracticedAt == now.addingTimeInterval(-3_600))
        // Never practiced first.
        #expect(stats.upNext == "Who are your users?")
    }
}
