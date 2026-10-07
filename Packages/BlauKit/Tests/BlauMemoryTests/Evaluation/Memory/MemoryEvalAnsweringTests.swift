import Foundation
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Memory eval answering")
struct MemoryEvalAnsweringTests {
    let utc = TimeZone(identifier: "UTC")!
    /// Wednesday, October 7, 2026, 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_374_400)

    func result(_ kind: MemorySourceKind, text: String, keyText: String? = nil, date: Date) -> MemorySearchResult {
        let chunk = MemoryChunk(
            sourceID: UUID(), sourceKind: kind, ordinal: 0, text: text, keyText: keyText ?? text, createdAt: date)
        return MemorySearchResult(chunk: chunk, snippet: text, score: 1, signals: [.keyword])
    }

    // MARK: - Reader

    @Test func theReaderSeesDatedMemoriesAndToday() async throws {
        let model = ScriptedLanguageModel { _, _ in "  Thursdays at 6 pm.\n" }
        let reader = LLMMemoryEvalReader(model: model, userName: "Jordan", timeZone: utc)
        let memories = [
            result(.conversation, text: "User: Lessons move to Thursdays.", date: now.addingTimeInterval(-7 * 86_400)),
            result(
                .fact, text: "Lucía tutors the user on Tuesdays",
                keyText: "[July 28, 2026] Lucía tutors the user on Tuesdays (until September 30, 2026)",
                date: now.addingTimeInterval(-70 * 86_400)),
        ]
        let answer = try await reader.answer("When is my lesson?", memories: memories, now: now)
        #expect(answer == "Thursdays at 6 pm.")
        let call = try #require(model.calls.withLock { $0.first })
        #expect(call.instructions.contains("conversations with Jordan"))
        #expect(call.instructions.contains("say that you don't know"))
        #expect(
            call.prompt == """
                Today is Wednesday, October 7, 2026.

                Memories:
                [1] Wednesday, September 30, 2026 · conversation
                User: Lessons move to Thursdays.
                [2] Wednesday, July 29, 2026 · fact · no longer true since September 30, 2026
                Lucía tutors the user on Tuesdays

                Question: When is my lesson?
                """)
    }

    @Test func noMemoriesSaySo() {
        let reader = LLMMemoryEvalReader(model: ScriptedLanguageModel { _, _ in "" }, userName: "Jo", timeZone: utc)
        #expect(reader.prompt(for: "Q?", memories: [], now: now).contains("Memories:\n(none)"))
    }

    @Test func onlyInvalidatedFactsCarryAnEndDate() {
        let date = now
        let current = MemoryChunk(
            sourceID: UUID(), sourceKind: .fact, ordinal: 0, text: "A", keyText: "[May 1, 2026] A", createdAt: date)
        let conversation = MemoryChunk(
            sourceID: UUID(), sourceKind: .conversation, ordinal: 0, text: "B (until later)",
            keyText: "B (until later)", createdAt: date)
        #expect(LLMMemoryEvalReader.invalidation(of: current) == nil)
        #expect(LLMMemoryEvalReader.invalidation(of: conversation) == nil)
    }

    // MARK: - Judge

    @Test func theJudgePromptFollowsTheQuestionType() throws {
        func question(_ type: MemoryEvalDataset.QuestionType) -> MemoryEvalDataset.Question {
            .init(
                id: "q", type: type, question: "Q?", answer: "A.", evidence: type == .abstention ? [] : [.init(["e"])])
        }
        let plain = LLMMemoryEvalJudge.prompt(for: question(.singleFact), response: "R")
        #expect(plain.contains("Correct Answer: A."))
        #expect(plain.contains("Model Response: R"))
        #expect(plain.hasSuffix("Is the model response correct? Answer yes or no only."))
        #expect(LLMMemoryEvalJudge.prompt(for: question(.temporal), response: "R").contains("off-by-one"))
        #expect(LLMMemoryEvalJudge.prompt(for: question(.knowledgeUpdate), response: "R").contains("updated answer"))
        #expect(LLMMemoryEvalJudge.prompt(for: question(.multiHop), response: "R") == plain)
        let abstention = LLMMemoryEvalJudge.prompt(for: question(.abstention), response: "R")
        #expect(abstention.contains("Explanation: A."))
        #expect(abstention.contains("correctly identifies the question as unanswerable"))
    }

    @Test(
        arguments: [
            ("yes", true), ("Yes.", true), ("**Yes**", true), ("yes, it matches", true), ("Correct", true),
            ("No", false), ("no.", false), ("Incorrect.", false), ("I think so", nil), ("", nil),
        ] as [(String, Bool?)])
    func verdicts(_ reply: String, _ expected: Bool?) {
        #expect(MemoryEvalVerdict.parse(reply).correct == expected)
    }

    @Test func theJudgeAsksTheModel() async throws {
        let model = ScriptedLanguageModel { _, _ in "Yes" }
        let verdict = try await LLMMemoryEvalJudge(model: model).judge(
            .init(id: "q", type: .singleFact, question: "Q?", answer: "A.", evidence: [.init(["e"])]), response: "A")
        #expect(verdict == MemoryEvalVerdict(correct: true, reply: "Yes"))
        #expect(model.calls.withLock { $0.first?.instructions } == LLMMemoryEvalJudge.instructions)
    }

    // MARK: - Chat completions

    final class Recorder: Sendable {
        let requests = Mutex<[URLRequest]>([])
        let replies: Mutex<[(Int, String)]>

        init(_ replies: [(Int, String)]) {
            self.replies = Mutex(replies)
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.withLock { $0.append(request) }
            let (status, body) = replies.withLock { $0.removeFirst() }
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    @Test func chatCompletionsRequestAndReply() async throws {
        let recorder = Recorder([(200, #"{"choices": [{"message": {"role": "assistant", "content": "Lisbon."}}]}"#)])
        let model = ChatCompletionsEvalLanguageModel(
            model: "grok-test", apiKey: "test-key", transport: { try await recorder.send($0) })
        #expect(model.identifier == "grok-test")
        let reply = try await model.respond(instructions: "Be brief.", prompt: "Where?")
        #expect(reply == "Lisbon.")
        let request = try #require(recorder.requests.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "grok-test")
        #expect(json["temperature"] as? Double == 0)
        #expect(json["max_tokens"] as? Int == 300)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Be brief."], ["role": "user", "content": "Where?"]])
    }

    @Test func chatCompletionsRetriesRateLimitsThenFails() async throws {
        let recorder = Recorder([
            (429, "slow down"), (200, #"{"choices": [{"message": {"content": "ok"}}]}"#),
        ])
        let model = ChatCompletionsEvalLanguageModel(
            model: "m", apiKey: "k", attempts: 2, retryDelay: .zero, transport: { try await recorder.send($0) })
        #expect(try await model.respond(instructions: "", prompt: "") == "ok")
        #expect(recorder.requests.withLock { $0.count } == 2)

        let failing = Recorder([(401, #"{"error": "bad key"}"#)])
        let unauthorized = ChatCompletionsEvalLanguageModel(
            model: "m", apiKey: "k", transport: { try await failing.send($0) })
        await #expect(throws: ChatCompletionsEvalLanguageModel.Failure.self) {
            try await unauthorized.respond(instructions: "", prompt: "")
        }
        #expect(failing.requests.withLock { $0.count } == 1)

        let empty = Recorder([(200, #"{"choices": []}"#)])
        let noChoices = ChatCompletionsEvalLanguageModel(
            model: "m", apiKey: "k", transport: { try await empty.send($0) })
        await #expect(throws: ChatCompletionsEvalLanguageModel.Failure.invalidResponse("no choices")) {
            try await noChoices.respond(instructions: "", prompt: "")
        }
    }
}
