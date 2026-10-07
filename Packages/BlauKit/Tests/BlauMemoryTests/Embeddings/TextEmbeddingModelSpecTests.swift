import BlauMemory
import Foundation
import Testing

@Suite("Text embedding model spec")
struct TextEmbeddingModelSpecTests {
    @Test func chosenModelIsEmbeddingGemmaAt256DimensionsInt8() {
        let chosen = TextEmbeddingModelSpec.chosen
        #expect(chosen.id == "embeddinggemma-300m")
        #expect(chosen.storedDimensions == 256)
        #expect(chosen.isMatryoshka)
        #expect(chosen.vectorIdentifier == "embeddinggemma-300m-256d-int8-r1")
        #expect(TextEmbeddingModelSpec.candidates.first == chosen)
        #expect(Set(TextEmbeddingModelSpec.candidates.map(\.id)).count == TextEmbeddingModelSpec.candidates.count)
    }

    @Test func promptsFollowTheModelCards() {
        let gemma = TextEmbeddingModelSpec.embeddingGemma300M
        #expect(gemma.queryText("where is Biscuit's vet") == "task: search result | query: where is Biscuit's vet")
        #expect(gemma.documentText("Dr. Okafor") == "title: none | text: Dr. Okafor")
        let qwen = TextEmbeddingModelSpec.qwen3Embedding06B
        #expect(qwen.queryPrompt.hasPrefix("Instruct: ") && qwen.queryPrompt.hasSuffix("\nQuery:"))
        #expect(qwen.documentPrompt.isEmpty)
    }

    @Test func storedWidthNeverExceedsTheModel() {
        for spec in TextEmbeddingModelSpec.candidates {
            #expect(spec.storedDimensions <= spec.fullDimensions, "\(spec.id)")
            #expect(spec.maximumTokens > 0)
        }
    }

    @Test func storedVectorIsTheNormalizedQuantizedPrefix() {
        let spec = TextEmbeddingModelSpec.embeddingGemma300M
        let full = (0..<768).map { Float($0 < 256 ? 1 : 100) }
        let stored = spec.storedVector(fromFullOutput: full)
        #expect(stored.codes.count == 256)
        #expect(stored.codes.allSatisfy { $0 == 127 })
        #expect(abs(stored.scale * 127 - 1 / Float(256).squareRoot()) < 1e-6)
    }

    /// The Python scripts that produced the #59 numbers must embed with the
    /// same prompts as the app.
    @Test func promptsMatchTheEvaluationScripts() throws {
        let script = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/embeddings/candidates.py")
        let source = try String(contentsOf: script, encoding: .utf8)
        let gemma = TextEmbeddingModelSpec.embeddingGemma300M
        #expect(source.contains("query_prompt=\"\(gemma.queryPrompt)\""))
        #expect(source.contains("document_prompt=\"\(gemma.documentPrompt)\""))
        let instruction = TextEmbeddingModelSpec.qwen3Embedding06B.queryPrompt
            .replacingOccurrences(of: "Instruct: ", with: "").replacingOccurrences(of: "\nQuery:", with: "")
        let collapsed = source.replacingOccurrences(of: "\"\n    \"", with: "")
        #expect(collapsed.contains(instruction))
        for spec in TextEmbeddingModelSpec.candidates where spec.source.contains("/") {
            #expect(source.contains("repo=\"\(spec.source)\""), "\(spec.id)")
        }
    }
}

@Suite("Embedding model selection")
struct EmbeddingModelSelectionTests {
    typealias M = EmbeddingModelSelection.Measurements

    static let qwen = M(
        specID: "qwen3-embedding-0.6b", recallAt5: 0.82, nonFiniteOutputs: 0, deviceP95Milliseconds: 30,
        downloadBytes: 320_000_000)

    /// The verdict docs/benchmarks.md records for #59.
    @Test func recordedMeasurementsLeaveEmbeddingGemmaProvisional() throws {
        let selection = EmbeddingModelSelection()
        guard case .pending(let provisional, let missing) = selection.evaluate(EmbeddingModelSelection.measured)
        else {
            Issue.record("Expected pending")
            return
        }
        #expect(provisional == TextEmbeddingModelSpec.chosen.id)
        #expect(missing.contains("embeddinggemma-300m: Recall@5"))
        // Qwen3 is out on size until the budget changes or the table shrinks.
        let qwen = EmbeddingModelSelection.measured.first { $0.specID == "qwen3-embedding-0.6b" }
        #expect(selection.disqualifications(try #require(qwen)).count == 1)
        #expect(Set(EmbeddingModelSelection.measured.map(\.specID)) == Set(TextEmbeddingModelSpec.candidates.map(\.id)))
    }

    @Test func pendingWhileTheChosenModelIsUnmeasured() {
        let verdict = EmbeddingModelSelection().evaluate([M(specID: "embeddinggemma-300m"), Self.qwen])
        guard case .pending(let provisional, let missing) = verdict else {
            Issue.record("Expected pending, got \(verdict)")
            return
        }
        #expect(provisional == "embeddinggemma-300m")
        #expect(missing.contains("embeddinggemma-300m: Recall@5"))
        #expect(missing.contains("embeddinggemma-300m: Neural Engine numerics"))
    }

    @Test func smallerModelWinsWhenCloseEnough() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.80, nonFiniteOutputs: 0, deviceP95Milliseconds: 20,
            downloadBytes: 170_000_000)
        guard case .chosen(let id, _) = EmbeddingModelSelection().evaluate([gemma, Self.qwen]) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(id == "embeddinggemma-300m")
    }

    @Test func clearlyBetterModelWinsDespiteSize() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.70, nonFiniteOutputs: 0, deviceP95Milliseconds: 20,
            downloadBytes: 170_000_000)
        guard case .chosen(let id, _) = EmbeddingModelSelection().evaluate([gemma, Self.qwen]) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(id == "qwen3-embedding-0.6b")
    }

    @Test func nonFiniteOutputRulesAModelOut() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.85, nonFiniteOutputs: 12, deviceP95Milliseconds: 20,
            downloadBytes: 170_000_000)
        let selection = EmbeddingModelSelection()
        #expect(selection.disqualifications(gemma).count == 1)
        guard case .chosen(let id, let reasons) = selection.evaluate([gemma, Self.qwen]) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(id == "qwen3-embedding-0.6b")
        #expect(reasons.contains { $0.contains("non-finite") })
    }

    @Test func budgetsCanRuleOutEveryone() {
        let slow = M(
            specID: "qwen3-embedding-0.6b", recallAt5: 0.82, nonFiniteOutputs: 0, deviceP95Milliseconds: 90,
            downloadBytes: 1_200_000_000)
        guard case .noneQualifies(let reasons) = EmbeddingModelSelection().evaluate([slow]) else {
            Issue.record("Expected none to qualify")
            return
        }
        #expect(reasons.count == 2)
    }

    @Test func staticModelsSkipCoreMLCriteria() {
        let potion = M(
            specID: "potion-retrieval-32m", recallAt5: 0.62, deviceP95Milliseconds: 1, downloadBytes: 130_000_000,
            needsCoreMLModel: false)
        let selection = EmbeddingModelSelection()
        #expect(selection.missing(potion).isEmpty)
        #expect(selection.disqualifications(potion).isEmpty)
    }
}
