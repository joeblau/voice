import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

/// Collections in memory, recording attempts like the synced store does.
final class FakePracticeBackend: PracticeBackend {
    struct Attempt: Hashable {
        var itemID: UUID
        var score: Double?
        var date: Date
    }

    private struct State {
        var collections: [PracticeCollection] = []
        var items: [UUID: [PracticeItem]] = [:]
        var attempts: [Attempt] = []
    }

    private let state = Mutex(State())
    let failure: MemoryToolFailure?

    init(failure: MemoryToolFailure? = nil) {
        self.failure = failure
    }

    /// Adds a collection of `prompts`, each with the reference answer
    /// "Answer n". Returns its id.
    @discardableResult
    func add(_ title: String, prompts: [String], answers: Bool = true) -> UUID {
        let id = UUID()
        let items = prompts.enumerated().map { index, prompt in
            PracticeItem(
                id: UUID(), collectionID: id, ordinal: index, prompt: prompt,
                referenceAnswer: answers ? "Answer \(index + 1)" : nil)
        }
        state.withLock { state in
            state.collections.append(PracticeCollection(id: id, title: title, itemCount: items.count))
            state.items[id] = items
        }
        return id
    }

    func setItems(_ items: [PracticeItem], in collectionID: UUID) {
        state.withLock { $0.items[collectionID] = items }
    }

    func items(_ collectionID: UUID) -> [PracticeItem] { state.withLock { $0.items[collectionID] ?? [] } }
    var attempts: [Attempt] { state.withLock { $0.attempts } }

    func practiceCollections() async throws -> [PracticeCollection] {
        if let failure { throw failure }
        return state.withLock { state in
            state.collections.map { collection in
                let items = state.items[collection.id] ?? []
                let practiced = items.filter(\.isPracticed)
                let scores = practiced.compactMap(\.score)
                return PracticeCollection(
                    id: collection.id, title: collection.title, itemCount: items.count,
                    practicedCount: practiced.count,
                    averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                    lastPracticedAt: practiced.compactMap(\.lastPracticedAt).max())
            }
        }
    }

    func practiceItems(inCollection collectionID: UUID) async throws -> [PracticeItem] {
        if let failure { throw failure }
        return items(collectionID)
    }

    func recordPractice(itemID: UUID, score: Double?, at date: Date) async throws -> PracticeItem? {
        if let failure { throw failure }
        return state.withLock { state in
            for (collectionID, items) in state.items {
                guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
                var item = items[index]
                item.practiceCount += 1
                item.lastPracticedAt = date
                if let score { item.score = score }
                state.items[collectionID]?[index] = item
                state.attempts.append(Attempt(itemID: itemID, score: score, date: date))
                return item
            }
            return nil
        }
    }
}

/// Records what the practice tools asked of the topic recorder.
final class FakePracticeRunRecorder: PracticeRunRecording {
    enum Call: Hashable {
        case begin(title: String)
        case update(runID: UUID, summary: String)
        case end(runID: UUID)
    }

    private struct State {
        var calls: [Call] = []
        var open: Set<UUID> = []
        var accepts = true
    }

    private let state = Mutex(State())

    init(accepts: Bool = true) {
        state.withLock { $0.accepts = accepts }
    }

    /// Whether a conversation is running to take runs.
    func setAccepts(_ accepts: Bool) {
        state.withLock { $0.accepts = accepts }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var summaries: [String] {
        calls.compactMap { if case .update(_, let summary) = $0 { summary } else { nil } }
    }

    /// The conversation finished: every run is over.
    func finishConversation() {
        state.withLock { $0.open.removeAll() }
    }

    func beginPracticeRun(title: String, at date: Date) async -> UUID? {
        state.withLock { state in
            guard state.accepts else { return nil }
            let id = UUID()
            state.calls.append(.begin(title: title))
            state.open.insert(id)
            return id
        }
    }

    func updatePracticeRun(_ runID: UUID, summary: String) async {
        state.withLock { $0.calls.append(.update(runID: runID, summary: summary)) }
    }

    func endPracticeRun(_ runID: UUID, at date: Date) async {
        state.withLock { state in
            state.calls.append(.end(runID: runID))
            state.open.remove(runID)
        }
    }

    func isPracticeRunOpen(_ runID: UUID) async -> Bool {
        state.withLock { $0.open.contains(runID) }
    }
}

@Suite("Practice tools")
struct PracticeToolsTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let ycPrompts = [
        "What are you building?", "Who are your users?", "Why now?", "Who are your competitors?",
        "How do you make money?", "What's your traction?", "Why is this team the one to do it?",
        "What's the hardest part?", "How big can this get?", "What do you need from YC?", "What's your burn?",
    ]

    struct Harness {
        let backend = FakePracticeBackend()
        let recorder: FakePracticeRunRecorder
        let clock = ManualClock(now: PracticeToolsTests.now)
        let coordinator: PracticeCoordinator
        let tools: RealtimeToolRegistry

        init(recorder: FakePracticeRunRecorder = FakePracticeRunRecorder(), tokens: Int = 1_500) throws {
            self.recorder = recorder
            coordinator = PracticeCoordinator(
                backend: backend, runs: recorder,
                settings: PracticeToolSettings(
                    clock: clock, timeZone: { TimeZone(identifier: "UTC")! }, maximumOutputTokens: tokens))
            tools = try RealtimeToolRegistry(PracticeTools.all(coordinator: coordinator))
        }

        func call(_ name: String, _ arguments: String) async throws -> [String: Any] {
            let tool = try #require(tools.tool(named: name))
            let output = try await tool.call(Data(arguments.utf8))
            #expect(MemoryToolSettings.approximateTokens(output) <= 1_500)
            return try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        }

        func next(_ collection: String = "YC questions") async throws -> [String: Any] {
            try await call("next_practice_question", #"{"collection":"\#(collection)"}"#)
        }

        func record(_ id: String, score: Double, notes: String = "Lead with the customer.") async throws
            -> [String: Any]
        {
            try await call("record_practice_result", #"{"item_id":"\#(id)","score":\#(score),"notes":"\#(notes)"}"#)
        }
    }

    static func question(_ output: [String: Any]) throws -> [String: Any] {
        try #require(output["question"] as? [String: Any])
    }

    // MARK: Registry

    @Test func declaresFourValidTools() throws {
        let harness = try Harness()
        #expect(harness.tools.names == PracticeTools.names)
        #expect(
            PracticeTools.names == [
                "list_collection", "next_practice_question", "record_practice_result", "end_practice",
            ])
        for definition in harness.tools.definitions {
            guard case .function(_, let description, let parameters) = definition else {
                Issue.record("Not a function tool")
                continue
            }
            #expect(description?.isEmpty == false)
            guard case .object(let object) = parameters else {
                Issue.record("Parameters aren't an object")
                continue
            }
            #expect(object["type"] == "object")
        }
    }

    // MARK: A full run

    /// Acceptance criterion, client side: a full practice run of ten
    /// questions. Each question comes once, the first ten in collection
    /// order (none practiced before), with its reference answer; every
    /// attempt is recorded with its score; the run's topic opens once,
    /// gets a summary after each answer and closes at the end.
    @Test func aFullRunOfTenQuestions() async throws {
        let harness = try Harness()
        let collection = harness.backend.add("YC interview questions", prompts: Self.ycPrompts)
        var asked: [String] = []
        for number in 1...10 {
            let next = try await harness.next()
            #expect(next["collection"] as? String == "YC interview questions")
            #expect((next["started"] as? Bool) == (number == 1 ? true : nil))
            let question = try Self.question(next)
            asked.append(try #require(question["prompt"] as? String))
            #expect(question["number"] as? Int == number)
            #expect(question["reference_answer"] as? String == "Answer \(number)")
            let id = try #require(question["id"] as? String)
            let recorded = try await harness.record(id, score: Double(number) / 10)
            let run = try #require(recorded["run"] as? [String: Any])
            #expect(run["answered"] as? Int == number)
            #expect(run["total"] as? Int == 11)
            harness.clock.advance(by: .seconds(45))
        }
        #expect(asked == Array(Self.ycPrompts.prefix(10)))
        #expect(Set(asked).count == 10)
        #expect(harness.backend.attempts.count == 10)
        #expect(harness.backend.items(collection).prefix(10).allSatisfy { $0.practiceCount == 1 && $0.score != nil })

        let ended = try await harness.call("end_practice", "{}")
        let summary = try #require(ended["ended"] as? [String: Any])
        #expect(summary["answered"] as? Int == 10)
        #expect(summary["asked"] as? Int == 10)
        #expect(summary["average_score"] as? Double == 0.55)
        let weakest = try #require(summary["to_work_on"] as? [[String: Any]])
        #expect(
            weakest.map { $0["prompt"] as? String } == ["What are you building?", "Who are your users?", "Why now?"])
        #expect((summary["strongest"] as? [String: Any])?["prompt"] as? String == "What do you need from YC?")

        let calls = harness.recorder.calls
        #expect(calls.first == .begin(title: "Practice: YC interview questions"))
        #expect(calls.filter { if case .begin = $0 { true } else { false } }.count == 1)
        #expect(harness.recorder.summaries.count == 11)
        let last = try #require(harness.recorder.summaries.last)
        #expect(last.hasPrefix("Practiced 10 of 11 questions in YC interview questions, average 55%."))
        #expect(last.contains("- What are you building? 10%. Lead with the customer."))
        #expect(last.split(separator: "\n").count == 11)
        if case .end = calls.last {} else { Issue.record("The run's topic wasn't closed") }
        #expect(try await harness.call("end_practice", "{}")["message"] as? String == "No practice run is going on.")
    }

    @Test func theNextRunAsksTheWeakestAndLeastRecentFirst() async throws {
        let harness = try Harness()
        let collection = harness.backend.add("YC interview questions", prompts: Array(Self.ycPrompts.prefix(3)))
        let items = harness.backend.items(collection)
        // Practiced yesterday: strong, weak, middling.
        let yesterday = Self.now.addingTimeInterval(-86_400)
        harness.backend.setItems(
            [
                PracticeItem(
                    id: items[0].id, collectionID: collection, ordinal: 0, prompt: items[0].prompt, practiceCount: 1,
                    score: 0.9, lastPracticedAt: yesterday),
                PracticeItem(
                    id: items[1].id, collectionID: collection, ordinal: 1, prompt: items[1].prompt, practiceCount: 1,
                    score: 0.2, lastPracticedAt: yesterday),
                PracticeItem(
                    id: items[2].id, collectionID: collection, ordinal: 2, prompt: items[2].prompt, practiceCount: 1,
                    score: 0.5, lastPracticedAt: yesterday),
            ], in: collection)
        var order: [String] = []
        for _ in 0..<3 {
            order.append(try #require(try Self.question(try await harness.next())["prompt"] as? String))
        }
        #expect(order == ["Who are your users?", "Why now?", "What are you building?"])
        let done = try await harness.next()
        #expect(done["done"] as? Bool == true)
        #expect(done["question"] == nil)
        #expect((done["instruction"] as? String)?.contains("end_practice") == true)
    }

    @Test func aNewCollectionEndsTheRunAndStartsAnother() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?", "B?"])
        harness.backend.add("Sales objections", prompts: ["Too expensive?"])
        _ = try await harness.next()
        let sales = try await harness.next("sales")
        #expect(sales["started"] as? Bool == true)
        #expect(try Self.question(sales)["prompt"] as? String == "Too expensive?")
        let calls = harness.recorder.calls
        #expect(calls.count == 4)
        #expect(calls[0] == .begin(title: "Practice: YC interview questions"))
        if case .end = calls[2] {} else { Issue.record("The first run wasn't ended") }
        #expect(calls[3] == .begin(title: "Practice: Sales objections"))
    }

    @Test func aFinishedConversationStartsAFreshRun() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?", "B?"])
        #expect(try Self.question(try await harness.next())["prompt"] as? String == "A?")
        harness.recorder.finishConversation()
        let next = try await harness.next()
        #expect(next["started"] as? Bool == true)
        // A fresh run: nothing asked yet, and A was never answered.
        #expect(try Self.question(next)["prompt"] as? String == "A?")
    }

    @Test func withoutATopicARunEndsWhenLeftAlone() async throws {
        let harness = try Harness(recorder: FakePracticeRunRecorder(accepts: false))
        harness.backend.add("YC interview questions", prompts: ["A?", "B?"])
        _ = try await harness.next()
        harness.clock.advance(by: .seconds(60))
        #expect(try Self.question(try await harness.next())["prompt"] as? String == "B?")
        harness.clock.advance(by: .seconds(31 * 60))
        let next = try await harness.next()
        #expect(next["started"] as? Bool == true)
        #expect(try Self.question(next)["prompt"] as? String == "A?")
        #expect(await harness.coordinator.currentRun()?.recordingID == nil)
    }

    @Test func aRunStartedBeforeTheConversationWasTrackedGetsItsTopicLater() async throws {
        let recorder = FakePracticeRunRecorder(accepts: false)
        let harness = try Harness(recorder: recorder)
        harness.backend.add("YC interview questions", prompts: ["A?", "B?", "C?"])
        _ = try await harness.next()
        #expect(await harness.coordinator.currentRun()?.recordingID == nil)
        recorder.setAccepts(true)
        // Same run (B, not A again), now with a topic.
        #expect(try Self.question(try await harness.next())["prompt"] as? String == "B?")
        #expect(await harness.coordinator.currentRun()?.recordingID != nil)
        #expect(recorder.calls == [.begin(title: "Practice: YC interview questions")])
    }

    // MARK: Recording

    @Test(arguments: [(0.7, 0.7), (7, 0.7), (70, 0.7), (0, 0), (1, 1), (10, 1)])
    func scoresAreKeptBetweenZeroAndOne(_ given: Double, _ stored: Double) async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?"])
        let id = try #require(try Self.question(try await harness.next())["id"] as? String)
        let recorded = try await harness.record(id, score: given)
        #expect((recorded["recorded"] as? [String: Any])?["score"] as? Double == stored)
        #expect(harness.backend.attempts.last?.score == stored)
    }

    @Test func badScoresAndIdsAreRejected() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?"])
        _ = try await harness.next()
        let tool = try #require(harness.tools.tool(named: "record_practice_result"))
        await #expect(throws: RealtimeToolError.self) {
            _ = try await tool.call(Data(#"{"item_id":"not-an-id","score":0.5}"#.utf8))
        }
        await #expect(throws: RealtimeToolError.self) {
            _ = try await tool.call(Data(#"{"item_id":"\#(UUID().uuidString)","score":-1}"#.utf8))
        }
        await #expect(throws: RealtimeToolError.self) {
            _ = try await tool.call(Data(#"{"item_id":"\#(UUID().uuidString)","score":500}"#.utf8))
        }
        do {
            _ = try await tool.call(Data(#"{"item_id":"\#(UUID().uuidString)","score":0.5}"#.utf8))
            Issue.record("Recorded an unknown question")
        } catch let error as RealtimeToolError {
            guard case .failed(let message) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(message.contains("No question has that id"))
        }
        #expect(harness.backend.attempts.isEmpty)
    }

    @Test func aQuestionNumberAndAStringScoreAreUnderstood() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?", "B?"])
        _ = try await harness.next()
        let recorded = try await harness.call("record_practice_result", #"{"item_id":2,"score":"80%"}"#)
        let entry = try #require(recorded["recorded"] as? [String: Any])
        #expect(entry["prompt"] as? String == "B?")
        #expect(entry["score"] as? Double == 0.8)
    }

    @Test func aRetakeReplacesTheAnswerInTheRunAndReportsThePreviousScore() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["A?"])
        let id = try #require(try Self.question(try await harness.next())["id"] as? String)
        _ = try await harness.record(id, score: 0.4)
        let again = try await harness.record(id, score: 0.9, notes: "Much sharper.")
        let entry = try #require(again["recorded"] as? [String: Any])
        #expect(entry["previous_score"] as? Double == 0.4)
        #expect(entry["times_practiced"] as? Int == 2)
        #expect((again["run"] as? [String: Any])?["answered"] as? Int == 1)
        #expect(
            harness.recorder.summaries.last
                == "Practiced 1 of 1 questions in YC interview questions, average 90%.\n- A? 90%. Much sharper.")
    }

    // MARK: Listing

    @Test func listsCollectionsAndOneCollectionsQuestions() async throws {
        let harness = try Harness()
        harness.backend.add("YC interview questions", prompts: ["What are you building?", "Why now?"])
        harness.backend.add("Board prep", prompts: ["What's the burn?"], answers: false)
        let all = try await harness.call("list_collection", "{}")
        let collections = try #require(all["collections"] as? [[String: Any]])
        #expect(collections.map { $0["name"] as? String } == ["YC interview questions", "Board prep"])
        #expect(collections.first?["questions"] as? Int == 2)

        let yc = try await harness.call("list_collection", #"{"name":"yc"}"#)
        #expect((yc["collection"] as? [String: Any])?["name"] as? String == "YC interview questions")
        let questions = try #require(yc["questions"] as? [[String: Any]])
        #expect(questions.map { $0["prompt"] as? String } == ["What are you building?", "Why now?"])
        #expect(questions.map { $0["number"] as? Int } == [1, 2])
        #expect(questions.allSatisfy { $0["has_reference_answer"] as? Bool == true && $0["reference_answer"] == nil })
        let board = try await harness.call("list_collection", #"{"name":"board"}"#)
        #expect((board["questions"] as? [[String: Any]])?.first?["has_reference_answer"] == nil)
    }

    @Test func aLongCollectionStaysWithinTheBudget() async throws {
        let harness = try Harness()
        let prompts = (1...120).map {
            "Question \($0): " + String(repeating: "tell me more about the market ", count: 6)
        }
        harness.backend.add("Huge", prompts: prompts)
        let listed = try await harness.call("list_collection", #"{"name":"huge"}"#)
        let questions = try #require(listed["questions"] as? [[String: Any]])
        #expect(questions.count < 120)
        #expect(listed["omitted"] as? Int == 120 - questions.count)
        #expect(questions.first?["number"] as? Int == 1)
    }

    @Test func aLongReferenceAnswerIsClipped() async throws {
        let harness = try Harness()
        let collection = harness.backend.add("YC interview questions", prompts: ["A?"])
        var item = try #require(harness.backend.items(collection).first)
        item.referenceAnswer = String(repeating: "We help restaurants cut food waste. ", count: 200)
        harness.backend.setItems([item], in: collection)
        let answer = try #require(try Self.question(try await harness.next())["reference_answer"] as? String)
        #expect(answer.count <= 900)
        #expect(answer.hasSuffix("…"))
    }

    // MARK: Failures

    @Test func unknownAndEmptyCollectionsAreExplained() async throws {
        let harness = try Harness()
        let tool = try #require(harness.tools.tool(named: "next_practice_question"))
        await #expect(
            throws: RealtimeToolError.failed(
                "The user has no collections to practice yet. They can add one, for example by pasting a list of "
                    + "questions, in Settings, Knowledge, Collections.")
        ) {
            _ = try await tool.call(Data(#"{"collection":"YC"}"#.utf8))
        }
        harness.backend.add("YC interview questions", prompts: [])
        harness.backend.add("Sales objections", prompts: ["Too expensive?"])
        do {
            _ = try await tool.call(Data(#"{"collection":"pitch deck"}"#.utf8))
            Issue.record("Matched a collection that doesn't exist")
        } catch RealtimeToolError.failed(let message) {
            #expect(message.contains("\"YC interview questions\", \"Sales objections\""))
        }
        do {
            _ = try await tool.call(Data(#"{"collection":"YC"}"#.utf8))
            Issue.record("Practiced an empty collection")
        } catch RealtimeToolError.failed(let message) {
            #expect(message.contains("has no questions yet"))
        }
        #expect(harness.recorder.calls.isEmpty)
    }

    @Test func anUnavailableStoreIsReportedToGrok() async throws {
        let coordinator = PracticeCoordinator(backend: FakePracticeBackend(failure: .unavailable("Not open yet.")))
        let tool = ListCollectionTool(coordinator: coordinator)
        await #expect(throws: RealtimeToolError.failed("Not open yet.")) {
            _ = try await tool.call(Data("{}".utf8))
        }
    }

    // MARK: Instructions

    @Test func theInstructionsTeachPracticeModeWhenTheToolsArePresent() async throws {
        let harness = try Harness()
        let text = RealtimeInstructions.blau.render(
            tools: harness.tools.definitions, now: Self.now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.contains("\n# Practice\n"))
        #expect(text.contains("let's practice YC questions"))
        #expect(text.contains("call list_collection first"))
        #expect(text.contains("call end_practice"))
        #expect(text.contains("Don't read the reference answer aloud"))
        let without = RealtimeInstructions.blau.render(
            tools: [EchoTool.definition], now: Self.now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(!without.contains("# Practice"))
    }

    @Test func theAppsStartRequestNamesTheCollection() {
        #expect(
            PracticeTools.startRequest(collectionTitle: "YC interview questions")
                == "Let's practice my \"YC interview questions\" collection. Ask me the questions one at a time.")
    }
}
