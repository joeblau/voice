import Foundation
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Memory evaluator")
struct MemoryEvaluatorTests {
    /// Answers from the context: the first memory's text.
    struct EchoReader: MemoryEvalReader {
        var identifier: String { "echo" }

        func answer(_ question: String, memories: [MemorySearchResult], now: Date) async throws -> String {
            if question.contains("cat") { return "I don't know." }
            if question.contains("tomatoes") { throw Broken() }
            return memories.first?.chunk.text ?? ""
        }
    }

    struct Broken: Error {}

    /// Accepts an answer that shares a word with the reference; can't
    /// decide on the gift question.
    struct OverlapJudge: MemoryEvalJudge {
        var identifier: String { "overlap" }

        func judge(_ question: MemoryEvalDataset.Question, response: String) async throws -> MemoryEvalVerdict {
            if question.id == "q-sf" { return MemoryEvalVerdict(correct: nil, reply: "maybe") }
            if question.type == .abstention {
                return MemoryEvalVerdict(correct: response.contains("don't know"), reply: "")
            }
            let words = Set(question.answer.lowercased().split { !$0.isLetter && !$0.isNumber })
            let overlap = response.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { words.contains($0) }
            return MemoryEvalVerdict(correct: overlap, reply: overlap ? "yes" : "no")
        }
    }

    @Test func retrievalOnlyRun() async throws {
        let dataset = try MemoryEvalDataset.small()
        let report = try await MemoryEvaluator(dataset: dataset).run(embeddings: HashingEvalEmbeddings(), commit: "abc")
        #expect(report.systems.map(\.id) == ["hybrid", "hybrid-no-entities", "bm25-fallback", "dense"])
        #expect(report.primarySystem == "hybrid")
        #expect(report.embeddingModel == "hashing-256d-int8@1")
        #expect(report.commit == "abc")
        #expect(report.answers == nil)
        #expect(report.answersSkipped == "no reader and judge")
        #expect(report.dataset.questions == 5)
        #expect(
            report.dataset.questionsByType == [
                "single-fact": 1, "temporal": 1, "knowledge-update": 1, "multi-hop": 1, "abstention": 1,
            ])
        // Abstention has no evidence, so four questions are scored.
        let hybrid = try #require(report.system("hybrid"))
        #expect(hybrid.overall.count == 4)
        #expect(hybrid.byType["abstention"] == nil)
        #expect(hybrid.overall.updateCount == 1)
        // The gift note and the update are found at the top.
        let gift = try #require(report.questions.first { $0.id == "q-sf" })
        #expect(gift.ranking.first == "d1")
        #expect(gift.firstEvidenceRank == 1)
        let weight = try #require(report.questions.first { $0.id == "q-ku" })
        #expect(weight.ranking.contains("f2"))
        // "yesterday" resolves against the dataset's now.
        let yesterday = try #require(report.questions.first { $0.id == "q-tr" })
        #expect(yesterday.timeExpression?.hasPrefix("relative") == true)
        #expect(yesterday.ranking.first == "t3")
        let abstention = try #require(report.questions.first { $0.id == "q-ab" })
        #expect(abstention.retrieval == nil)
    }

    @Test func withoutVectorsOnlyTheKeywordSystemRuns() async throws {
        let report = try await MemoryEvaluator(dataset: MemoryEvalDataset.small()).run(embeddings: nil)
        #expect(report.systems.map(\.id) == ["bm25-fallback"])
        #expect(report.primarySystem == "bm25-fallback")
        #expect(report.embeddingModel == nil)

        var configuration = MemoryEvaluator.Configuration()
        configuration.systems = [.dense]
        await #expect(throws: MemoryEvaluator.Failure.noSystems) {
            try await MemoryEvaluator(dataset: MemoryEvalDataset.small(), configuration: configuration)
                .run(embeddings: nil)
        }
    }

    @Test func missingVectorsFailLoudly() async throws {
        let dataset = try MemoryEvalDataset.small()
        let empty = try MemoryEvalRecordedEmbeddings(
            .init(model: "m", modelVersion: "m@1", dimensions: 4, documents: [:], queries: [:]))
        await #expect(throws: MemoryEvaluator.Failure.self) {
            try await MemoryEvaluator(dataset: dataset).run(embeddings: empty)
        }
    }

    @Test func answersAreReadJudgedAndCounted() async throws {
        let dataset = try MemoryEvalDataset.small()
        var configuration = MemoryEvaluator.Configuration()
        configuration.contextSize = 3
        let lines = Mutex<[String]>([])
        let report = try await MemoryEvaluator(dataset: dataset, configuration: configuration).run(
            embeddings: HashingEvalEmbeddings(), reader: EchoReader(), judge: OverlapJudge(),
            progress: { line in lines.withLock { $0.append(line) } })
        let answers = try #require(report.answers)
        #expect(answers.reader == "echo")
        #expect(answers.judge == "overlap")
        #expect(answers.key == "echo judged by overlap")
        #expect(answers.contextSize == 3)
        #expect(answers.system == "hybrid")
        #expect(answers.overall.count == 5)
        // The gift (unparsable verdict) and tomatoes (reader threw) failed.
        #expect(answers.overall.failures == 2)
        #expect(answers.byType["abstention"]?.correct == 1)
        #expect(answers.byType["temporal"]?.failures == 1)
        let tomatoes = try #require(report.questions.first { $0.id == "q-tr" })
        #expect(tomatoes.error?.contains("Broken") == true)
        #expect(tomatoes.response == nil)
        let gift = try #require(report.questions.first { $0.id == "q-sf" })
        #expect(gift.error == "unparsable verdict")
        #expect(gift.response?.contains("ceramics") == true)
        #expect(report.answersSkipped == nil)
        #expect(lines.withLock { $0.contains { $0.hasPrefix("answered 5 of 5") } })
    }

    @Test func rankingsCountEachRecordOnce() throws {
        let dataset = try MemoryEvalDataset.small()
        let evaluator = MemoryEvaluator(dataset: dataset)
        let document = MemoryEvalCorpus.uuid("document", "d1")
        let chunks = (0..<3).map { ordinal in
            MemoryChunk(
                sourceID: document, sourceKind: .document, ordinal: ordinal, text: "\(ordinal)", keyText: "\(ordinal)",
                createdAt: dataset.now)
        }
        let stranger = MemoryChunk(
            sourceID: UUID(), sourceKind: .fact, ordinal: 0, text: "?", keyText: "?", createdAt: dataset.now)
        #expect(evaluator.ranking(chunks + [stranger]) == ["d1", "chunk:\(stranger.id.uuidString)"])
    }

    // MARK: - Report and gate

    @Test func reportRoundTripsAndRenders() async throws {
        let dataset = try MemoryEvalDataset.small()
        var report = try await MemoryEvaluator(dataset: dataset).run(
            embeddings: HashingEvalEmbeddings(), reader: EchoReader(), judge: OverlapJudge())
        report.gate = MemoryEvalThresholds(retrieval: ["hybrid": .init(overall: [.recallAt5: 0])]).evaluate(report)
        let decoded = try MemoryEvalReport.decode(report.jsonData())
        #expect(decoded == report)

        let table = report.table()
        #expect(table.contains("hybrid-no-entities"))
        #expect(table.contains("knowledge-update"))
        #expect(table.contains("Answers: reader echo, judge overlap"))
        #expect(table.contains("Regression gate: passed"))
        let markdown = report.markdown()
        #expect(markdown.hasPrefix("# Memory evaluation"))
        #expect(markdown.contains("| `hybrid` |"))
        #expect(markdown.contains("## Answers"))
        #expect(markdown.contains("`q-tr`"))

        let comparison = report.comparisonTable(with: report, markdown: true)
        #expect(comparison.contains("| hybrid Recall@5 |"))
        #expect(comparison.contains("+0.000"))
        #expect(comparison.contains("answer accuracy (echo judged by overlap)"))
    }

    @Test func theGateChecksSystemsTypesAndAnswers() async throws {
        let dataset = try MemoryEvalDataset.small()
        let report = try await MemoryEvaluator(dataset: dataset).run(
            embeddings: HashingEvalEmbeddings(), reader: EchoReader(), judge: OverlapJudge())
        let hybrid = try #require(report.system("hybrid"))
        let accuracy = try #require(report.answers?.overall.accuracy)

        let passing = MemoryEvalThresholds(
            retrieval: [
                "hybrid": .init(
                    overall: [.recallAt5: hybrid.overall.recallAt5], byType: ["single-fact": [.hitAt5: 1]])
            ],
            answers: ["echo judged by overlap": .init(minAccuracy: accuracy, maxFailures: 2)])
        let passed = passing.evaluate(report)
        #expect(passed.passed, "\(passed.summary())")
        #expect(passed.checks.count == 4)

        let failing = MemoryEvalThresholds(
            retrieval: ["hybrid": .init(overall: [.recallAt5: 1.01]), "missing": .init()],
            answers: ["echo judged by overlap": .init(byType: ["abstention": 1.01], maxFailures: 1)])
        let failed = failing.evaluate(report)
        #expect(!failed.passed)
        #expect(
            failed.failures.map(\.scope).sorted() == [
                "answers (echo judged by overlap)", "answers (echo judged by overlap) abstention", "hybrid", "missing",
            ])
        let summary = failed.summary()
        #expect(summary.contains("Regression gate: FAILED (4 of 4 checks)"))
        #expect(summary.contains("missing: ran not measured"))
        #expect(summary.contains("failures 2.000 > 1.000"))
    }

    @Test func partialRunsSkipOverallLimits() async throws {
        let dataset = try MemoryEvalDataset.small().limited(toTypes: [.temporal])
        let report = try await MemoryEvaluator(dataset: dataset).run(embeddings: HashingEvalEmbeddings())
        let thresholds = MemoryEvalThresholds(
            retrieval: [
                "hybrid": .init(
                    overall: [.recallAt5: 1.01], byType: ["temporal": [.recallAt5: 0], "multi-hop": [.recallAt5: 1]])
            ])
        let gate = thresholds.evaluate(report, partial: true)
        #expect(gate.passed, "\(gate.summary())")
        #expect(gate.checks.map(\.scope) == ["hybrid temporal"])
        #expect(gate.notes.contains("hybrid: overall limits skipped (partial run)"))
        #expect(!thresholds.evaluate(report, partial: false).passed)
    }

    @Test func answersCanBeRequired() async throws {
        let report = try await MemoryEvaluator(dataset: MemoryEvalDataset.small()).run(
            embeddings: HashingEvalEmbeddings(), answersSkipped: "no model")
        let thresholds = MemoryEvalThresholds(retrieval: [:], answers: ["echo": .init(minAccuracy: 0.5)])
        let optional = thresholds.evaluate(report)
        #expect(optional.passed)
        #expect(optional.notes == ["answers not evaluated (no model); answer limits not checked"])
        #expect(!thresholds.evaluate(report, requireAnswers: true).passed)
    }
}
