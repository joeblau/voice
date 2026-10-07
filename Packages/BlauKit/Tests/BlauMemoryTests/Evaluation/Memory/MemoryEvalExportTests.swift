import Foundation
import Testing

@testable import BlauMemory

/// Writes every chunk key text and question of the memory eval set to the
/// JSON file `BLAU_MEMORY_EVAL_EXPORT` names, for
/// `scripts/embeddings/record_memory_eval_vectors.py` to embed with a
/// reference model (docs/memory-eval.md#recording-vectors). Off otherwise.
///
/// ```json
/// {"documents": ["<key text>", ...], "queries": ["<question>", ...]}
/// ```
@Suite(
    "Memory eval export",
    .enabled(if: (ProcessInfo.processInfo.environment["BLAU_MEMORY_EVAL_EXPORT"] ?? "").isEmpty == false)
)
struct MemoryEvalExportTests {
    struct Export: Encodable {
        var dataset: String
        var documents: [String]
        var queries: [String]
    }

    @Test func exportTheTextsToEmbed() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BLAU_MEMORY_EVAL_EXPORT"])
        let dataset = try MemoryEvalFixtures.dataset()
        let texts = try await MemoryEvaluator(dataset: dataset).embeddingTexts()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Export(dataset: dataset.name, documents: texts.documents, queries: texts.queries))
            .write(to: URL(filePath: path))
        print(
            "[memory-eval] exported \(texts.documents.count) key texts and \(texts.queries.count) questions to \(path)")
    }
}
