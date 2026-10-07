import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Synchronization
import Testing

/// Fakes and fixtures for the shared text-embedding service's tests.
enum TextEmbeddingTestSupport {
    /// A spec with distinct prompts, 8-d output and a 2-d stored prefix.
    static let spec = TextEmbeddingModelSpec(
        id: "fake", displayName: "Fake", source: "blau/fake", license: "none",
        queryPrompt: "query: ", documentPrompt: "passage: ", fullDimensions: 8, storedDimensions: 2,
        maximumTokens: 16, pooling: .mean, isMatryoshka: true)

    /// One token per character (its scalar value), cut to `maximumLength`;
    /// records every text it sees.
    final class CharacterTokenizer: TextTokenizing {
        let texts = Mutex<[String]>([])

        func encode(_ text: String, maximumLength: Int?) -> HuggingFaceTokenizer.Encoding {
            texts.withLock { $0.append(text) }
            let ids = text.unicodeScalars.map { Int32($0.value) }
            let limit = maximumLength ?? ids.count
            return HuggingFaceTokenizer.Encoding(
                ids: Array(ids.prefix(limit)), truncatedTokens: max(0, ids.count - limit))
        }
    }

    /// Returns `output(tokenIDs)` for every sequence and records the batches.
    final class FakeNetwork: TokenEmbeddingModel {
        let batches = Mutex<[[[Int32]]]>([])
        let output: @Sendable ([Int32]) -> [Float]

        init(output: @escaping @Sendable ([Int32]) -> [Float] = FakeNetwork.lengthVector) {
            self.output = output
        }

        /// [3, 4, length, 0, ...]: the stored 2-d prefix is always [0.6, 0.8].
        static let lengthVector: @Sendable ([Int32]) -> [Float] = { ids in
            [3, 4, Float(ids.count)] + [Float](repeating: 0, count: 5)
        }

        func load() async throws {}
        var maximumSequenceLength: Int { 16 }
        func embed(tokenIDs: [Int32]) async throws -> [Float] { output(tokenIDs) }
        func embed(batch: [[Int32]]) async throws -> [[Float]] {
            batches.withLock { $0.append(batch) }
            return batch.map(output)
        }
        func unload() async {}
    }

    static func model(
        tokenizer: CharacterTokenizer = CharacterTokenizer(),
        network: FakeNetwork = FakeNetwork(),
        version: String = "fake-2d-int8-r1+L16@000000000000",
        signposter: Signposter = .disabled(.memory)
    ) -> TextEmbeddingModel {
        TextEmbeddingModel(
            spec: spec, modelVersion: version, tokenizer: tokenizer, network: network, maximumTokens: 16,
            signposter: signposter)
    }

    // MARK: A real bundle around the tiny Core ML fixture

    /// A tokenizer for the tiny model's 10-row table: `<bos> $A <eos>`,
    /// spaces as `▁`, merges `a b` and `c d`.
    static let tinyTokenizerJSON = #"""
        {"version": "1.0",
         "added_tokens": [
           {"id": 0, "content": "<pad>", "special": true},
           {"id": 1, "content": "<eos>", "special": true},
           {"id": 2, "content": "<bos>", "special": true}],
         "normalizer": {"type": "Replace", "pattern": {"String": " "}, "content": "▁"},
         "pre_tokenizer": {"type": "Split", "pattern": {"String": " "}, "behavior": "MergedWithPrevious", "invert": false},
         "post_processor": {"type": "TemplateProcessing",
           "single": [{"SpecialToken": {"id": "<bos>", "type_id": 0}}, {"Sequence": {"id": "A", "type_id": 0}},
                      {"SpecialToken": {"id": "<eos>", "type_id": 0}}],
           "special_tokens": {"<bos>": {"id": "<bos>", "ids": [2], "tokens": ["<bos>"]},
                              "<eos>": {"id": "<eos>", "ids": [1], "tokens": ["<eos>"]}}},
         "model": {"type": "BPE", "fuse_unk": false, "byte_fallback": false,
           "vocab": {"<pad>": 0, "<eos>": 1, "<bos>": 2, "a": 3, "b": 4, "c": 5, "d": 6, "▁": 7, "ab": 8, "cd": 9},
           "merges": [["a", "b"], ["c", "d"]]}}
        """#

    static func tinyMetadata(table: TokenEmbeddingTable.Format) -> TextEmbeddingBundle.Metadata {
        TextEmbeddingBundle.Metadata(
            spec: "tiny-split", name: "TinySplitEmbedding",
            source: .init(repo: "blau/tiny-split", revision: "feedfacecafebeef0000", license: "none"),
            model: "TinySplitEmbedding.mlpackage", inputs: ["inputs_embeds", "attention_mask"],
            tokenEmbeddings: .init(
                file: "TinySplitEmbedding.token-embeddings.\(table.fileExtension)", dtype: table.rawValue,
                vocabularySize: 10, width: 4),
            output: "embedding", sequenceLengths: [8], fullDimensions: 4, storedDimensions: 2, pooling: "mean",
            queryPrompt: "ab ", documentPrompt: "", computePrecision: "fp32", weights: "none",
            tokenizer: "tokenizer.json")
    }

    /// A temporary bundle directory: the tiny Core ML model, its table
    /// (float16, or quantized to int8), the tokenizer and the metadata.
    static func makeTinyBundle(table format: TokenEmbeddingTable.Format = .float16) throws -> URL {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures/CoreML", withExtension: nil))
        let directory = FileManager.default.temporaryDirectory.appending(path: "tiny-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appending(path: "TinySplitEmbedding.mlpackage"),
            to: directory.appending(path: "TinySplitEmbedding.mlpackage"))
        let tableName = "TinySplitEmbedding.token-embeddings.\(format.fileExtension)"
        switch format {
        case .float16:
            try FileManager.default.copyItem(
                at: fixtures.appending(path: "TinySplitEmbedding.token-embeddings.f16"),
                to: directory.appending(path: tableName))
        case .int8:
            // Row i = [i, i + 0.5, -i, 1], one float32 scale per row.
            var bytes: [UInt8] = []
            for i in 0..<10 {
                let values: [Float] = [Float(i), Float(i) + 0.5, -Float(i), 1]
                let scale = values.map(abs).max()! / 127
                bytes += withUnsafeBytes(of: scale.bitPattern.littleEndian, Array.init)
                bytes += values.map { UInt8(bitPattern: Int8(($0 / scale).rounded())) }
            }
            try Data(bytes).write(to: directory.appending(path: tableName))
        }
        try Data(tinyTokenizerJSON.utf8).write(to: directory.appending(path: "tokenizer.json"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(tinyMetadata(table: format))
            .write(to: directory.appending(path: TextEmbeddingBundle.metadataFileName))
        return directory
    }
}
