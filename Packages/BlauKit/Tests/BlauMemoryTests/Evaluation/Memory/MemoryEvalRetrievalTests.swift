import Foundation
import Testing

@testable import BlauMemory

/// #70's regression gate for retrieval, on every `swift test`: the
/// committed memory eval set through the real index and `MemorySearch`,
/// with recorded Qwen3-Embedding-0.6B vectors, against the limits in
/// `docs/memory-eval/thresholds.json`. Hermetic and about two seconds; the
/// answer stage (an LLM reader and judge) runs nightly instead
/// (`MemoryEvalRunTests`, docs/memory-eval.md).
@Suite("Memory eval retrieval on the committed set", .serialized)
struct MemoryEvalRetrievalTests {
    @Test func retrievalMeetsTheCommittedThresholds() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        var report = try await MemoryEvaluator(dataset: dataset).run(
            embeddings: MemoryEvalFixtures.vectors(), answersSkipped: "retrieval only (swift test)")
        let thresholds = try MemoryEvalThresholds.load(MemoryEvalFixtures.thresholdsURL)
        report.gate = thresholds.evaluate(report)
        print(report.table())
        if let baseline = try? MemoryEvalReport.decode(Data(contentsOf: MemoryEvalFixtures.baselineURL)) {
            print("Against the baseline:\n" + report.comparisonTable(with: baseline, markdown: false))
        }
        #expect(report.gate?.passed == true, "\(report.gate?.summary() ?? "")")
    }

    @Test func theThresholdsAcceptTheBaselineAndCoverEverySystem() throws {
        let thresholds = try MemoryEvalThresholds.load(MemoryEvalFixtures.thresholdsURL)
        let baseline = try MemoryEvalReport.decode(Data(contentsOf: MemoryEvalFixtures.baselineURL))
        let gate = thresholds.evaluate(baseline, requireAnswers: true)
        #expect(gate.passed, "\(gate.summary())")
        #expect(Set(thresholds.retrieval.keys) == Set(MemoryEvalSystem.allCases.map(\.rawValue)))
        let hybrid = try #require(thresholds.retrieval[MemoryEvalSystem.hybrid.rawValue])
        let answerable = MemoryEvalDataset.QuestionType.allCases.filter { $0 != .abstention }.map(\.rawValue)
        #expect(Set(hybrid.byType?.keys.map { $0 } ?? []) == Set(answerable))
        let answers = try #require(baseline.answers.flatMap { thresholds.answers?[$0.key] })
        #expect(
            Set(answers.byType?.keys.map { $0 } ?? []) == Set(MemoryEvalDataset.QuestionType.allCases.map(\.rawValue)))
    }

    /// The committed baseline was made from the committed set.
    @Test func theBaselineMatchesTheDataset() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        let baseline = try MemoryEvalReport.decode(Data(contentsOf: MemoryEvalFixtures.baselineURL))
        #expect(baseline.dataset.name == dataset.name)
        #expect(baseline.questions.map(\.id) == dataset.questions.map(\.id))
        let index = try await MemoryEvaluator(dataset: dataset).buildIndex(embedder: nil)
        #expect(try await baseline.dataset.chunks == index.statistics().chunks)
        #expect(baseline.embeddingModel == MemoryEvalFixtures.vectorsModelVersion)
    }

    /// The recording holds exactly the current key texts and questions.
    @Test func theRecordedVectorsMatchTheDataset() async throws {
        let dataset = try MemoryEvalFixtures.dataset()
        let vectors = try MemoryEvalFixtures.vectors()
        let texts = try await MemoryEvaluator(dataset: dataset).embeddingTexts()
        #expect(vectors.modelVersion == MemoryEvalFixtures.vectorsModelVersion)
        #expect(vectors.dimensions == 256)
        #expect(vectors.documentCount == texts.documents.count)
        #expect(vectors.queryCount == Set(texts.queries).count)
        _ = try await vectors.embedDocuments(texts.documents)
        for query in texts.queries { _ = try await vectors.embedQuery(query) }
    }
}
