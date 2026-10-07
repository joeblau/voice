import BlauCore
import BlauTelemetry
import Foundation

/// The memory index at personal scale (#62): 50,000 exchange-like chunks
/// with 256-d int8 vectors in an on-disk index, searched the way hybrid
/// retrieval (#64) will search it. The acceptance criterion: **a search
/// over 50k chunks within 20 ms p95 on an A17**.
///
/// Needs no model: the text is synthetic (Zipf-distributed words, so BM25
/// sees realistic posting lists) and the vectors are random unit vectors,
/// which cost the brute-force search exactly what real ones do. Records
/// `build` (writing the index), `load` (the launch cost of reading every
/// vector into the matrix), `search.vector`, `search.keyword` and
/// `search.hybrid` (both at once, as #64 runs them) latencies,
/// `budget.search`, the file size and a verdict note.
public struct MemoryIndexSearchBenchmark: BenchmarkCase {
    /// The criterion's budget for one search.
    public static let searchBudget: Duration = .milliseconds(20)

    public let id: String
    public let title: String
    public var category: LogCategory { .memory }

    public let chunkCount: Int
    public let queries: Int
    public let warmupQueries: Int
    public let limit: Int
    public let dimensions: Int
    private let directory: @Sendable () throws -> URL

    public init(
        id: String = "memory.index.search50k",
        title: String = "Memory index search, 50k chunks",
        chunkCount: Int = 50_000,
        queries: Int = 200,
        warmupQueries: Int = 20,
        limit: Int = 20,
        dimensions: Int = 256,
        directory: @escaping @Sendable () throws -> URL = { FileManager.default.temporaryDirectory }
    ) {
        self.id = id
        self.title = title
        self.chunkCount = chunkCount
        self.queries = queries
        self.warmupQueries = warmupQueries
        self.limit = limit
        self.dimensions = dimensions
        self.directory = directory
    }

    public func run(recorder: BenchmarkRecorder, context: BenchmarkContext) async throws {
        let folder = try directory().appending(
            path: "blau-index-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: MemoryIndex.fileName)
        var memory = context.memoryWatermark()

        recorder.progress(0, "Writing \(chunkCount) chunks")
        let corpus = SyntheticCorpus(dimensions: dimensions)
        let modelVersion = "benchmark-random-\(dimensions)d-int8"
        let (_, buildTime) = try await context.measure {
            let index = try MemoryIndex.open(at: url)
            var generator = TextEmbeddingBatchBenchmark.SplitMix(seed: 62)
            let perSource = 50
            var written = 0
            while written < chunkCount {
                try Task.checkCancellation()
                var sources: [MemoryIndex.SourceChunks] = []
                var embeddings: [UUID: TextEmbedding] = [:]
                for _ in 0..<20 where written < chunkCount {
                    let sourceID = UUID()
                    let count = min(perSource, chunkCount - written)
                    let chunks = (0..<count).map { ordinal in
                        let text = corpus.exchange(&generator)
                        return MemoryChunk(
                            sourceID: sourceID, sourceKind: .conversation, ordinal: ordinal, text: text, keyText: text,
                            createdAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(written + ordinal) * 600),
                            conversationID: sourceID)
                    }
                    for chunk in chunks {
                        embeddings[chunk.id] = TextEmbedding(
                            codes: corpus.vector(&generator), scale: 1 / 127, modelVersion: modelVersion, tokenCount: 0)
                    }
                    sources.append(MemoryIndex.SourceChunks(kind: .conversation, sourceID: sourceID, chunks: chunks))
                    written += count
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
        memory.sample()

        var generator = TextEmbeddingBatchBenchmark.SplitMix(seed: 6_200)
        var vectorLatencies: [Duration] = []
        var keywordLatencies: [Duration] = []
        var hybridLatencies: [Duration] = []
        var keywordHits = 0
        let total = warmupQueries + queries
        for iteration in 0..<total {
            try Task.checkCancellation()
            let text = corpus.query(&generator)
            let query = TextEmbedding(
                codes: corpus.vector(&generator), scale: 1 / 127, modelVersion: modelVersion, tokenCount: 0)
            let limit = limit
            let (_, vectorTime) = try await context.measure { try await index.vectorSearch(query, limit: limit) }
            let (hits, keywordTime) = try await context.measure { try await index.keywordSearch(text, limit: limit) }
            let (_, hybridTime) = try await context.measure {
                async let vector = index.vectorSearch(query, limit: limit)
                async let keyword = index.keywordSearch(text, limit: limit)
                return try await (vector, keyword)
            }
            if iteration >= warmupQueries {
                vectorLatencies.append(vectorTime)
                keywordLatencies.append(keywordTime)
                hybridLatencies.append(hybridTime)
                keywordHits += hits.isEmpty ? 0 : 1
            }
            recorder.progress(0.6 + 0.4 * Double(iteration + 1) / Double(total), "Query \(iteration + 1) of \(total)")
        }
        memory.sample()

        recorder.recordLatencies("search.vector", vectorLatencies)
        recorder.recordLatencies("search.keyword", keywordLatencies)
        recorder.recordLatencies("search.hybrid", hybridLatencies)
        recorder.record("budget.search", Self.searchBudget)
        recorder.record("keyword.queriesWithHits", Double(keywordHits), unit: .count)
        let bytes =
            (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size])
            as? NSNumber
        recorder.record("index.fileSize", bytes: bytes?.uint64Value)
        recorder.note("\(matrix.count) chunks × \(dimensions)-d int8, top \(limit), \(queries) queries")
        if let p95 = LatencySummary(hybridLatencies)?.p95 {
            let budget = Self.searchBudget / .milliseconds(1)
            recorder.note(
                p95 <= budget
                    ? "Within budget: hybrid search p95 \(String(format: "%.2f", p95)) ms ≤ \(Int(budget)) ms"
                    : "Over budget: hybrid search p95 \(String(format: "%.2f", p95)) ms > \(Int(budget)) ms")
        }
        recorder.recordMemory(memory)
        recorder.progress(1, "Done")
    }

    /// Deterministic exchange-like text and random unit vectors.
    struct SyntheticCorpus: Sendable {
        let dimensions: Int
        /// Function words (frequent) followed by content words (Zipf).
        let vocabulary: [String]

        init(dimensions: Int) {
            self.dimensions = dimensions
            let content = (0..<12_000).map { index in
                // Pronounceable, distinct, porter-stable pseudo-words.
                let syllables = ["ka", "lo", "mi", "ne", "ru", "sa", "to", "vi", "ze", "po", "da", "fu"]
                var word = ""
                var value = index + 1
                while value > 0 {
                    word += syllables[value % syllables.count]
                    value /= syllables.count
                }
                return word
            }
            vocabulary = Array(KeywordQuery.stopWords.sorted().prefix(60)) + content
        }

        /// A Zipf-ish word index: rank r is about 1 / r as likely.
        func word(_ generator: inout TextEmbeddingBatchBenchmark.SplitMix) -> String {
            let uniform = Double(generator.next() % 1_000_000) / 1_000_000
            let rank = Int(pow(Double(vocabulary.count), uniform)) - 1
            return vocabulary[max(0, min(vocabulary.count - 1, rank))]
        }

        func exchange(_ generator: inout TextEmbeddingBatchBenchmark.SplitMix) -> String {
            let user = (0..<(20 + Int(generator.next() % 20))).map { _ in word(&generator) }
            let agent = (0..<(30 + Int(generator.next() % 30))).map { _ in word(&generator) }
            return "User: " + user.joined(separator: " ") + "\nBlau: " + agent.joined(separator: " ")
        }

        func query(_ generator: inout TextEmbeddingBatchBenchmark.SplitMix) -> String {
            (0..<(4 + Int(generator.next() % 5))).map { _ in word(&generator) }.joined(separator: " ")
        }

        func vector(_ generator: inout TextEmbeddingBatchBenchmark.SplitMix) -> [Int8] {
            (0..<dimensions).map { _ in Int8(truncatingIfNeeded: Int(generator.next() % 255) - 127) }
        }
    }
}
