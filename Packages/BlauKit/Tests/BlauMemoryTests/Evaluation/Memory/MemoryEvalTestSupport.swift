import BlauPersistence
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

/// The committed memory eval set and its recorded vectors.
enum MemoryEvalFixtures {
    /// The recorded vectors' file name (Qwen3-Embedding-0.6B, 256-d int8,
    /// the reference #64 tuned on; docs/memory-eval.md).
    static let vectorsName = "qwen3-embedding-0.6b-256d-int8"
    static let vectorsModelVersion = "qwen3-embedding-0.6b-256d-int8@97b0c614"

    static func datasetURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/MemoryEval", withExtension: nil))
    }

    static func vectorsURL() throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Fixtures/MemoryEvalVectors/\(vectorsName)", withExtension: "json"))
    }

    static func dataset() throws -> MemoryEvalDataset {
        try MemoryEvalDataset.load(directory: datasetURL())
    }

    static func vectors() throws -> MemoryEvalRecordedEmbeddings {
        try MemoryEvalRecordedEmbeddings.load(vectorsURL())
    }

    /// The repository root, for the committed thresholds and baseline.
    static var repositoryRoot: URL {
        // Tests/BlauMemoryTests/Evaluation/Memory/<file> → the repo root.
        var url = URL(filePath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return url
    }

    static var thresholdsURL: URL { repositoryRoot.appending(path: "docs/memory-eval/thresholds.json") }
    static var baselineURL: URL { repositoryRoot.appending(path: "docs/memory-eval/baseline.json") }
}

/// A language model that answers from a script, recording every call.
final class ScriptedLanguageModel: MemoryEvalLanguageModel {
    let identifier: String
    let calls = Mutex<[(instructions: String, prompt: String)]>([])
    private let reply: @Sendable (String, String) throws -> String

    init(identifier: String = "scripted", reply: @escaping @Sendable (String, String) throws -> String) {
        self.identifier = identifier
        self.reply = reply
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        calls.withLock { $0.append((instructions, prompt)) }
        return try reply(instructions, prompt)
    }
}

/// Embeds chunks and queries with `IndexTestSupport.HashingEmbedder`'s
/// lexical vectors: texts sharing words are similar.
struct HashingEvalEmbeddings: MemoryChunkEmbedding, MemoryQueryEmbedding {
    let embedder = IndexTestSupport.HashingEmbedder()

    func currentModelVersion() async throws -> String { embedder.version }

    func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] { texts.map(embedder.embed) }

    func embedQuery(_ text: String) async throws -> TextEmbedding { embedder.embed(text) }
}

extension MemoryEvalDataset {
    /// A small dataset: one conversation with an update, a document, an
    /// entity with facts, and one question of each type.
    /// `now` is the day after the second session.
    static func small(now: Date = IndexTestSupport.t0.addingTimeInterval(21 * 86_400)) throws -> MemoryEvalDataset {
        let day: TimeInterval = 86_400
        let t0 = IndexTestSupport.t0
        let manifest = Manifest(
            name: "small", version: 1, description: nil, consent: "Synthetic test data.", userName: "Jo", now: now,
            timeZone: "UTC", firstWeekday: 2)
        return try MemoryEvalDataset(
            manifest: manifest,
            entities: [Entity(id: "rex", name: "Rex", type: "other")],
            sessions: [
                Session(
                    id: "s1", startedAt: t0, topic: "Garden",
                    turns: [
                        Turn(
                            id: "t1", user: "The tomatoes on the balcony have yellow leaves.",
                            assistant: "Water them deeply."),
                        Turn(id: "t2", user: "My dog Rex is scared of thunder.", assistant: "Give him a quiet den."),
                    ]),
                Session(
                    id: "s2", startedAt: t0.addingTimeInterval(20 * day), topic: "Garden",
                    turns: [Turn(id: "t3", user: "The tomatoes recovered after the compost.", assistant: "Great news.")]
                ),
            ],
            documents: [
                Document(
                    id: "d1", kind: .note, title: "Gift ideas", body: "A ceramics course for Sam.",
                    updatedAt: t0.addingTimeInterval(day))
            ],
            facts: [
                Fact(
                    id: "f1", subject: "rex", predicate: "weighs", object: "30 pounds", validFrom: t0,
                    invalidatedAt: t0.addingTimeInterval(10 * day)),
                Fact(
                    id: "f2", subject: "rex", predicate: "weighs", object: "33 pounds",
                    validFrom: t0.addingTimeInterval(10 * day), source: "t2"),
            ],
            questions: [
                Question(
                    id: "q-sf", type: .singleFact, question: "What gift idea did I note for Sam?",
                    answer: "A ceramics course.", evidence: [Evidence(["d1"])]),
                Question(
                    id: "q-tr", type: .temporal, question: "What did I say about the tomatoes yesterday?",
                    answer: "They recovered after the compost.", evidence: [Evidence(["t3"])]),
                Question(
                    id: "q-ku", type: .knowledgeUpdate, question: "How much does Rex weigh?",
                    answer: "33 pounds.", evidence: [Evidence(["f2"])], stale: ["f1"]),
                Question(
                    id: "q-mh", type: .multiHop, question: "What is my dog scared of and what does he weigh?",
                    answer: "Thunder; 33 pounds.", evidence: [Evidence(["t2"]), Evidence(["f2"])]),
                Question(
                    id: "q-ab", type: .abstention, question: "What's my cat's name?",
                    answer: "No cat was mentioned."),
            ])
    }
}
