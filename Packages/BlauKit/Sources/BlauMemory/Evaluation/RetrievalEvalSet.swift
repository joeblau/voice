import Foundation

/// A labelled retrieval benchmark: documents to index and queries with the
/// documents that answer them.
///
/// Blau's personal eval (#59) lives in
/// `Tests/BlauMemoryTests/Fixtures/RetrievalEval/`, one JSON file per
/// category (company facts, YC answers, past conversations, profile facts
/// and notes). `scripts/embeddings/evalset.py` reads the same files, so the
/// Python and Swift numbers are comparable.
public struct RetrievalEvalSet: Hashable, Sendable {
    public struct Document: Codable, Hashable, Sendable {
        public var id: String
        /// `company`, `collectionItem`, `exchange`, `fact` or `note`: the
        /// memory record the chunk stands for.
        public var kind: String
        public var title: String?
        public var text: String
        /// When the record was made (`yyyy-MM-dd`), if it has a date.
        public var date: String?

        public init(id: String, kind: String, title: String? = nil, text: String, date: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.text = text
            self.date = date
        }
    }

    public struct Query: Hashable, Sendable {
        public var id: String
        public var text: String
        /// Every document that answers the query.
        public var relevant: [String]
        /// The file's category (`company`, `yc`, `conversation`, `profile`).
        public var category: String
        /// `paraphrase` (little word overlap with the answer) or `keyword`
        /// (names, numbers, exact terms).
        public var style: String

        public init(id: String, text: String, relevant: [String], category: String, style: String = "paraphrase") {
            self.id = id
            self.text = text
            self.relevant = relevant
            self.category = category
            self.style = style
        }
    }

    public enum LoadError: Error, Hashable, Sendable, CustomStringConvertible {
        case noFiles(String)
        case duplicateDocument(String)
        case duplicateQuery(String)
        case unknownRelevantDocument(query: String, document: String)
        case noRelevantDocuments(query: String)

        public var description: String {
            switch self {
            case .noFiles(let path): "No eval set files (*.json) in \(path)"
            case .duplicateDocument(let id): "Document id \(id) appears more than once"
            case .duplicateQuery(let id): "Query id \(id) appears more than once"
            case .unknownRelevantDocument(let query, let document):
                "Query \(query) lists unknown relevant document \(document)"
            case .noRelevantDocuments(let query): "Query \(query) lists no relevant documents"
            }
        }
    }

    public private(set) var documents: [Document]
    public private(set) var queries: [Query]

    /// Validates that ids are unique and every relevant document exists.
    public init(documents: [Document], queries: [Query]) throws(LoadError) {
        var documentIDs = Set<String>()
        for document in documents where !documentIDs.insert(document.id).inserted {
            throw .duplicateDocument(document.id)
        }
        var queryIDs = Set<String>()
        for query in queries {
            guard queryIDs.insert(query.id).inserted else { throw .duplicateQuery(query.id) }
            guard !query.relevant.isEmpty else { throw .noRelevantDocuments(query: query.id) }
            if let unknown = query.relevant.first(where: { !documentIDs.contains($0) }) {
                throw .unknownRelevantDocument(query: query.id, document: unknown)
            }
        }
        self.documents = documents
        self.queries = queries
    }

    /// Loads every `*.json` file in `directory`, in file-name order.
    public static func load(directory: URL) throws -> RetrievalEvalSet {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw LoadError.noFiles(directory.path) }
        var documents: [Document] = []
        var queries: [Query] = []
        for file in files {
            let part = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            documents += part.documents
            queries += part.queries.map {
                Query(
                    id: $0.id, text: $0.text, relevant: $0.relevant, category: part.category,
                    style: $0.style ?? "paraphrase")
            }
        }
        return try RetrievalEvalSet(documents: documents, queries: queries)
    }

    /// One file's JSON.
    struct File: Decodable {
        struct QueryEntry: Decodable {
            var id: String
            var text: String
            var relevant: [String]
            var style: String?
        }

        var category: String
        var documents: [Document]
        var queries: [QueryEntry]
    }
}
