#if canImport(NaturalLanguage)
    import BlauTelemetry
    import BlauTopics
    import Foundation
    import NaturalLanguage
    import Testing

    /// Exercises the real `NLContextualEmbedding` model. Opt-in with
    /// `BLAU_DEVICE_TESTS=1`, because the model's assets are an OS download
    /// that may not be on the machine (these tests never trigger it: they
    /// skip when the assets are missing).
    @Suite(
        "NLContextualTextEmbedder (BLAU_DEVICE_TESTS=1)",
        .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
        .serialized
    )
    struct NLContextualTextEmbedderTests {
        /// The embedder, or `nil` (and a recorded note) when the OS has no
        /// model or its assets aren't downloaded.
        private func makeEmbedder() async -> NLContextualTextEmbedder? {
            guard let embedder = NLContextualTextEmbedder(language: .english) else {
                Issue.record("No contextual embedding model for English on this OS")
                return nil
            }
            guard await embedder.hasAvailableAssets else {
                print("NLContextualTextEmbedder: assets not on this machine; skipping")
                return nil
            }
            return embedder
        }

        @Test func embedsToTheModelsDimension() async throws {
            guard let embedder = await makeEmbedder() else { return }
            let vector = try await embedder.embed("Let's bake sourdough bread this weekend.")
            #expect(vector.count == embedder.dimension)
            let isFinite = vector.allSatisfy { $0.isFinite }
            #expect(isFinite)
            let hasSignal = vector.contains { $0 != 0 }
            #expect(hasSignal)
            let empty = try await embedder.embed("")
            let isZero = empty.allSatisfy { $0 == 0 }
            #expect(isZero)
        }

        @Test func isDeterministic() async throws {
            guard let embedder = await makeEmbedder() else { return }
            let text = "How long should my long run be each week?"
            let first = try await embedder.embed(text)
            let second = try await embedder.embed(text)
            #expect(first == second)
        }

        /// The scripted transcripts segmented with the real model. Reports
        /// Pk and WindowDiff per transcript; asserts only that the brief
        /// digression isn't split out and the mean Pk stays reasonable.
        @Test func segmentsTheScriptedTranscripts() async throws {
            guard let embedder = await makeEmbedder() else { return }
            var pkTotal = 0.0
            for transcript in ScriptedTranscript.all {
                let segmenter = StreamingTopicSegmenter(
                    embedder: embedder,
                    config: .contextualEmbedding,
                    signposter: .disabled(.topics)
                )
                for unit in transcript.units() {
                    _ = try await segmenter.append(unit)
                }
                let found = await segmenter.boundaries.map(\.unitIndex)
                let pk = SegmentationMetrics.pk(
                    reference: transcript.boundaries,
                    hypothesis: found,
                    count: transcript.count
                )
                let windowDiff = SegmentationMetrics.windowDiff(
                    reference: transcript.boundaries,
                    hypothesis: found,
                    count: transcript.count
                )
                pkTotal += pk
                print(
                    "NLContextual \(transcript.name): reference \(transcript.boundaries) found \(found) Pk \(pk) WindowDiff \(windowDiff)"
                )
                if let digression = transcript.digression {
                    let span = digression.lowerBound...digression.upperBound
                    let splitDigression = found.contains { span.contains($0) }
                    #expect(!splitDigression)
                }
            }
            let meanPk = pkTotal / Double(ScriptedTranscript.all.count)
            print("NLContextual mean Pk \(meanPk)")
            #expect(meanPk <= 0.25)
        }
    }
#endif
