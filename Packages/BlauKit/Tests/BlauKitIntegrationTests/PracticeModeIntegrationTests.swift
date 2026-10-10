import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import Foundation
import SwiftData
import Synchronization
import Testing

/// Practice mode (#69) wired as the app's composition root wires it: the
/// practice tools (BlauRealtime) over the synced collections
/// (BlauPersistence's `PracticeStore`), each run recorded as a topic by the
/// topic lifecycle (BlauTopics), run by the turn orchestrator inside a
/// realtime session with a scripted Grok that interviews the user.
@Suite("Practice mode: integration")
struct PracticeModeIntegrationTests {
    static let prompts = [
        "What are you building?", "Who are your users?", "Why now?", "Who are your competitors?",
        "How do you make money?", "What's your traction?", "Why is this team the one to do it?",
        "What's the hardest part?", "How big can this get?", "What do you need from YC?", "What's your burn?",
        "What would you do with the money?",
    ]

    /// The orchestrator's transcript with the topic lifecycle listening, as
    /// the app's `TopicTrackingTranscript` does it.
    struct TopicTrackingTranscript: TurnTranscriptRecording {
        let base: ConversationStore
        let topics: TopicLifecycle

        func beginConversation(_ id: ConversationID, at date: Date) async throws {
            try await base.beginConversation(id, at: date)
            await topics.beginConversation(id, at: date)
        }

        func record(_ utterance: Utterance) async throws {
            try await base.record(utterance)
            await topics.ingest(utterance)
        }

        func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws {
            try await base.markInterrupted(utteranceID, reason: reason)
        }

        func finishConversation(_ id: ConversationID, at date: Date) async throws {
            try await base.finishConversation(id, at: date)
            await topics.finishConversation(id)
        }

        func flush() async throws {
            try await base.flush()
        }
    }

    /// Grok as the interviewer: what the realtime model does when it follows
    /// the Practice instructions. It asks each question the tools return,
    /// gives feedback and records a score, and wraps up when told to stop.
    final class ScriptedInterviewer: Sendable {
        private struct State {
            var questionID: String?
            var answers = 0
        }

        private let state = Mutex(State())

        func reply(to request: ScriptedRealtimeServer.ReplyRequest) -> ScriptedRealtimeServer.Reply {
            if request.isFollowUp {
                for output in request.functionOutputs {
                    guard
                        let object = try? JSONSerialization.jsonObject(with: Data(output.output.utf8))
                            as? [String: Any]
                    else { continue }
                    if let question = object["question"] as? [String: Any] {
                        state.withLock { $0.questionID = question["id"] as? String }
                        let number = question["number"] as? Int ?? 0
                        return .init(text: "Question \(number). \(question["prompt"] as? String ?? "")")
                    }
                    if let ended = object["ended"] as? [String: Any] {
                        state.withLock { $0.questionID = nil }
                        return .init(
                            text: "That's the run: \(ended["answered"] as? Int ?? 0) answered. Work on the first two.")
                    }
                }
                return .init(text: "Noted.")
            }
            let text = request.userText.lowercased()
            if text.contains("let's practice") {
                return .init(
                    text: "Sure, I'll be the partner.",
                    functionCalls: [.init(name: "next_practice_question", arguments: #"{"collection":"YC questions"}"#)]
                )
            }
            if text.contains("stop") {
                return .init(text: "Let's wrap up.", functionCalls: [.init(name: "end_practice", arguments: "{}")])
            }
            let (id, answers) = state.withLock { state -> (String?, Int) in
                state.answers += 1
                return (state.questionID, state.answers)
            }
            guard let id else { return .init(text: "Sorry, which question was that?") }
            let score = Double(answers % 5 + 5) / 10
            return .init(
                text: "Good. Lead with the customer next time.",
                functionCalls: [
                    .init(
                        name: "record_practice_result",
                        arguments: #"{"item_id":"\#(id)","score":\#(score),"notes":"Lead with the customer."}"#),
                    .init(name: "next_practice_question", arguments: #"{"collection":"YC questions"}"#),
                ])
        }
    }

    /// Polls `condition` until it holds, failing after `timeout` worth of
    /// polls. The limit counts polls, not wall time, so a loaded runner that
    /// keeps the whole process off the CPU can't run it out (#180).
    static func waitUntil(
        _ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool
    ) async throws {
        let interval = Duration.milliseconds(2)
        var polls = Int(timeout / interval)
        while !(await condition()) {
            guard polls > 0 else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            polls -= 1
            try await Task.sleep(for: interval)
        }
    }

    /// Acceptance criterion: a full practice run of ten questions by voice.
    /// Twelve spoken user turns (the request, ten answers, "let's stop") and
    /// one more afterwards go through the real client, orchestrator, tool
    /// runner, practice tools, SwiftData store and topic lifecycle; the
    /// scripted Grok only does what the instructions ask of the model.
    @Test func aFullPracticeRunOfTenQuestionsByVoice() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let knowledge = KnowledgeBaseStore(modelContainer: container)
        let collectionID = UUID()
        _ = try await knowledge.saveDocument(
            collectionID, kind: .collection, title: "YC interview questions", body: "")
        _ = try await knowledge.addItems(
            Self.prompts.enumerated().map { .init(prompt: $1, referenceAnswer: "Reference \($0 + 1)") },
            to: collectionID)

        // One clock for the conversation, so what the user says and what
        // Grok answers are timestamped in the order they happen.
        let clock = ManualClock(now: Date(timeIntervalSinceReferenceDate: 813_000_000))
        let store = ConversationStore(modelContainer: container, savePolicy: .immediate)
        let topics = TopicLifecycle(
            store: store, labeling: TopicLabelingService(labelers: []),
            configuration: .init(exchangeSettleDelay: nil)
        ) {
            StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics))
        }
        let coordinator = PracticeCoordinator(
            backend: PracticeStore(modelContainer: container), runs: topics,
            settings: PracticeToolSettings(clock: clock))
        let tools = try RealtimeToolRegistry(PracticeTools.all(coordinator: coordinator))
        let interviewer = ScriptedInterviewer()
        let server = ScriptedRealtimeServer { interviewer.reply(to: $0) }
        let client = RealtimeClient(
            endpoint: URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")!,
            tokenProvider: ScriptedRealtimeServer.TokenProvider(), connector: server, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil), signposter: .disabled(.realtime))
        let orchestrator = TurnOrchestrator(
            client: client,
            configurator: RealtimeSessionConfigurator(
                settings: RealtimeVoiceSettingsStore(), tools: tools.definitions, clock: clock),
            audio: DiscardingAgentAudioOutput(), transcript: TopicTrackingTranscript(base: store, topics: topics),
            tools: tools, clock: clock, signposter: .disabled(.realtime))

        let conversation = try await orchestrator.start()
        // The conversation is open in the transcript and the topic lifecycle
        // before the user says anything, as in the app.
        await orchestrator.waitUntilSettled()
        await topics.waitUntilIdle()
        var turn = 0
        func say(_ text: String) async throws {
            turn += 1
            let expected = turn
            // A pause, then two seconds of speech.
            clock.advance(by: .seconds(5))
            let startedAt = clock.now
            clock.advance(by: .seconds(2))
            try await orchestrator.send(
                Utterance(
                    conversationID: conversation, speaker: .user, text: text,
                    // Seconds apart on the audio timeline, so no answer
                    // continues the previous one.
                    timeRange: TimeRange(start: .seconds(Double(expected) * 30), duration: .seconds(2)),
                    startedAt: startedAt, speakerDecision: .accept))
            try await Self.waitUntil("turn \(expected)") {
                let snapshot = await orchestrator.snapshot
                return snapshot.completedTurns == expected && snapshot.state == .listening
            }
            await orchestrator.waitUntilSettled()
            await topics.waitUntilIdle()
        }

        try await say("Let's practice my YC questions.")
        for answer in 1...10 {
            try await say("Answer \(answer): we help independent restaurants cut food waste with inventory software.")
        }
        try await say("That's enough, let's stop.")
        try await say("Thanks. What should I cook tonight?")
        await orchestrator.stop()
        await topics.waitUntilIdle()

        // Every question was asked once, in order (none practiced before),
        // and spoken by Grok.
        let rows = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
            .orderedUtterances
        let asked = rows.filter { $0.role == .agent && $0.text.hasPrefix("Question ") }.map(\.text)
        #expect(asked.count == 11)
        #expect(asked.first == "Question 1. What are you building?")
        #expect(asked[9] == "Question 10. What do you need from YC?")
        #expect(Set(asked).count == asked.count)

        // Ten attempts in the synced practice record, the eleventh question
        // asked but not answered, the twelfth never asked.
        let items = try ModelContext(container).fetch(
            FetchDescriptor<CollectionItem>(sortBy: [SortDescriptor(\.ordinal)]))
        #expect(items.prefix(10).allSatisfy { $0.practiceCount == 1 && $0.score != nil && $0.lastPracticedAt != nil })
        #expect(items.suffix(2).allSatisfy { $0.practiceCount == 0 && $0.score == nil })

        // The run is a topic of its own with the run's record as summary; the
        // conversation after it is another topic.
        let stored = try await store.topicSnapshots(in: conversation)
        #expect(stored.count == 2)
        let practice = try #require(stored.first)
        #expect(practice.title == "Practice: YC interview questions")
        #expect(!practice.titleIsProvisional)
        let summary = try #require(practice.summary)
        #expect(summary.hasPrefix("Practiced 10 of 12 questions in YC interview questions, average "))
        #expect(summary.split(separator: "\n").count == 11)
        #expect(summary.contains("- What are you building? "))
        #expect(summary.contains("Lead with the customer."))
        let practiceRows = try await store.topicUtterances(practice.id)
        #expect(practiceRows.first?.text == "Let's practice my YC questions.")
        #expect(practiceRows.last?.text == "That's the run: 10 answered. Work on the first two.")
        let after = try await store.topicUtterances(stored[1].id)
        #expect(after.first?.text == "Thanks. What should I cook tonight?")

        let calls = await orchestrator.snapshot.toolCalls
        #expect(calls.allSatisfy { $0.outcome == .succeeded })
        await orchestrator.shutdown()
    }
}
