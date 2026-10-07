import BlauCore
import BlauMemory
import BlauTelemetry
import BlauTopics
import Foundation
import Testing

/// The topic segmenter (#52) running on the shared text-embedding service
/// (#60) through `SharedTextEmbedder`, the way the composition root wires
/// them.
///
/// The shared path adds what the segmenter never saw before: the document
/// prompt, the stored-width cut, int8 quantization and dequantization. To
/// check that this path alone doesn't change topic decisions, these tests
/// put the reference `LexicalTextEmbedder` behind it (as the "network") and
/// require the same boundaries as the reference on every scripted transcript.
@Suite("Topic segmentation on the shared embedding service")
struct SharedEmbedderTopicSegmentationTests {
    /// Passes the text through as UTF-8 byte "tokens".
    struct ByteTokenizer: TextTokenizing {
        func encode(_ text: String, maximumLength: Int?) -> HuggingFaceTokenizer.Encoding {
            HuggingFaceTokenizer.Encoding(ids: text.utf8.map { Int32($0) })
        }
    }

    /// Decodes the byte tokens, drops the document prompt and returns the
    /// lexical embedding of the text.
    struct LexicalNetwork: TokenEmbeddingModel {
        static let prompt = "passage: "
        let lexical = LexicalTextEmbedder(dimension: 1_024)

        func load() async throws {}
        var maximumSequenceLength: Int { 1 << 20 }
        func embed(tokenIDs: [Int32]) async throws -> [Float] {
            let text = String(decoding: tokenIDs.map { UInt8($0) }, as: UTF8.self)
            #expect(text.hasPrefix(Self.prompt))
            return try await lexical.embed(String(text.dropFirst(Self.prompt.count)))
        }
        func unload() async {}
    }

    static func sharedLexicalEmbedder() -> SharedTextEmbedder {
        let spec = TextEmbeddingModelSpec(
            id: "lexical-through-service", displayName: "Lexical", source: "BlauTopics", license: "n/a",
            queryPrompt: "query: ", documentPrompt: LexicalNetwork.prompt, fullDimensions: 1_024,
            storedDimensions: 1_024, maximumTokens: 1 << 20, pooling: .mean, isMatryoshka: false)
        let model = TextEmbeddingModel(
            spec: spec, modelVersion: "lexical-through-service-1024d-int8", tokenizer: ByteTokenizer(),
            network: LexicalNetwork(), maximumTokens: 1 << 20, signposter: .disabled(.memory))
        return SharedTextEmbedder(model: model)
    }

    static func boundaries(of transcript: ScriptedTranscript, embedder: any TextEmbedder) async throws -> [Int] {
        let segmenter = StreamingTopicSegmenter(embedder: embedder, signposter: .disabled(.topics))
        for unit in transcript.units() {
            _ = try await segmenter.append(unit)
        }
        return await segmenter.boundaries.map(\.unitIndex)
    }

    @Test(arguments: ScriptedTranscript.all)
    func findsTheSameBoundariesAsTheReference(transcript: ScriptedTranscript) async throws {
        let shared = Self.sharedLexicalEmbedder()
        #expect(shared.modelIdentifier == "lexical-through-service-1024d-int8")
        let reference = try await Self.boundaries(of: transcript, embedder: LexicalTextEmbedder())
        let found = try await Self.boundaries(of: transcript, embedder: shared)
        #expect(found == reference, "reference \(reference), through the service \(found)")
        #expect(found == transcript.boundaries, "labelled \(transcript.boundaries), found \(found)")
    }

    /// The segmenter's other entry point, for an exchange the memory indexer
    /// has already embedded: the stored int8 vector, dequantized.
    @Test func acceptsVectorsTheIndexerAlreadyComputed() async throws {
        let shared = Self.sharedLexicalEmbedder()
        let transcript = ScriptedTranscript.threeTopics
        let units = transcript.units()
        let stored = try await shared.model.embed(units.map(\.text), as: .document)
        let segmenter = StreamingTopicSegmenter(embedder: shared, signposter: .disabled(.topics))
        for (unit, embedding) in zip(units, stored) {
            _ = try await segmenter.append(unit, embedding: embedding.vector)
        }
        #expect(await segmenter.boundaries.map(\.unitIndex) == transcript.boundaries)
    }
}

#if canImport(CoreML)
    /// The scripted transcripts segmented with a real converted embedding
    /// model through the shared service. Opt-in (the model isn't in the
    /// repository):
    ///
    ///     BLAU_TEXT_EMBEDDING_BUNDLE=<hosting folder> swift test --filter RealModelTopicSegmentationTests
    ///
    /// Reports Pk and WindowDiff per transcript with
    /// `TopicConfig.sharedEmbedding`; asserts what
    /// `NLContextualTextEmbedderTests` asserts for the embedder it replaces:
    /// the brief digression is never split out and the mean Pk stays at or
    /// below 0.25. `BLAU_TOPIC_MINIMUM_DEPTH` overrides the config's floor,
    /// for calibrating a new model.
    @Suite(
        "Topic segmentation on a real embedding model (BLAU_TEXT_EMBEDDING_BUNDLE)",
        .enabled(if: ProcessInfo.processInfo.environment["BLAU_TEXT_EMBEDDING_BUNDLE"] != nil),
        .serialized
    )
    struct RealModelTopicSegmentationTests {
        static var bundles: [URL] {
            (ProcessInfo.processInfo.environment["BLAU_TEXT_EMBEDDING_BUNDLE"] ?? "")
                .split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        }

        @Test(arguments: bundles)
        func segmentsTheScriptedTranscripts(directory: URL) async throws {
            let model = try await TextEmbeddingModel.load(bundle: TextEmbeddingBundle(directory: directory))
            let embedder = SharedTextEmbedder(model: model)
            var config = TopicConfig.sharedEmbedding
            if let depth = ProcessInfo.processInfo.environment["BLAU_TOPIC_MINIMUM_DEPTH"].flatMap(Double.init) {
                config.minimumDepth = depth
            }

            var rows: [String] = []
            var pkTotal = 0.0
            var resegmentedPkTotal = 0.0
            for transcript in ScriptedTranscript.all {
                let segmenter = StreamingTopicSegmenter(
                    embedder: embedder, config: config, signposter: .disabled(.topics))
                var depths: [Double] = []
                for unit in transcript.units() {
                    _ = try await segmenter.append(unit)
                }
                for gap in 1..<transcript.count {
                    if let score = await segmenter.gapScore(at: gap) { depths.append(score.depth) }
                }
                let found = await segmenter.boundaries.map(\.unitIndex)
                let pk = SegmentationMetrics.pk(
                    reference: transcript.boundaries, hypothesis: found, count: transcript.count)
                let windowDiff = SegmentationMetrics.windowDiff(
                    reference: transcript.boundaries, hypothesis: found, count: transcript.count)
                pkTotal += pk
                // Offline re-segmentation (#55) on the same vectors.
                let units = transcript.units()
                let resegmented = TopicResegmenter(
                    configuration: TopicResegmenter.Configuration.standard.matching(config)
                ).resegment(
                    embeddings: await segmenter.embeddings, timeRanges: units.map(\.timeRange), boundaries: found)
                let resegmentedPk = SegmentationMetrics.pk(
                    reference: transcript.boundaries, hypothesis: resegmented.boundaries, count: transcript.count)
                resegmentedPkTotal += resegmentedPk
                #expect(resegmentedPk <= pk + 1e-12, "\(transcript.name): re-segmentation made it worse")
                let deepest = depths.sorted(by: >).prefix(3).map { String(format: "%.3f", $0) }
                rows.append(
                    "| `\(transcript.name)` | \(transcript.boundaries) | \(found) | \(String(format: "%.2f", pk)) / \(String(format: "%.2f", windowDiff)) | \(deepest.joined(separator: ", ")) | \(resegmented.boundaries) (Pk \(String(format: "%.2f", resegmentedPk))) |"
                )
                if let digression = transcript.digression {
                    let span = digression.lowerBound...digression.upperBound
                    #expect(!found.contains { span.contains($0) }, "\(transcript.name): split the digression \(found)")
                }
            }
            let meanPk = pkTotal / Double(ScriptedTranscript.all.count)
            print(
                """
                ## Topics on \(model.modelVersion), minimumDepth \(config.minimumDepth)

                | Transcript | Reference | Found | Pk / WindowDiff | Deepest gaps | Re-segmented (#55) |
                | --- | --- | --- | --- | --- | --- |
                \(rows.joined(separator: "\n"))

                Mean Pk \(String(format: "%.3f", meanPk)), re-segmented \(
                    String(format: "%.3f", resegmentedPkTotal / Double(ScriptedTranscript.all.count)))
                """)
            #expect(meanPk <= 0.25)
        }
    }
#endif
