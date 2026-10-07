// Micro-benchmarks for BlauKit's pure-Swift hot paths (#73), run with
// ordo-one's package-benchmark on the macOS host:
//
//     make microbench            # run and print the results
//     make microbench-check      # compare with the committed thresholds
//
// See docs/performance.md, "Micro-benchmarks". Every benchmark runs on
// deterministic data (fixed seeds), so the instruction and allocation counts
// the regression gate checks only change when the code does.

import Benchmark
import BlauCore
import BlauMemory
import BlauTopics
import Foundation

let benchmarks: @Sendable () -> Void = {
    // The regression gate (docs/performance.md, "Micro-benchmarks"): a p90
    // more than 10% worse than the committed thresholds (`make
    // microbench-check`, every CI run) or than another revision
    // (`make microbench-compare`) fails.
    //
    // Only the deterministic counters are gated: allocations, which come out
    // the same on every run and every machine, and instructions retired,
    // where the machine exposes them (Apple silicon Macs do; GitHub's macOS
    // VMs don't, so CI gates allocations). CPU and wall-clock time are
    // reported, never gated: on Apple silicon a run that lands on the
    // efficiency cores is about a third slower with identical code. A metric
    // missing from this table would be checked with package-benchmark's
    // defaults, so every measured metric is listed.
    let gate: [BenchmarkMetric: BenchmarkThresholds] = [
        .instructions: .init(relative: [.p90: 10]),
        .mallocCountTotal: .init(relative: [.p90: 10]),
        .cpuTotal: .init(),
        .wallClock: .init(),
        .throughput: .init(),
    ]

    Benchmark.defaultConfiguration = .init(
        metrics: [.instructions, .mallocCountTotal, .wallClock, .cpuTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(3),
        maxIterations: 1_000,
        thresholds: gate
    )

    // MARK: Topic engine (BlauTopics)

    // The streaming segmenter's whole decision path (depth scores,
    // statistics, hysteresis) over a 240-exchange conversation with a topic
    // change every 8 exchanges, on precomputed lexical embeddings: about an
    // hour of talk. Embedding is benchmarked separately below.
    Benchmark(
        "topics.segment-240-exchanges",
        closure: { benchmark, input in
            var segmenter = TopicSegmenter()
            var events = 0
            for (unit, embedding) in zip(input.units, input.embeddings) {
                events += (try? segmenter.append(unit, embedding: embedding))?.count ?? 0
            }
            events += segmenter.finish().count
            blackHole(events)
            blackHole(segmenter.boundaries.count)
        },
        setup: { TopicInput.make(exchanges: 240) }
    )

    // The lexical embedder the segmenter falls back to, over the same
    // exchanges.
    Benchmark(
        "topics.lexical-embed-240-exchanges",
        closure: { benchmark, input in
            let embedder = LexicalTextEmbedder()
            for unit in input.units {
                blackHole(embedder.vector(for: unit.text))
            }
        },
        setup: { TopicInput.make(exchanges: 240) }
    )

    // MARK: Memory retrieval (BlauMemory)

    // Reciprocal rank fusion of a BM25 and a vector ranking (50 hits each,
    // half of them shared), for 1,000 queries: hybrid retrieval's (#64)
    // fusion step.
    Benchmark(
        "memory.rrf-1000-queries-2x50-hits",
        closure: { benchmark, rankings in
            for pair in rankings {
                blackHole(reciprocalRankFusion(pair))
            }
        },
        setup: { FusionInput.make(queries: 1_000, hits: 50) }
    )

    // The int8 vector search behind memory search: cosine of 256-d int8
    // codes against a 10,000-row matrix and the top 10 (vDSP dot products
    // plus a heap), for 20 queries.
    Benchmark(
        "memory.int8-top10-of-10k-256d-20-queries",
        closure: { benchmark, input in
            for query in input.queries {
                blackHole(input.matrix.nearest(to: query, limit: 10))
            }
        },
        setup: { VectorInput.make(rows: 10_000, dimensions: 256, queries: 20) }
    )
}

// MARK: - Inputs

/// A scripted conversation as topic units with their embeddings.
struct TopicInput: Sendable {
    let units: [TopicUnit]
    let embeddings: [[Float]]

    static func make(exchanges: Int) -> TopicInput {
        let conversation = ScriptedConversation(exchanges: exchanges, exchangesPerTopic: 8)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let units = conversation.exchanges.map { exchange in
            // 16 s per exchange, as in the scripted replay session.
            let offset = Duration.seconds(16 * exchange.index)
            return TopicUnit(
                userText: exchange.user, agentText: exchange.agent,
                timeRange: TimeRange(start: offset, duration: .seconds(15)),
                startedAt: start.addingTimeInterval(Double(16 * exchange.index)))
        }
        let embedder = LexicalTextEmbedder()
        return TopicInput(units: units, embeddings: units.map { embedder.vector(for: $0.text) })
    }
}

/// Pairs of rankings (BM25, vector) of chunk ids.
enum FusionInput {
    static func make(queries: Int, hits: Int) -> [[[String]]] {
        var random = SeededRandomGenerator(seed: 0x00FF_5105)
        let corpus = (0..<5_000).map { "chunk-\($0)" }
        return (0..<queries).map { _ in
            let keyword = (0..<hits).map { _ in random.pick(corpus) }
            // Half of the vector hits are keyword hits, in another order.
            let shared = random.shuffled(Array(keyword.prefix(hits / 2)))
            let vector = shared + (0..<(hits - shared.count)).map { _ in random.pick(corpus) }
            return [keyword, random.shuffled(vector)]
        }
    }
}

/// A memory vector matrix of random unit vectors and some queries.
struct VectorInput: Sendable {
    let matrix: VectorMatrix
    let queries: [[Int8]]

    static func make(rows: Int, dimensions: Int, queries: Int) -> VectorInput {
        var random = SeededRandomGenerator(seed: 0x0000_1B8D)
        func codes() -> [Int8] {
            (0..<dimensions).map { _ in Int8(truncatingIfNeeded: random.nextIndex(below: 255) - 127) }
        }
        var matrix = VectorMatrix(modelVersion: "benchmark", dimensions: dimensions)
        matrix.reserveCapacity(rows)
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for row in 0..<rows {
            matrix.upsert(
                rowID: Int64(row + 1), chunkID: UUID(), kind: .conversation, createdAt: created, codes: codes())
        }
        return VectorInput(matrix: matrix, queries: (0..<queries).map { _ in codes() })
    }
}
