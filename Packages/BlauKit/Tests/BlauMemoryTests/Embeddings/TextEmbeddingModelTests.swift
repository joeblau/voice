import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Synchronization
import Testing

#if canImport(CoreML)
    import CoreML
#endif

@Suite("Text embedding model")
struct TextEmbeddingModelTests {
    typealias Support = TextEmbeddingTestSupport

    @Test func promptsQueriesAndDocumentsDifferently() async throws {
        let tokenizer = Support.CharacterTokenizer()
        let model = Support.model(tokenizer: tokenizer)
        _ = try await model.embed("when did I start?", as: .query)
        _ = try await model.embed(["first run", "second run"], as: .document)
        #expect(
            tokenizer.texts.withLock { $0 } == [
                "query: when did I start?", "passage: first run", "passage: second run",
            ])
        #expect(model.prompted("x", as: .query) == "query: x")
        #expect(model.tokenCount(of: "abc", as: .document) == "passage: abc".count)
    }

    /// Keep the Matryoshka prefix, L2-normalize, int8 with one scale.
    @Test func storesTheNormalizedInt8Prefix() async throws {
        let model = Support.model(version: "fake-v1")
        let embedding = try await model.embed("hello", as: .document)
        // Network output [3, 4, ...] → prefix [0.6, 0.8] → codes [95, 127].
        #expect(embedding.codes == [95, 127])
        #expect(abs(embedding.scale - 0.8 / 127) < 1e-7)
        #expect(embedding.dimensions == 2)
        #expect(embedding.modelVersion == "fake-v1")
        #expect(embedding.tokenCount == "passage: hello".count)
        let vector = embedding.vector
        #expect(abs(vector[0] - 0.6) < 0.01 && abs(vector[1] - 0.8) < 0.01)
        #expect(!embedding.isZero)
    }

    @Test func embedsInBatchesOf32WithOneSignpostEach() async throws {
        let network = Support.FakeNetwork()
        let recording = RecordingSignpostBackend()
        let model = Support.model(network: network, signposter: Signposter(category: .memory, backend: recording))
        let texts = (0..<70).map { "chunk \($0)" }
        let embeddings = try await model.embed(texts, as: .document)

        #expect(embeddings.count == 70)
        #expect(network.batches.withLock { $0.map(\.count) } == [32, 32, 6])
        // Order is kept: each vector's third component is its length.
        let lengths = network.batches.withLock { $0.flatMap { $0.map(\.count) } }
        #expect(lengths == texts.map { min(16, "passage: \($0)".count) })
        #expect(recording.completedIntervals == ["memory.embed", "memory.embed", "memory.embed"])
        #expect(recording.openIntervals.isEmpty)
        let messages = recording.endMessages(of: "memory.embed")
        #expect(messages.first?.hasPrefix("32 texts, ") == true)
        #expect(messages.last?.hasPrefix("6 texts, ") == true)

        let statistics = await model.statistics
        #expect(statistics.texts == 70)
        #expect(statistics.batches == 3)
        #expect(statistics.lastBatchDuration != nil)
        #expect(try await model.embed([], as: .query).isEmpty)
    }

    @Test func reportsTruncation() async throws {
        let model = Support.model()
        let short = try await model.embed("ok", as: .document)
        let long = try await model.embed(String(repeating: "x", count: 40), as: .document)
        #expect(!short.wasTruncated)
        #expect(long.tokenCount == 16)
        #expect(long.truncatedTokens == "passage: ".count + 40 - 16)
        #expect(await model.statistics.truncatedTexts == 1)
        #expect(model.tokenCount(of: String(repeating: "x", count: 40), as: .document) == 49)
    }

    @Test func nonFiniteOutputsBecomeZeroVectors() async throws {
        let network = Support.FakeNetwork { ids in
            ids.count == "passage: bad".count ? [.nan, 1] + [Float](repeating: 0, count: 6) : [1, 0, 0, 0, 0, 0, 0, 0]
        }
        let model = Support.model(network: network)
        let embeddings = try await model.embed(["good", "bad"], as: .document)
        #expect(!embeddings[0].isZero)
        #expect(embeddings[1].isZero)
        #expect(embeddings[1].codes == [0, 0])
        #expect(await model.statistics.nonFiniteVectors == 1)
        #expect(embeddings[0].cosineSimilarity(to: embeddings[1]) == 0)
    }

    @Test func rejectsOutputOfTheWrongWidth() async throws {
        let model = Support.model(network: Support.FakeNetwork { _ in [1, 2, 3] })
        await #expect(throws: TextEmbeddingModel.Failure.unexpectedWidth(expected: 8, got: 3)) {
            try await model.embed("x", as: .query)
        }
    }

    @Test func comparesOnlyVectorsOfTheSameModel() {
        let a = TextEmbedding(codes: [127, 0], scale: 1, modelVersion: "m1", tokenCount: 3)
        let b = TextEmbedding(codes: [127, 0], scale: 1, modelVersion: "m2", tokenCount: 3)
        let c = TextEmbedding(codes: [0, 127], scale: 1, modelVersion: "m1", tokenCount: 3)
        #expect(a.cosineSimilarity(to: a) == 1)
        #expect(a.cosineSimilarity(to: c) == 0)
        #expect(a.cosineSimilarity(to: b) == nil)
    }

    #if canImport(CoreML)
        /// The whole production path on the tiny Core ML fixture: bundle
        /// metadata, tokenizer.json, token table (float16 and int8), Core ML,
        /// Matryoshka prefix and int8. The model outputs the masked mean of
        /// its input rows, row i = [i, i + 0.5, -i, 1], so every number is
        /// predictable.
        @Test(arguments: [TokenEmbeddingTable.Format.float16, .int8])
        func loadsAnInstalledBundle(table: TokenEmbeddingTable.Format) async throws {
            let directory = try Support.makeTinyBundle(table: table)
            defer { try? FileManager.default.removeItem(at: directory) }
            let bundle = try TextEmbeddingBundle(directory: directory)
            let model = try await TextEmbeddingModel.load(
                bundle: bundle, revision: "0123456789abcdef0123", computeUnits: .cpuOnly,
                signposter: .disabled(.memory))

            #expect(model.maximumTokens == 8)
            #expect(model.storedDimensions == 2)
            let tableTag = table == .int8 ? "ti8" : "tf16"
            #expect(model.modelVersion == "tiny-split-2d-int8-r1+fp32.\(tableTag).L8@0123456789ab")

            // "cd a" → "cd▁a" → [<bos>, cd, ▁, a, <eos>] = rows [2, 9, 7, 3, 1]:
            // mean i = 4.4 → [4.4, 4.9]. The query adds the prompt "ab ":
            // [2, ab, ▁, cd, 1] = [2, 8, 7, 9, 1] → mean 5.4 → [5.4, 5.9].
            let document = try await model.embed("cd a", as: .document)
            let query = try await model.embed("cd", as: .query)
            #expect(document.tokenCount == 5)
            #expect(query.tokenCount == 5)
            func expectUnit(_ embedding: TextEmbedding, _ x: Float, _ y: Float) {
                let norm = (x * x + y * y).squareRoot()
                let vector = embedding.vector
                #expect(abs(vector[0] - x / norm) < 0.02, "\(vector)")
                #expect(abs(vector[1] - y / norm) < 0.02, "\(vector)")
            }
            expectUnit(document, 4.4, 4.9)
            expectUnit(query, 5.4, 5.9)
            let similarity = try #require(document.cosineSimilarity(to: query))
            #expect(similarity > 0.99)

            // Longer than the model's 8 tokens: cut, keeping <bos> and <eos>.
            let long = try await model.embed("a b c d a b c d", as: .document)
            #expect(long.tokenCount == 8)
            #expect(long.wasTruncated)
            #expect(model.tokenCount(of: "a b c d a b c d", as: .document) > 8)
        }
    #endif
}

@Suite("Text embedding bundle")
struct TextEmbeddingBundleTests {
    typealias Support = TextEmbeddingTestSupport

    /// What `convert_coreml.py` wrote for Qwen3 before #60 added `spec`.
    static let qwenMetadata = TextEmbeddingBundle.Metadata(
        spec: nil, name: "Qwen3Embedding06B",
        source: .init(repo: "Qwen/Qwen3-Embedding-0.6B", revision: "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"),
        model: "Qwen3Embedding06B.mlmodelc", inputs: ["inputs_embeds", "attention_mask"],
        tokenEmbeddings: .init(
            file: "Qwen3Embedding06B.token-embeddings.i8", dtype: "int8", vocabularySize: 151_669, width: 1_024),
        output: "embedding", sequenceLengths: [128], fullDimensions: 1_024, storedDimensions: 256,
        pooling: "last-token", queryPrompt: TextEmbeddingModelSpec.qwen3Embedding06B.queryPrompt, documentPrompt: "",
        computePrecision: "fp16", weights: "int8")

    static func directory(with files: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: directory.appending(path: file))
        }
        return directory
    }

    @Test func recognizesAKnownModelAndNamesItsVectors() throws {
        let directory = try Self.directory(with: [
            "Qwen3Embedding06B.mlmodelc", "tokenizer.json", "Qwen3Embedding06B.token-embeddings.i8",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try TextEmbeddingBundle(directory: directory, metadata: Self.qwenMetadata)
        #expect(bundle.spec == .qwen3Embedding06B)
        #expect(bundle.maximumTokens == 128)
        #expect(bundle.tokenEmbeddingsURL?.lastPathComponent == "Qwen3Embedding06B.token-embeddings.i8")
        #expect(
            bundle.modelVersion(revision: nil) == "qwen3-embedding-0.6b-256d-int8-r1+fp16.wint8.ti8.L128@97b0c614be4d")
        #expect(bundle.modelVersion(revision: "abcdef0123456789").hasSuffix("@abcdef012345"))

        var gemma = Self.qwenMetadata
        gemma.spec = "embeddinggemma-300m"
        gemma.pooling = "mean"
        gemma.fullDimensions = 768
        gemma.queryPrompt = "task: search result | query: "
        gemma.documentPrompt = "title: none | text: "
        #expect(try TextEmbeddingBundle(directory: directory, metadata: gemma).spec == .embeddingGemma300M)
    }

    @Test func refusesMetadataThatDisagreesWithTheSpec() throws {
        let directory = try Self.directory(with: [
            "Qwen3Embedding06B.mlmodelc", "tokenizer.json", "Qwen3Embedding06B.token-embeddings.i8",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        var metadata = Self.qwenMetadata
        metadata.queryPrompt = "Query: "
        metadata.storedDimensions = 128
        #expect(
            throws: TextEmbeddingBundle.Failure.specMismatch("qwen3-embedding-0.6b: query prompt, stored width")
        ) {
            try TextEmbeddingBundle(directory: directory, metadata: metadata)
        }
        metadata = Self.qwenMetadata
        metadata.pooling = "cls"
        #expect(throws: TextEmbeddingBundle.Failure.unsupported("pooling cls")) {
            try TextEmbeddingBundle(directory: directory, metadata: metadata)
        }
        metadata = Self.qwenMetadata
        metadata.tokenEmbeddings?.dtype = "int4"
        #expect(throws: TextEmbeddingBundle.Failure.unsupported("token table dtype int4")) {
            try TextEmbeddingBundle(directory: directory, metadata: metadata)
        }
    }

    @Test func refusesAnIncompleteBundle() throws {
        let directory = try Self.directory(with: ["Qwen3Embedding06B.mlmodelc", "tokenizer.json"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: TextEmbeddingBundle.Failure.missingFile("Qwen3Embedding06B.token-embeddings.i8")) {
            try TextEmbeddingBundle(directory: directory, metadata: Self.qwenMetadata)
        }
        #expect(throws: TextEmbeddingBundle.Failure.self) { try TextEmbeddingBundle(directory: directory) }
    }

    @Test func readsTheMetadataFile() throws {
        let directory = try Support.makeTinyBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try TextEmbeddingBundle(directory: directory)
        #expect(bundle.metadata == Support.tinyMetadata(table: .float16))
        // An unknown model gets a spec built from its metadata.
        #expect(bundle.spec.id == "tiny-split")
        #expect(bundle.spec.queryPrompt == "ab ")
        #expect(bundle.spec.storedDimensions == 2)
        #expect(bundle.spec.isMatryoshka)
    }
}
