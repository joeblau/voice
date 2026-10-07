import Foundation

/// Replays vectors a real embedding model gave every chunk key text and
/// question of a memory eval set, so the harness measures hybrid retrieval
/// with real semantic vectors and no model download.
///
/// `scripts/embeddings/record_memory_eval_vectors.py` writes the file from
/// the texts `MemoryEvalExportTests` exports (docs/memory-eval.md):
///
/// ```json
/// {"model": "qwen3-embedding-0.6b", "modelVersion": "qwen3-embedding-0.6b-256d-int8@97b0c614",
///  "dimensions": 256,
///  "documents": {"<SHA-256 of the key text>": "<base64 int8 codes>"},
///  "queries": {"<SHA-256 of the question>": "<base64 int8 codes>"}}
/// ```
///
/// A text that wasn't recorded throws: the dataset or the chunker changed,
/// and the vectors must be recorded again.
public struct MemoryEvalRecordedEmbeddings: MemoryChunkEmbedding, MemoryQueryEmbedding {
    public struct File: Codable, Hashable, Sendable {
        public var model: String
        public var modelVersion: String
        public var repo: String?
        public var revision: String?
        public var dimensions: Int
        public var documents: [String: String]
        public var queries: [String: String]
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case invalidCodes(String)
        case wrongDimensions(String, expected: Int, got: Int)
        case missingDocument(hash: String)
        case missingQuery(hash: String)

        public var description: String {
            switch self {
            case .invalidCodes(let key): "Recorded vector \(key) isn't valid base64"
            case .wrongDimensions(let key, let expected, let got):
                "Recorded vector \(key) has \(got) dimensions, expected \(expected)"
            case .missingDocument(let hash):
                "No recorded vector for chunk key text \(hash.prefix(12)); re-record the memory eval vectors "
                    + "(docs/memory-eval.md#recording-vectors)"
            case .missingQuery(let hash):
                "No recorded vector for question \(hash.prefix(12)); re-record the memory eval vectors "
                    + "(docs/memory-eval.md#recording-vectors)"
            }
        }
    }

    public let model: String
    public let modelVersion: String
    public let dimensions: Int
    private let documents: [String: TextEmbedding]
    private let queries: [String: TextEmbedding]

    public init(_ file: File) throws(Failure) {
        func embeddings(_ encoded: [String: String]) throws(Failure) -> [String: TextEmbedding] {
            var result: [String: TextEmbedding] = [:]
            for (key, base64) in encoded {
                guard let data = Data(base64Encoded: base64) else { throw .invalidCodes(key) }
                guard data.count == file.dimensions else {
                    throw .wrongDimensions(key, expected: file.dimensions, got: data.count)
                }
                let codes = data.map { Int8(bitPattern: $0) }
                // Search ranks by the cosine of the codes, so only a zero
                // vector's scale matters.
                let isZero = codes.allSatisfy { $0 == 0 }
                result[key] = TextEmbedding(
                    codes: codes, scale: isZero ? 0 : 1 / 127, modelVersion: file.modelVersion, tokenCount: 0)
            }
            return result
        }
        model = file.model
        modelVersion = file.modelVersion
        dimensions = file.dimensions
        documents = try embeddings(file.documents)
        queries = try embeddings(file.queries)
    }

    public static func load(_ url: URL) throws -> MemoryEvalRecordedEmbeddings {
        try MemoryEvalRecordedEmbeddings(JSONDecoder().decode(File.self, from: Data(contentsOf: url)))
    }

    /// The key a text is recorded under: SHA-256 of its UTF-8 bytes, 64
    /// lowercase hex digits (the same as `MemoryChunk.contentHash`).
    public static func key(for text: String) -> String {
        MemoryChunk.contentHash(of: text)
    }

    public var documentCount: Int { documents.count }
    public var queryCount: Int { queries.count }

    public func currentModelVersion() async throws -> String { modelVersion }

    public func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
        try texts.map { text in
            let key = Self.key(for: text)
            guard let embedding = documents[key] else { throw Failure.missingDocument(hash: key) }
            return embedding
        }
    }

    public func embedQuery(_ text: String) async throws -> TextEmbedding {
        let key = Self.key(for: text)
        guard let embedding = queries[key] else { throw Failure.missingQuery(hash: key) }
        return embedding
    }
}
