import BlauCore
import BlauTelemetry
import Foundation

/// Runs a retrieval eval set through a `TextEmbedder` exactly the way the
/// memory index will (#62): every document gets the model's document prompt,
/// every query its query prompt, each vector is cut to the stored Matryoshka
/// width, normalized and quantized to int8, and documents are ranked by
/// cosine similarity of the int8 codes (brute force, ties in document order).
///
/// Used by #59 to compare embedding models on real hardware, and by #70's
/// evaluation harness.
public struct EmbeddingRetrievalEvaluator: Sendable {
    public var spec: TextEmbeddingModelSpec
    /// Width kept from each vector; `nil` keeps the full output.
    public var storedDimensions: Int?
    public var clock: any BlauClock
    public var signposter: Signposter

    public init(
        spec: TextEmbeddingModelSpec,
        storedDimensions: Int? = nil,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory
    ) {
        self.spec = spec
        self.storedDimensions = storedDimensions
        self.clock = clock
        self.signposter = signposter
    }

    /// What one evaluation measured.
    public struct Evaluation: Codable, Hashable, Sendable {
        public var specID: String
        public var modelIdentifier: String
        public var fullDimensions: Int
        public var storedDimensions: Int
        public var result: RetrievalEvalResult
        /// Vectors with NaN or infinite components (counted, then zeroed).
        public var nonFiniteVectors: Int
        /// Time per `embed` call for documents and for queries.
        public var documentLatency: LatencySummary?
        public var queryLatency: LatencySummary?
    }

    public enum Failure: Error, Hashable, Sendable {
        /// The embedder returned vectors of different lengths.
        case inconsistentDimensions(expected: Int, got: Int)
    }

    public func evaluate(_ evalSet: RetrievalEvalSet, embedder: any TextEmbedder) async throws -> Evaluation {
        var nonFinite = 0
        var fullDimensions: Int?

        func embed(_ text: String) async throws -> (codes: [Int8], duration: Duration) {
            let start = clock.uptime
            var vector = try await signposter.withInterval(.memoryEmbed) { try await embedder.embed(text) }
            let duration = clock.uptime - start
            if let expected = fullDimensions, expected != vector.count {
                throw Failure.inconsistentDimensions(expected: expected, got: vector.count)
            }
            fullDimensions = vector.count
            if !vector.allSatisfy(\.isFinite) {
                nonFinite += 1
                vector = vector.map { $0.isFinite ? $0 : 0 }
            }
            let width = storedDimensions ?? vector.count
            let stored = MatryoshkaEmbedding.quantized(MatryoshkaEmbedding.truncatedAndNormalized(vector, to: width))
            return (stored.codes, duration)
        }

        var documentCodes: [[Int8]] = []
        var documentTimes: [Duration] = []
        for document in evalSet.documents {
            try Task.checkCancellation()
            let (codes, duration) = try await embed(spec.documentText(document.text))
            documentCodes.append(codes)
            documentTimes.append(duration)
        }

        var rankings: [String: [String]] = [:]
        var queryTimes: [Duration] = []
        for query in evalSet.queries {
            try Task.checkCancellation()
            let (codes, duration) = try await embed(spec.queryText(query.text))
            queryTimes.append(duration)
            rankings[query.id] = Self.rank(query: codes, documents: documentCodes).map { evalSet.documents[$0].id }
        }

        let full = fullDimensions ?? 0
        return Evaluation(
            specID: spec.id,
            modelIdentifier: embedder.modelIdentifier,
            fullDimensions: full,
            storedDimensions: min(storedDimensions ?? full, full),
            result: RetrievalEvalResult(evalSet: evalSet, rankings: rankings),
            nonFiniteVectors: nonFinite,
            documentLatency: LatencySummary(documentTimes),
            queryLatency: LatencySummary(queryTimes)
        )
    }

    /// Document indices by descending cosine similarity of int8 codes; ties
    /// keep document order. A zero vector scores 0 against everything.
    public static func rank(query: [Int8], documents: [[Int8]]) -> [Int] {
        func norm(_ codes: [Int8]) -> Double {
            Double(codes.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }).squareRoot()
        }
        let queryNorm = norm(query)
        let scores = documents.map { document -> Double in
            let length = min(query.count, document.count)
            var dot: Int64 = 0
            for index in 0..<length {
                dot += Int64(query[index]) * Int64(document[index])
            }
            let denominator = queryNorm * norm(document)
            return denominator > 0 ? Double(dot) / denominator : 0
        }
        return scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
    }
}
