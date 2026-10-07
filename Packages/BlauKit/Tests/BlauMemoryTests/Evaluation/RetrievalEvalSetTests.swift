import BlauMemory
import Foundation
import Testing

/// The personal retrieval eval set shipped in `Fixtures/RetrievalEval`.
enum PersonalEvalSet {
    static var directory: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "Fixtures/RetrievalEval", withExtension: nil))
        }
    }

    static func load() throws -> RetrievalEvalSet {
        try RetrievalEvalSet.load(directory: directory)
    }
}

@Suite("Retrieval eval set")
struct RetrievalEvalSetTests {
    @Test func personalSetHas200QueriesOverFourCategories() throws {
        let set = try PersonalEvalSet.load()
        #expect(set.queries.count == 200)
        #expect(set.documents.count == 216)
        let byCategory = Dictionary(grouping: set.queries, by: \.category).mapValues(\.count)
        #expect(byCategory == ["company": 55, "yc": 45, "conversation": 65, "profile": 35])
        #expect(Set(set.queries.map(\.style)) == ["paraphrase", "keyword"])
        #expect(set.documents.allSatisfy { !$0.text.isEmpty })
    }

    @Test func everyConversationChunkIsOneExchange() throws {
        let set = try PersonalEvalSet.load()
        let exchanges = set.documents.filter { $0.kind == "exchange" }
        #expect(exchanges.count == 76)
        for exchange in exchanges {
            #expect(exchange.text.hasPrefix("User: "))
            #expect(exchange.text.contains(" Blau: "))
            #expect(exchange.date != nil)
        }
    }

    @Test func rejectsUnknownRelevantDocuments() {
        #expect(throws: RetrievalEvalSet.LoadError.unknownRelevantDocument(query: "q", document: "missing")) {
            try RetrievalEvalSet(
                documents: [.init(id: "a", kind: "fact", text: "A")],
                queries: [.init(id: "q", text: "?", relevant: ["missing"], category: "c")])
        }
    }

    @Test func rejectsDuplicatesAndEmptyLabels() {
        #expect(throws: RetrievalEvalSet.LoadError.duplicateDocument("a")) {
            try RetrievalEvalSet(
                documents: [.init(id: "a", kind: "fact", text: "A"), .init(id: "a", kind: "fact", text: "B")],
                queries: [])
        }
        #expect(throws: RetrievalEvalSet.LoadError.noRelevantDocuments(query: "q")) {
            try RetrievalEvalSet(
                documents: [.init(id: "a", kind: "fact", text: "A")],
                queries: [.init(id: "q", text: "?", relevant: [], category: "c")])
        }
        #expect(throws: RetrievalEvalSet.LoadError.duplicateQuery("q")) {
            try RetrievalEvalSet(
                documents: [.init(id: "a", kind: "fact", text: "A")],
                queries: [
                    .init(id: "q", text: "?", relevant: ["a"], category: "c"),
                    .init(id: "q", text: "!", relevant: ["a"], category: "c"),
                ])
        }
    }

    @Test func emptyDirectoryIsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: RetrievalEvalSet.LoadError.noFiles(directory.path)) {
            try RetrievalEvalSet.load(directory: directory)
        }
    }
}
