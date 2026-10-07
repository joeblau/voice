import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation

/// Hybrid retrieval at personal scale (#64): the full `MemorySearch`
/// pipeline (BM25 and vector candidates, weighted RRF, the time boost,
/// entity expansion, dedupe and snippets) over 50,000 chunks in an on-disk
/// index. The acceptance criterion: **p95 search latency under 50 ms**.
///
/// Needs no model. The corpus is `MemoryIndexSearchBenchmark`'s (Zipf
/// words, random unit vectors, which cost the scan exactly what real ones
/// do); a tenth of the chunks are facts about 2,000 entities named after
/// corpus words, so hits name entities and expansion does real work; a
/// third of the queries say "last week", so the time boost runs too. The
/// query vector is precomputed: embedding the query is the shared
/// service's `memory.embed` (#60), measured by its own benchmark.
public struct MemorySearchBenchmark: BenchmarkCase {
    /// The criterion's budget for one search.
    public static let searchBudget: Duration = .milliseconds(50)

    public let id: String
    public let title: String
    public var category: LogCategory { .memory }

    public let chunkCount: Int
    public let entityCount: Int
    public let queries: Int
    public let warmupQueries: Int
    public let limit: Int
    public let dimensions: Int
    private let directory: @Sendable () throws -> URL

    public init(
        id: String = "memory.search50k",
        title: String = "Memory search (hybrid), 50k chunks",
        chunkCount: Int = 50_000,
        entityCount: Int = 2_000,
        queries: Int = 200,
        warmupQueries: Int = 20,
        limit: Int = 10,
        dimensions: Int = 256,
        directory: @escaping @Sendable () throws -> URL = { FileManager.default.temporaryDirectory }
    ) {
        self.id = id
        self.title = title
        self.chunkCount = chunkCount
        self.entityCount = entityCount
        self.queries = queries
        self.warmupQueries = warmupQueries
        self.limit = limit
        self.dimensions = dimensions
        self.directory = directory
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        let folder = try directory().appending(
            path: "blau-search-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: MemoryIndex.fileName)
        var memory = context.memoryWatermark()

        recorder.progress(0, "Writing \(chunkCount) chunks")
        let corpus = MemoryIndexSearchBenchmark.SyntheticCorpus(dimensions: dimensions)
        let modelVersion = "benchmark-random-\(dimensions)d-int8"
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let spacing: TimeInterval = 600
        var generator = TextEmbeddingBatchBenchmark.SplitMix(seed: 64)

        // Entities named after mid-frequency corpus words, so exchanges
        // mention them now and then.
        let names = (0..<entityCount).map { corpus.vocabulary[min(corpus.vocabulary.count - 1, 200 + $0)] }
        let entities = names.map { MemoryEntityGraph.Entity(id: UUID(), name: $0, type: .other) }
        var facts: [MemoryEntityGraph.FactLink] = []

        let (_, buildTime) = try await context.measure {
            let index = try MemoryIndex.open(at: url)
            var written = 0
            while written < chunkCount {
                try Task.checkCancellation()
                var sources: [MemoryIndex.SourceChunks] = []
                var embeddings: [UUID: TextEmbedding] = [:]
                func vector() -> TextEmbedding {
                    TextEmbedding(
                        codes: corpus.vector(&generator), scale: 1 / 127, modelVersion: modelVersion, tokenCount: 0)
                }
                // One conversation of 45 exchanges and 5 facts per batch item.
                for _ in 0..<20 where written < chunkCount {
                    let conversation = UUID()
                    let exchanges = min(45, chunkCount - written)
                    let chunks = (0..<exchanges).map { ordinal in
                        let text = corpus.exchange(&generator)
                        return MemoryChunk(
                            sourceID: conversation, sourceKind: .conversation, ordinal: ordinal, text: text,
                            keyText: text, createdAt: start.addingTimeInterval(Double(written + ordinal) * spacing),
                            conversationID: conversation)
                    }
                    for chunk in chunks { embeddings[chunk.id] = vector() }
                    sources.append(
                        MemoryIndex.SourceChunks(kind: .conversation, sourceID: conversation, chunks: chunks))
                    written += exchanges
                    for _ in 0..<min(5, chunkCount - written) {
                        let factID = UUID()
                        let entity = Int(generator.next() % UInt64(entityCount))
                        let createdAt = start.addingTimeInterval(Double(written) * spacing)
                        let text =
                            names[entity] + " " + (0..<8).map { _ in corpus.word(&generator) }.joined(separator: " ")
                        let chunk = MemoryChunk(
                            sourceID: factID, sourceKind: .fact, ordinal: 0, text: text, keyText: text,
                            createdAt: createdAt)
                        embeddings[chunk.id] = vector()
                        sources.append(MemoryIndex.SourceChunks(kind: .fact, sourceID: factID, chunks: [chunk]))
                        // A fifth of the facts have since stopped being true.
                        let invalidated = generator.next() % 5 == 0 ? createdAt.addingTimeInterval(86_400) : nil
                        facts.append(
                            .init(
                                id: factID, subjectID: entities[entity].id, validFrom: createdAt,
                                invalidatedAt: invalidated))
                        written += 1
                    }
                }
                try await index.replace(sources, embeddings: embeddings)
                recorder.progress(0.6 * Double(written) / Double(chunkCount), "Wrote \(written) chunks")
            }
        }
        recorder.record("build", buildTime)
        memory.sample()

        // A fresh open, as at launch.
        let index = try MemoryIndex.open(at: url)
        let (matrix, loadTime) = try await context.measure { try await index.loadVectors(modelVersion: modelVersion) }
        recorder.record("load", loadTime)
        recorder.record("chunks", Double(matrix.count), unit: .count)
        let graph = MemoryEntityGraph(entities: entities, facts: facts)
        recorder.record("entities", Double(graph.entities.count), unit: .count)
        recorder.record("facts", Double(facts.count), unit: .count)
        memory.sample()

        let total = warmupQueries + queries
        var queryTexts: [String] = []
        var vectors: [String: TextEmbedding] = [:]
        for iteration in 0..<total {
            var text = corpus.query(&generator)
            if iteration % 3 == 0 { text += " last week" }
            if iteration % 4 == 0 { text = names[Int(generator.next() % UInt64(entityCount))] + " " + text }
            text += " #\(iteration)"  // distinct texts for the recorded vectors
            queryTexts.append(text)
            vectors[text] = TextEmbedding(
                codes: corpus.vector(&generator), scale: 1 / 127, modelVersion: modelVersion, tokenCount: 0)
        }
        let now = start.addingTimeInterval(Double(chunkCount) * spacing + 86_400)
        let search = MemorySearch(
            index: index, embedder: FixedQueryEmbedder(vectors: vectors), entities: graph,
            timeParser: TemporalQueryParser(timeZone: TimeZone(identifier: "UTC") ?? .current),
            clock: FixedWallClock(now: now), signposter: .disabled(.memory))

        var latencies: [Duration] = []
        var expanded = 0
        var timed = 0
        var results = 0
        for (iteration, text) in queryTexts.enumerated() {
            try Task.checkCancellation()
            let limit = limit
            let (response, time) = try await context.measure { try await search.search(text, limit: limit) }
            if iteration >= warmupQueries {
                latencies.append(time)
                expanded += response.expandedFacts
                timed += response.timeExpression == nil ? 0 : 1
                results += response.results.count
            }
            recorder.progress(0.6 + 0.4 * Double(iteration + 1) / Double(total), "Query \(iteration + 1) of \(total)")
        }
        memory.sample()

        recorder.recordLatencies("search", latencies)
        recorder.record("budget.search", Self.searchBudget)
        recorder.record("search.expandedFacts", Double(expanded) / Double(max(1, queries)), unit: .count)
        recorder.record("search.timeQueries", Double(timed), unit: .count)
        recorder.record("search.results", Double(results) / Double(max(1, queries)), unit: .count)
        let bytes =
            (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size])
            as? NSNumber
        recorder.record("index.fileSize", bytes: bytes?.uint64Value)
        recorder.note(
            "\(matrix.count) chunks × \(dimensions)-d int8 (\(facts.count) facts about \(entityCount) entities), "
                + "top \(limit), \(queries) queries, query embedding excluded")
        if let p95 = LatencySummary(latencies)?.p95 {
            let budget = Self.searchBudget / .milliseconds(1)
            recorder.note(
                p95 <= budget
                    ? "Within budget: search p95 \(String(format: "%.2f", p95)) ms ≤ \(Int(budget)) ms"
                    : "Over budget: search p95 \(String(format: "%.2f", p95)) ms > \(Int(budget)) ms")
        }
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }

    /// Answers each benchmark query with its precomputed vector.
    struct FixedQueryEmbedder: MemoryQueryEmbedding {
        let vectors: [String: TextEmbedding]

        func embedQuery(_ text: String) async throws -> TextEmbedding {
            guard let vector = vectors[text] else { throw MemorySearch.Failure.noEmbedding }
            return vector
        }
    }

    /// A clock whose wall time is fixed (the benchmark's "now"); uptime is
    /// real.
    struct FixedWallClock: BlauClock {
        let now: Date
        private let system = SystemClock()

        init(now: Date) {
            self.now = now
        }

        var uptime: Duration { system.uptime }

        func sleep(for duration: Duration) async throws {
            try await system.sleep(for: duration)
        }
    }
}
