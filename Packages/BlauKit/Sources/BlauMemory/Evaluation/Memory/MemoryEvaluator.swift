import BlauCore
import BlauTelemetry
import Foundation

/// A retrieval system the memory evaluation measures.
public enum MemoryEvalSystem: String, Codable, CaseIterable, Hashable, Sendable {
    /// `MemorySearch` as the app runs it: BM25 + vectors, weighted RRF, the
    /// time boost and entity expansion. The primary system.
    case hybrid
    /// `MemorySearch` without the entity graph: what expansion adds.
    case hybridWithoutEntities = "hybrid-no-entities"
    /// `MemorySearch` without an embedding model (before it is downloaded):
    /// BM25, the time boost and expansion.
    case keywordFallback = "bm25-fallback"
    /// The vector ranking alone (`MemoryIndex.vectorSearch`).
    case dense

    public var summary: String {
        switch self {
        case .hybrid: "MemorySearch defaults: BM25 + vectors (weighted RRF), time boost, entity expansion"
        case .hybridWithoutEntities: "MemorySearch without the entity graph"
        case .keywordFallback: "MemorySearch without an embedding model"
        case .dense: "Vector search alone (int8 cosine)"
        }
    }

    public var needsVectors: Bool { self != .keywordFallback }
}

/// The memory retrieval and answer evaluation harness (#70), LongMemEval
/// style: builds the memory index from a `MemoryEvalDataset` through the
/// production path (`MemoryIndexRebuilder` and `MemoryChunker`), asks
/// every question through each retrieval system, scores the rankings
/// against the evidence, and, with a reader and a judge, answers every
/// question from the top memories and grades the answer.
///
/// ```swift
/// let dataset = try MemoryEvalDataset.load(directory: url)
/// let vectors = try MemoryEvalRecordedEmbeddings.load(vectorsURL)
/// let model = FoundationModelsEvalLanguageModel()
/// let report = try await MemoryEvaluator(dataset: dataset).run(
///     embeddings: vectors,
///     reader: LLMMemoryEvalReader(model: model, userName: dataset.userName, timeZone: dataset.timeZone),
///     judge: LLMMemoryEvalJudge(model: model))
/// print(report.table())
/// ```
///
/// Questions are asked at the dataset's `now` in its time zone, so "last
/// week" means the same days on every run.
public struct MemoryEvaluator: Sendable {
    public struct Configuration: Sendable {
        /// The search configuration of the `MemorySearch` systems.
        public var search = MemorySearch.Configuration.default
        /// How chunks are cut; `nil` for the shipped 128-token model's policy
        /// in the dataset's time zone.
        public var chunking: ChunkingPolicy?
        /// Systems to measure. `hybrid` (or, without vectors,
        /// `bm25-fallback`) is the primary one.
        public var systems: [MemoryEvalSystem] = MemoryEvalSystem.allCases
        /// Memories handed to the reader per question.
        public var contextSize = 8

        public init() {}
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case embeddingFailed(String)
        case vectorsUnavailable(question: String, reason: String)
        case noSystems

        public var description: String {
            switch self {
            case .embeddingFailed(let reason): "Embedding the eval corpus failed: \(reason)"
            case .vectorsUnavailable(let question, let reason):
                "Question \(question) was searched without vectors: \(reason)"
            case .noSystems: "No retrieval system can run (the selected ones all need vectors)"
            }
        }
    }

    /// The top this many evidence ids are scored.
    public static let rankingDepth = 10

    public let dataset: MemoryEvalDataset
    public let corpus: MemoryEvalCorpus
    public var configuration: Configuration

    public init(dataset: MemoryEvalDataset, configuration: Configuration = Configuration()) {
        self.dataset = dataset
        self.corpus = MemoryEvalCorpus(dataset)
        self.configuration = configuration
    }

    public var chunkingPolicy: ChunkingPolicy {
        configuration.chunking ?? .forSequenceLength(128, timeZone: dataset.timeZone)
    }

    /// The parser for questions, in the dataset's time zone and week.
    public var timeParser: TemporalQueryParser {
        TemporalQueryParser(timeZone: dataset.timeZone, firstWeekday: dataset.manifest.firstWeekday)
    }

    // MARK: - Index

    /// An in-memory index of the corpus, built the way the app builds it.
    ///
    /// - Parameter embedder: Embeds the chunks; `nil` builds a keyword-only
    ///   index. A failure to embed throws, rather than quietly measuring
    ///   BM25 alone.
    public func buildIndex(embedder: (any MemoryChunkEmbedding)?) async throws -> MemoryIndex {
        let index = try MemoryIndex.inMemory()
        let rebuilder = MemoryIndexRebuilder(
            index: index, sources: corpus.sources, chunker: MemoryChunker(policy: chunkingPolicy), embedder: embedder,
            clock: ManualClock(now: dataset.now))
        let report = try await rebuilder.rebuild()
        if embedder != nil, let failure = report.embeddingFailure { throw Failure.embeddingFailed(failure) }
        return index
    }

    /// Every chunk key text (to embed) and question, for recording vectors
    /// with a reference model (`MemoryEvalExportTests`).
    public func embeddingTexts() async throws -> (documents: [String], queries: [String]) {
        let index = try await buildIndex(embedder: nil)
        let chunks = try await index.chunksNeedingEmbedding(modelVersion: "export", limit: 1_000_000)
        return (Array(Set(chunks.map(\.keyText))).sorted(), dataset.questions.map(\.question))
    }

    // MARK: - Run

    /// Runs the evaluation.
    ///
    /// - Parameters:
    ///   - embeddings: Chunk and query vectors (recorded, or a real model);
    ///     `nil` measures only the systems that don't need them.
    ///   - reader: Answers each question from the primary system's top
    ///     `contextSize` memories; `nil` skips the answer stage.
    ///   - judge: Grades the answers; required with a reader.
    ///   - answersSkipped: Why there is no reader, for the report.
    ///   - commit: Recorded in the report.
    ///   - progress: One line per stage and every 20 answers.
    public func run(
        embeddings: (any MemoryChunkEmbedding & MemoryQueryEmbedding)?,
        reader: (any MemoryEvalReader)? = nil,
        judge: (any MemoryEvalJudge)? = nil,
        answersSkipped: String? = nil,
        commit: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MemoryEvalReport {
        let systems = configuration.systems.filter { embeddings != nil || !$0.needsVectors }
        guard !systems.isEmpty else { throw Failure.noSystems }
        let primary = systems.contains(.hybrid) ? MemoryEvalSystem.hybrid : systems[0]

        let index = try await buildIndex(embedder: embeddings)
        let statistics = try await index.statistics(modelVersion: embeddings?.currentModelVersion())
        progress?(
            "indexed \(statistics.chunks) chunks (\(statistics.vectors) vectors) from \(dataset.sessions.count) "
                + "sessions, \(dataset.documents.count) documents and \(dataset.facts.count) facts")

        var systemResults: [MemoryEvalReport.SystemResult] = []
        var primaryRuns: [String: SearchRun] = [:]
        for system in systems {
            var perQuestion: [(MemoryEvalDataset.Question, MemoryEvalRetrievalMetrics)] = []
            for question in dataset.questions {
                try Task.checkCancellation()
                let run = try await search(question, system: system, index: index, embeddings: embeddings)
                if system == primary { primaryRuns[question.id] = run }
                guard question.type != .abstention else { continue }
                perQuestion.append(
                    (
                        question,
                        MemoryEvalRetrievalMetrics(
                            ranking: run.ranking, evidence: question.evidence, stale: question.stale)
                    ))
            }
            let byType = Dictionary(grouping: perQuestion, by: \.0.type.rawValue).mapValues {
                MemoryEvalRetrievalMetrics(averaging: $0.map(\.1))
            }
            let result = MemoryEvalReport.SystemResult(
                id: system.rawValue, summary: system.summary,
                overall: MemoryEvalRetrievalMetrics(averaging: perQuestion.map(\.1)), byType: byType,
                misses: perQuestion.filter { $0.1.hitAt5 == 0 }.map(\.0.id))
            systemResults.append(result)
            progress?(
                "\(system.rawValue): Recall@5 \(MemoryEvalReport.number(result.overall.recallAt5)), "
                    + "MRR@10 \(MemoryEvalReport.number(result.overall.mrrAt10))")
        }

        var questionResults: [MemoryEvalReport.QuestionResult] = dataset.questions.map { question in
            let run = primaryRuns[question.id]
            let ranking = run?.ranking ?? []
            let retrieval =
                question.type == .abstention
                ? nil : MemoryEvalRetrievalMetrics(ranking: ranking, evidence: question.evidence, stale: question.stale)
            let evidence = Set(question.evidence.flatMap(\.alternatives))
            return MemoryEvalReport.QuestionResult(
                id: question.id, type: question.type, ranking: ranking, retrieval: retrieval,
                firstEvidenceRank: ranking.firstIndex(where: evidence.contains).map { $0 + 1 },
                timeExpression: run?.timeExpression, expandedFacts: run?.expandedFacts ?? 0)
        }

        var answers: MemoryEvalReport.AnswerResult?
        if let reader, let judge {
            answers = try await answer(
                with: reader, judge: judge, runs: primaryRuns, system: primary, results: &questionResults,
                progress: progress)
        }

        var byType: [String: Int] = [:]
        for question in dataset.questions { byType[question.type.rawValue, default: 0] += 1 }
        let info = MemoryEvalReport.DatasetInfo(
            name: dataset.name, version: dataset.manifest.version, now: dataset.now,
            questions: dataset.questions.count, questionsByType: byType, sessions: dataset.sessions.count,
            turns: dataset.sessions.reduce(0) { $0 + $1.turns.count },
            documents: dataset.documents.count + dataset.documents.reduce(0) { $0 + $1.items.count },
            facts: dataset.facts.count, entities: dataset.entities.count, chunks: statistics.chunks)
        return MemoryEvalReport(
            format: MemoryEvalReport.currentFormat, dataset: info,
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), commit: commit,
            embeddingModel: try await embeddings?.currentModelVersion(), primarySystem: primary.rawValue,
            systems: systemResults, answers: answers,
            answersSkipped: answers == nil ? (answersSkipped ?? "no reader and judge") : nil,
            questions: questionResults, gate: nil)
    }

    // MARK: - Retrieval

    /// One question's search: evidence ids of the top results, and what
    /// the reader is shown.
    struct SearchRun: Sendable {
        var ranking: [String]
        var memories: [MemorySearchResult]
        var timeExpression: String?
        var expandedFacts: Int
    }

    func memorySearch(_ system: MemoryEvalSystem, index: MemoryIndex, embedder: (any MemoryQueryEmbedding)?)
        -> MemorySearch
    {
        MemorySearch(
            index: index, embedder: system == .keywordFallback ? nil : embedder,
            entities: system == .hybridWithoutEntities ? nil : corpus.entityGraph,
            configuration: configuration.search, timeParser: timeParser, clock: ManualClock(now: dataset.now),
            signposter: .disabled(.memory))
    }

    func search(
        _ question: MemoryEvalDataset.Question, system: MemoryEvalSystem, index: MemoryIndex,
        embeddings: (any MemoryQueryEmbedding)?
    ) async throws -> SearchRun {
        // A few extra, since several chunks of one record count once.
        let depth = Self.rankingDepth + 10
        switch system {
        case .dense:
            guard let embeddings else { throw Failure.noSystems }
            let vector = try await embeddings.embedQuery(question.question)
            let hits = try await index.vectorSearch(vector, limit: depth)
            let chunks = try await index.chunks(withIDs: hits.map(\.chunkID))
            let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
            return SearchRun(
                ranking: ranking(hits.compactMap { byID[$0.chunkID] }), memories: [], timeExpression: nil,
                expandedFacts: 0)
        case .hybrid, .hybridWithoutEntities, .keywordFallback:
            let response = try await memorySearch(system, index: index, embedder: embeddings)
                .search(question.question, limit: depth)
            if system.needsVectors, !response.usedVectors {
                throw Failure.vectorsUnavailable(
                    question: question.id, reason: response.vectorFailure ?? "no embedding")
            }
            return SearchRun(
                ranking: ranking(response.results.map(\.chunk)),
                memories: Array(response.results.prefix(configuration.contextSize)),
                timeExpression: response.timeExpression.map { "\($0.anchor) \($0.range)" },
                expandedFacts: response.expandedFacts)
        }
    }

    /// Evidence ids of `chunks`, each record once, at most `rankingDepth`.
    /// A chunk the dataset didn't produce keeps its place as `chunk:<id>`.
    func ranking(_ chunks: [MemoryChunk]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for chunk in chunks {
            let id = corpus.evidenceID(of: chunk) ?? "chunk:\(chunk.id.uuidString)"
            if seen.insert(id).inserted { ids.append(id) }
            if ids.count == Self.rankingDepth { break }
        }
        return ids
    }

    // MARK: - Answers

    private func answer(
        with reader: any MemoryEvalReader, judge: any MemoryEvalJudge, runs: [String: SearchRun],
        system: MemoryEvalSystem, results: inout [MemoryEvalReport.QuestionResult],
        progress: (@Sendable (String) -> Void)?
    ) async throws -> MemoryEvalReport.AnswerResult {
        let clock = ContinuousClock()
        let start = clock.now
        var byType: [String: MemoryEvalAnswerMetrics] = [:]
        for (position, question) in dataset.questions.enumerated() {
            try Task.checkCancellation()
            var metrics = MemoryEvalAnswerMetrics(count: 1)
            do {
                let response = try await reader.answer(
                    question.question, memories: runs[question.id]?.memories ?? [], now: dataset.now)
                results[position].response = response
                let verdict = try await judge.judge(question, response: response)
                results[position].correct = verdict.correct
                results[position].judgeReply = verdict.reply
                if verdict.correct == true { metrics.correct = 1 }
                if verdict.correct == nil {
                    metrics.failures = 1
                    results[position].error = "unparsable verdict"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                metrics.failures = 1
                results[position].error = String(describing: error)
            }
            byType[question.type.rawValue] = MemoryEvalAnswerMetrics(
                summing: [byType[question.type.rawValue] ?? MemoryEvalAnswerMetrics(), metrics])
            if (position + 1) % 20 == 0 || position + 1 == dataset.questions.count {
                let total = MemoryEvalAnswerMetrics(summing: byType.values)
                progress?(
                    "answered \(position + 1) of \(dataset.questions.count): "
                        + "\(MemoryEvalReport.percent(total.accuracy)) correct, \(total.failures) failures")
            }
        }
        return MemoryEvalReport.AnswerResult(
            reader: reader.identifier, judge: judge.identifier, system: system.rawValue,
            contextSize: configuration.contextSize, overall: MemoryEvalAnswerMetrics(summing: byType.values),
            byType: byType, seconds: (clock.now - start) / .seconds(1))
    }
}
