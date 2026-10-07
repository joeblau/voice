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
        // Only EmbeddingGemma's numbers hold the verdict: baselines don't take
        // part, and Qwen3 is already out on size.
        #expect(missing.allSatisfy { $0.hasPrefix("embeddinggemma-300m: ") })
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

    /// A candidate ruled out only by budgets is named as over budget, not
    /// dropped: raising a budget is the owner's call.
    @Test func budgetsCanRuleOutEveryone() {
        let slow = M(
            specID: "qwen3-embedding-0.6b", recallAt5: 0.82, nonFiniteOutputs: 0, deviceP95Milliseconds: 90,
            downloadBytes: 1_200_000_000)
        var selection = EmbeddingModelSelection()
        selection.fallback = nil
        guard case .overBudget(let id, let reasons, let missing) = selection.evaluate([slow]) else {
            Issue.record("Expected over budget")
            return
        }
        #expect(id == "qwen3-embedding-0.6b")
        #expect(reasons.count == 2)
        #expect(missing.isEmpty)
    }

    /// The recorded numbers once EmbeddingGemma's arrive.
    static func measured(replacingGemmaWith gemma: M) -> [M] {
        EmbeddingModelSelection.measured.map { $0.specID == gemma.specID ? gemma : $0 }
    }

    /// Round-2 review: EmbeddingGemma misses only the latency budget, and
    /// Qwen3 is twice as slow and 2.5x larger. Falling back to Qwen3 would
    /// recommend a model that is worse on the very budget EmbeddingGemma
    /// broke, so the rule names EmbeddingGemma as over budget instead.
    @Test func slowEmbeddingGemmaDoesNotFallBackToASlowerQwen3() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.80, nonFiniteOutputs: 0, deviceP95Milliseconds: 60,
            downloadBytes: 300_000_000)
        let measured = Self.measured(replacingGemmaWith: gemma).map { m in
            var m = m
            if m.specID == "qwen3-embedding-0.6b" { m.deviceP95Milliseconds = 120 }
            return m
        }
        let verdict = EmbeddingModelSelection().evaluate(measured)
        guard case .overBudget(let id, let reasons, let missing) = verdict else {
            Issue.record("Expected EmbeddingGemma over budget, got \(verdict)")
            return
        }
        #expect(id == "embeddinggemma-300m")
        #expect(
            reasons == [
                "embeddinggemma-300m: iPhone p95 60.0 ms > 50.0 ms",
                "qwen3-embedding-0.6b: iPhone p95 120.0 ms > 50.0 ms",
                "qwen3-embedding-0.6b: download 753 MB > 400 MB",
            ])
        #expect(missing.isEmpty)

        // Raising the latency budget is what adopts EmbeddingGemma.
        var raised = EmbeddingModelSelection()
        raised.maximumDeviceP95Milliseconds = 200
        guard case .chosen(let chosen, _) = raised.evaluate(measured) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(chosen == "embeddinggemma-300m")
    }

    /// The same holds for the download budget, and before EmbeddingGemma's
    /// Recall@5 is measured: the verdict lists what is still missing.
    @Test func embeddingGemmaOverTheDownloadBudgetIsNamedWithItsMissingNumbers() {
        let gemma = M(specID: "embeddinggemma-300m", nonFiniteOutputs: 0, downloadBytes: 450_000_000)
        let verdict = EmbeddingModelSelection().evaluate(Self.measured(replacingGemmaWith: gemma))
        guard case .overBudget(let id, let reasons, let missing) = verdict else {
            Issue.record("Expected EmbeddingGemma over budget, got \(verdict)")
            return
        }
        #expect(id == "embeddinggemma-300m")
        #expect(reasons.contains("embeddinggemma-300m: download 450 MB > 400 MB"))
        #expect(missing == ["embeddinggemma-300m: Recall@5", "embeddinggemma-300m: iPhone latency"])
    }

    /// EmbeddingGemma over budget while Qwen3 has non-finite vectors: the
    /// verdict still names EmbeddingGemma, not `.noneQualifies`.
    @Test func overBudgetEmbeddingGemmaWithANonFiniteFallback() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.80, nonFiniteOutputs: 0, deviceP95Milliseconds: 60,
            downloadBytes: 300_000_000)
        let qwen = M(
            specID: "qwen3-embedding-0.6b", recallAt5: 0.8, nonFiniteOutputs: 1, deviceP95Milliseconds: 20,
            downloadBytes: 300_000_000)
        guard case .overBudget(let id, _, _) = EmbeddingModelSelection().evaluate([gemma, qwen]) else {
            Issue.record("Expected over budget")
            return
        }
        #expect(id == "embeddinggemma-300m")
    }

    /// docs/benchmarks.md, "Finishing EmbeddingGemma": a passing
    /// EmbeddingGemma is chosen even though the baselines have no iPhone
    /// latency and Qwen3 is over the download budget.
    @Test func fullyMeasuredEmbeddingGemmaIsChosenOverTheRecordedNumbers() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.78, nonFiniteOutputs: 0, deviceP95Milliseconds: 20,
            downloadBytes: 300_000_000)
        let verdict = EmbeddingModelSelection().evaluate(Self.measured(replacingGemmaWith: gemma))
        guard case .chosen(let id, let reasons) = verdict else {
            Issue.record("Expected a choice, got \(verdict)")
            return
        }
        #expect(id == "embeddinggemma-300m")
        #expect(reasons.contains { $0.hasPrefix("qwen3-embedding-0.6b: download 753 MB") })
        #expect(!reasons.contains { $0.contains("potion") || $0.contains("nl-contextual") })
    }

    /// docs/benchmarks.md, decision 2: if EmbeddingGemma's Neural Engine
    /// vectors aren't finite, the rule falls back to Qwen3 (not to potion) and says
    /// that the download budget has to be raised for it.
    @Test func nonFiniteEmbeddingGemmaFallsBackToQwen3() {
        let gemma = M(specID: "embeddinggemma-300m", nonFiniteOutputs: 3)
        let verdict = EmbeddingModelSelection().evaluate(Self.measured(replacingGemmaWith: gemma))
        guard case .fallback(let id, let reasons, let missing) = verdict else {
            Issue.record("Expected the Qwen3 fallback, got \(verdict)")
            return
        }
        #expect(id == "qwen3-embedding-0.6b")
        #expect(
            reasons == [
                "embeddinggemma-300m: 3 non-finite vectors on the Neural Engine",
                "qwen3-embedding-0.6b: download 753 MB > 400 MB",
            ])
        #expect(missing == ["qwen3-embedding-0.6b: iPhone latency"])
    }

    /// The same failure once the owner raises the budget for Qwen3 and its
    /// iPhone latency lands: Qwen3 is chosen outright.
    @Test func raisingTheBudgetMakesTheFallbackTheChoice() {
        let gemma = M(specID: "embeddinggemma-300m", nonFiniteOutputs: 3)
        let measured = Self.measured(replacingGemmaWith: gemma).map { m in
            var m = m
            if m.specID == "qwen3-embedding-0.6b" { m.deviceP95Milliseconds = 30 }
            return m
        }
        var selection = EmbeddingModelSelection()
        selection.maximumDownloadBytes = 800_000_000
        guard case .chosen(let id, _) = selection.evaluate(measured) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(id == "qwen3-embedding-0.6b")
    }

    @Test func fallbackWithNonFiniteVectorsLeavesNothing() {
        let gemma = M(specID: "embeddinggemma-300m", nonFiniteOutputs: 3)
        let qwen = M(
            specID: "qwen3-embedding-0.6b", recallAt5: 0.8, nonFiniteOutputs: 1, deviceP95Milliseconds: 20,
            downloadBytes: 300_000_000)
        guard case .noneQualifies(let reasons) = EmbeddingModelSelection().evaluate([gemma, qwen]) else {
            Issue.record("Expected none to qualify")
            return
        }
        #expect(reasons.count == 2)
    }

    /// Baselines and the CPU fallback are never selected and never hold the
    /// verdict at `.pending`, however good their numbers.
    @Test func baselinesNeitherWinNorBlock() {
        let gemma = M(
            specID: "embeddinggemma-300m", recallAt5: 0.70, nonFiniteOutputs: 0, deviceP95Milliseconds: 20,
            downloadBytes: 300_000_000)
        let potion = M(specID: "potion-retrieval-32m", role: .cpuFallback, recallAt5: 0.95, needsCoreMLModel: false)
        let apple = M(specID: "nl-contextual-embedding", role: .baseline, needsCoreMLModel: false)
        let selection = EmbeddingModelSelection()
        #expect(selection.missing(potion).isEmpty)
        #expect(selection.missing(apple).isEmpty)
        guard case .chosen(let id, _) = selection.evaluate([gemma, potion, apple]) else {
            Issue.record("Expected a choice")
            return
        }
        #expect(id == "embeddinggemma-300m")
        #expect(
            EmbeddingModelSelection.measured.filter { $0.role == .memoryCandidate }.map(\.specID) == [
                "embeddinggemma-300m", "qwen3-embedding-0.6b",
            ])
    }

    @Test func measurementsDecodeWithoutARole() throws {
        let json = Data(#"{"specID": "qwen3-embedding-0.6b", "recallAt5": 0.8}"#.utf8)
        let decoded = try JSONDecoder().decode(M.self, from: json)
        #expect(decoded == M(specID: "qwen3-embedding-0.6b", recallAt5: 0.8))
        let baseline = M(specID: "nl-contextual-embedding", role: .baseline, needsCoreMLModel: false)
        #expect(try JSONDecoder().decode(M.self, from: JSONEncoder().encode(baseline)) == baseline)
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
