import BlauMemory
import Foundation
import Synchronization
import Testing

@Suite("Pretokenized text embedder")
struct PretokenizedTextEmbedderTests {
    final class EchoModel: TokenEmbeddingModel {
        let calls = Mutex<[[Int32]]>([])
        func load() async throws {}
        var maximumSequenceLength: Int { 256 }
        func embed(tokenIDs: [Int32]) async throws -> [Float] {
            calls.withLock { $0.append(tokenIDs) }
            return tokenIDs.map(Float.init)
        }
        func unload() async {}
    }

    @Test func readsTheConversionScriptsTable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let json = #"{"model": "qwen3-embedding-0.6b", "maximumLength": 256, "tokens": {"hello": [7, 8, 151643]}}"#
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EchoModel()
        let embedder = try PretokenizedTextEmbedder(model: model, tableURL: url)
        #expect(embedder.modelIdentifier == "qwen3-embedding-0.6b-coreml")
        #expect(embedder.texts == ["hello"])
        #expect(try await embedder.embed("hello") == [7, 8, 151_643])
        #expect(model.calls.withLock { $0 } == [[7, 8, 151_643]])
    }

    @Test func unknownTextFails() async {
        let embedder = PretokenizedTextEmbedder(modelIdentifier: "m", model: EchoModel(), tokens: [:])
        await #expect(throws: PretokenizedTextEmbedder.Failure.notInTable("missing")) {
            try await embedder.embed("missing")
        }
    }
}
