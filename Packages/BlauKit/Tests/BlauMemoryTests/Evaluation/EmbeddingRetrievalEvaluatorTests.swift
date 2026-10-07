import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@Suite("Embedding retrieval evaluator")
struct EmbeddingRetrievalEvaluatorTests {
    /// Embeds each text as a one-hot vector chosen by `slot(for:)`, so the
    /// test decides exactly which documents a query matches. Records every
    /// text it was asked for and advances the clock 2 ms per call.
    final class OneHotEmbedder: TextEmbedder {
        let modelIdentifier = "one-hot"
        let width: Int
        let clock: ManualClock
        let slot: @Sendable (String) -> Int?
        let seen = Mutex<[String]>([])

        init(width: Int, clock: ManualClock, slot: @escaping @Sendable (String) -> Int?) {
            self.width = width
            self.clock = clock
            self.slot = slot
        }

        func embed(_ text: String) async throws -> [Float] {
            seen.withLock { $0.append(text) }
            clock.advance(by: .milliseconds(2))
            var vector = [Float](repeating: 0, count: width)
            if let index = slot(text) { vector[index] = 1 }
            return vector
        }
    }

    static let spec = TextEmbeddingModelSpec(
        id: "fake", displayName: "Fake", source: "test", license: "none", queryPrompt: "Q: ", documentPrompt: "D: ",
        fullDimensions: 8, storedDimensions: 4, maximumTokens: 16, pooling: .mean, isMatryoshka: true)

    static func smallSet() throws -> RetrievalEvalSet {
        try RetrievalEvalSet(
            documents: (0..<4).map { .init(id: "d\($0)", kind: "fact", text: "doc \($0)") },
            queries: [
                .init(id: "q0", text: "find 0", relevant: ["d0"], category: "c"),
                .init(id: "q2", text: "find 2", relevant: ["d2"], category: "c"),
            ])
    }

    @Test func appliesPromptsTruncatesAndRanks() async throws {
        let clock = ManualClock()
        // Slot = the digit in the text; the query for 2 points at d2.
        let embedder = OneHotEmbedder(width: 8, clock: clock) { text in text.last?.wholeNumberValue }
        let evaluator = EmbeddingRetrievalEvaluator(
            spec: Self.spec, storedDimensions: 4, clock: clock, signposter: .disabled(.memory))
        let evaluation = try await evaluator.evaluate(Self.smallSet(), embedder: embedder)

        #expect(evaluation.result.overall.hitAt1 == 1)
        #expect(evaluation.result.overall.mrrAt10 == 1)
        #expect(evaluation.fullDimensions == 8)
        #expect(evaluation.storedDimensions == 4)
        #expect(evaluation.nonFiniteVectors == 0)
        #expect(evaluation.modelIdentifier == "one-hot")
        #expect(evaluation.documentLatency?.p50 == 2)
        #expect(evaluation.queryLatency?.count == 2)
        let seen = embedder.seen.withLock { $0 }
        #expect(seen.prefix(4).allSatisfy { $0.hasPrefix("D: doc ") })
        #expect(seen.suffix(2) == ["Q: find 0", "Q: find 2"])
    }

    @Test func truncationDropsDimensionsPastTheStoredWidth() async throws {
        // Document 5 lives in dimension 5, which a 4-d index throws away: its
        // query can't find it any more.
        let set = try RetrievalEvalSet(
            documents: [.init(id: "d1", kind: "fact", text: "doc 1"), .init(id: "d5", kind: "fact", text: "doc 5")],
            queries: [.init(id: "q5", text: "find 5", relevant: ["d5"], category: "c")])
        let clock = ManualClock()
        let embedder = OneHotEmbedder(width: 8, clock: clock) { $0.last?.wholeNumberValue }
        let full = try await EmbeddingRetrievalEvaluator(spec: Self.spec, clock: clock, signposter: .disabled(.memory))
            .evaluate(set, embedder: embedder)
        let truncated = try await EmbeddingRetrievalEvaluator(
            spec: Self.spec, storedDimensions: 4, clock: clock, signposter: .disabled(.memory)
        ).evaluate(set, embedder: embedder)
        #expect(full.result.overall.hitAt1 == 1)
        #expect(truncated.result.overall.hitAt1 == 0)
        #expect(truncated.result.overall.mrrAt10 == 0.5)
    }

    @Test func countsAndNeutralizesNonFiniteVectors() async throws {
        struct NaNEmbedder: TextEmbedder {
            let modelIdentifier = "nan"
            func embed(_ text: String) async throws -> [Float] {
                text.hasPrefix("Q") ? [.nan, 1, 0, 0] : [1, 0, 0, 0]
            }
        }
        let evaluation = try await EmbeddingRetrievalEvaluator(spec: Self.spec, signposter: .disabled(.memory))
            .evaluate(Self.smallSet(), embedder: NaNEmbedder())
        #expect(evaluation.nonFiniteVectors == 2)
        #expect(evaluation.result.overall.count == 2)
    }

    @Test func inconsistentWidthsFail() async throws {
        struct Ragged: TextEmbedder {
            let modelIdentifier = "ragged"
            func embed(_ text: String) async throws -> [Float] {
                [Float](repeating: 1, count: text.hasPrefix("Q") ? 3 : 4)
            }
        }
        await #expect(throws: EmbeddingRetrievalEvaluator.Failure.inconsistentDimensions(expected: 4, got: 3)) {
            try await EmbeddingRetrievalEvaluator(spec: Self.spec, signposter: .disabled(.memory))
                .evaluate(Self.smallSet(), embedder: Ragged())
        }
    }

    @Test func rankUsesCosineOfInt8CodesWithStableTies() {
        let documents: [[Int8]] = [[0, 127], [127, 0], [127, 0], [0, 0]]
        #expect(EmbeddingRetrievalEvaluator.rank(query: [127, 10], documents: documents) == [1, 2, 0, 3])
    }

    /// An oracle that embeds every query onto its first relevant document
    /// reaches Hit@5 = 1 on the personal set, which checks the evaluator's
    /// bookkeeping end to end on the real fixture.
    @Test func oracleIsPerfectOnThePersonalSet() async throws {
        let set = try PersonalEvalSet.load()
        let documentSlots = Dictionary(
            uniqueKeysWithValues: set.documents.enumerated().map { (Self.spec.documentText($1.text), $0) })
        let querySlots = Dictionary(
            uniqueKeysWithValues: set.queries.map { query in
                (
                    Self.spec.queryText(query.text),
                    set.documents.firstIndex { $0.id == query.relevant[0] } ?? 0
                )
            })
        let width = set.documents.count
        let embedder = OneHotEmbedder(width: width, clock: ManualClock()) { documentSlots[$0] ?? querySlots[$0] }
        let evaluation = try await EmbeddingRetrievalEvaluator(spec: Self.spec, signposter: .disabled(.memory))
            .evaluate(set, embedder: embedder)
        #expect(evaluation.result.overall.hitAt1 == 1)
        #expect(evaluation.result.misses.isEmpty)
        #expect(evaluation.result.byCategory.count == 4)
    }
}
