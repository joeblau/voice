import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

@Suite("ASR evaluation report and gate")
struct ASREvaluationReportTests {
    static let device = BenchmarkDevice(
        modelIdentifier: "Mac15,8", marketingName: nil, chip: "Apple M3 Max", operatingSystem: "macOS 27.2",
        physicalMemoryBytes: 64 << 30, activeProcessorCount: 16, isSimulator: false)

    /// Two engines over a clean and a TV fixture.
    func report() async throws -> ASREvaluationReport {
        let clean = syntheticFixture(id: "clean-1", category: "clean", seconds: 4, utterances: [("hello there", 1, 2)])
        let tv = syntheticFixture(id: "tv-1", category: "tv", seconds: 4, utterances: [("good night | all", 1, 2)])
        func final(_ text: String, at position: Double, compute: Duration = .milliseconds(50)) -> ASRTimedEvent {
            ASRTimedEvent(
                kind: .final, text: text, range: 16_000..<32_000, audioPosition: Int64(position * 16_000),
                computeLag: compute)
        }
        func partial(at position: Double) -> ASRTimedEvent {
            ASRTimedEvent(
                kind: .partial, text: "x", range: 16_000..<20_000, audioPosition: Int64(position * 16_000),
                computeLag: .milliseconds(10))
        }
        let streaming = PreparedEngine(
            id: "streaming",
            [
                "clean-1": ASREngineTranscript(
                    events: [partial(at: 1.4), final("hello there", at: 3)], computeTime: .milliseconds(200)),
                "tv-1": ASREngineTranscript(
                    events: [partial(at: 1.6), final("good night all and the news", at: 3.2)],
                    computeTime: .milliseconds(200)),
            ])
        let offline = PreparedEngine(
            id: "offline", kind: .offline,
            [
                "clean-1": ASREngineTranscript(
                    events: [final("Hello there.", at: 2.2)], computeTime: .milliseconds(80)),
                "tv-1": ASREngineTranscript(
                    events: [final("Good night, all.", at: 2.2)], computeTime: .milliseconds(80)),
            ])
        let dataset = try ASREvaluationDataset(name: "unit", consent: "synthetic", fixtures: [clean, tv])
        return try await ASREvaluator(dataset: dataset).run(
            [streaming, offline], device: Self.device, commit: "deadbeef")
    }

    @Test func roundTripsThroughJSON() async throws {
        let report = try await report()
        let decoded = try ASREvaluationReport.decode(report.jsonData())
        #expect(decoded.engines == report.engines)
        #expect(decoded.dataset == report.dataset)
        #expect(decoded.device == report.device)
        #expect(decoded.commit == "deadbeef")
        #expect(abs(decoded.generatedAt.timeIntervalSince(report.generatedAt)) < 1)
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 1"))
        // The rates are stored too, so the artifact can be read without
        // recomputing them.
        #expect(json.contains("\"wordErrorRate\" : 0.6"))
        #expect(json.contains("\"realTimeFactor\""))
    }

    @Test func printsATablePerEngineWithARowPerCategory() async throws {
        let table = try await report().table()
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("ASR evaluation: unit, 2 fixtures, 2 utterances"))
        #expect(lines.contains { $0.hasPrefix("streaming: Prepared streaming") })
        #expect(lines.contains { $0.hasPrefix("offline: Prepared offline") })
        let headers = lines.filter { $0.hasPrefix("Category") }
        #expect(headers.count == 2)
        #expect(
            headers[0].contains("WER") && headers[0].contains("First partial p50 / p95") && headers[0].contains("RTF"))
        // Columns line up: every row of a table is as wide as its header.
        let streamingRows = lines.drop { !$0.hasPrefix("Category") }.prefix(4)
        #expect(Set(streamingRows.map(\.count)).count == 1, "\(Array(streamingRows))")
        #expect(
            streamingRows.map { $0.split(separator: " ").first.map(String.init) } == ["Category", "clean", "tv", "all"])
        // tv: "good night all" + "and the news" → three insertions over three words.
        #expect(lines.contains { $0.hasPrefix("tv") && $0.contains("100.0%") })
        // The offline engine has no partials.
        #expect(lines.contains { $0.hasPrefix("all") && $0.contains("–") })
        #expect(table.contains("RTF: compute / audio"))
    }

    @Test func rendersMarkdownWithTheErrorsAndTheGate() async throws {
        var report = try await report()
        report.gate = ASREvaluationThresholds(engines: ["streaming": .init(maxWER: 0.1)]).evaluate(report)
        let markdown = report.markdown()
        #expect(markdown.hasPrefix("# ASR evaluation\n"))
        #expect(markdown.contains("## `streaming`: Prepared streaming"))
        #expect(markdown.contains("| Category | Files | Words | WER |"))
        #expect(markdown.contains("| --- | ---: |"))
        #expect(markdown.contains("<details><summary>1 fixtures with errors</summary>"))
        #expect(markdown.contains("good night \\| all"), "Pipes in text are escaped")
        #expect(markdown.contains("- Regression gate: **failed**"))
        #expect(markdown.contains("| `streaming` | WER | 60.0% | 10.0% | **FAIL** |"))
    }

    @Test func theGateChecksEveryLimitAndRequiresListedEngines() async throws {
        let report = try await report()
        let thresholds = ASREvaluationThresholds(engines: [
            "streaming": .init(
                maxWER: 0.7, maxCategoryWER: ["clean": 0, "tv": 0.5, "cafe": 0.2], maxFirstPartialP95Ms: 1_000,
                maxFirstPartialAudioP95Ms: 600, maxEndOfUtteranceP95Ms: 2_000, maxEndOfUtteranceAudioP95Ms: 1_200,
                maxRealTimeFactor: 0.2, maxMissedUtterances: 0, maxSplitUtterances: 0),
            "offline": .init(maxWER: 0, maxFirstPartialP95Ms: 100),
            "missing": .init(maxWER: 0.5),
        ])
        let gate = thresholds.evaluate(report)
        #expect(!gate.passed)
        let failed = Set(gate.failures.map { "\($0.engine) \($0.metric)" })
        #expect(
            failed == [
                // 3 errors over 3 tv words.
                "streaming WER tv",
                // No cafe fixtures were run.
                "streaming WER cafe",
                // The offline engine has no partials to measure.
                "offline first partial p95",
                "missing ran",
            ])
        let streaming = gate.checks.filter { $0.engine == "streaming" }
        // p95 of 400 and 600 ms, interpolated.
        let audioPartial = try #require(streaming.first { $0.metric == "first partial p95 (audio)" })
        #expect(abs((audioPartial.value ?? 0) - 590) < 0.001)
        #expect(audioPartial.passed)
        #expect(streaming.contains { $0.metric == "failures" && $0.passed })
        #expect(gate.summary().contains("missing: did not run"))
        #expect(gate.summary().hasPrefix("Regression gate: FAILED (4 of"))

        let selected = thresholds.evaluate(report, engineIDs: ["streaming"])
        #expect(selected.checks.allSatisfy { $0.engine == "streaming" })
        // A run limited to some categories isn't failed for the others.
        let clean = thresholds.evaluate(report, engineIDs: ["streaming"], categories: ["clean"])
        #expect(clean.checks.filter { $0.metric.hasPrefix("WER ") }.map(\.metric) == ["WER clean"])
        #expect(clean.passed)
        let relaxed = ASREvaluationThresholds(engines: ["streaming": .init(maxWER: 0.7)]).evaluate(report)
        #expect(relaxed.passed)
        #expect(relaxed.summary().hasPrefix("Regression gate: passed"))
    }

    @Test func comparesARunWithTheBaseline() async throws {
        let current = try await report()
        var baseline = current
        baseline.engines[0].overall.wordErrorRate = 0.5
        baseline.engines[0].overall.unendedUtterances = 2
        baseline.engines.removeLast()

        let rows = current.comparisons(with: baseline)
        #expect(rows.allSatisfy { $0.engine == "streaming" }, "Engines missing from the baseline are skipped")
        let wer = try #require(rows.first { $0.metric == "WER" })
        #expect(wer.baseline == 0.5)
        #expect(abs((wer.change ?? 0) - 0.1) < 1e-9)
        #expect(rows.contains { $0.metric == "WER tv" })

        let table = current.comparisonTable(with: baseline, markdown: false)
        #expect(table.hasPrefix("Against the baseline of "))
        #expect(table.contains("(deadbeef) on Mac15,8 (Apple M3 Max):"))
        let werLine = try #require(table.split(separator: "\n").first { $0.hasPrefix("streaming  WER  ") })
        #expect(werLine.split(separator: " ").suffix(3) == ["50.0%", "60.0%", "+10.0%"])
        #expect(table.contains("-2"), "\(table)")
        #expect(table.contains("±0.0%"))
        #expect(current.comparisonTable(with: baseline, markdown: true).contains("| --- | --- | ---: |"))

        var unrelated = baseline
        unrelated.engines = []
        #expect(current.comparisonTable(with: unrelated, markdown: false) == "No engine in common with the baseline.")
    }

    @Test func theCommittedBaselineIsAReportOfTheBundledFixtures() throws {
        let url = ASRFixtures.repositoryRoot.appending(path: "docs/asr-eval/baseline.json")
        let baseline = try ASREvaluationReport.decode(Data(contentsOf: url))
        let manifest = try ASREvaluationDataset.manifest(at: ASRFixtures.manifestURL())
        #expect(baseline.dataset.name == manifest.name)
        #expect(baseline.dataset.fixtures == manifest.fixtures.count)
        #expect(Set(baseline.engines.map(\.descriptor.id)) == Set(ASREvaluationEngineID.allCases.map(\.rawValue)))
        // The committed thresholds accept the committed baseline.
        let thresholds = try ASREvaluationThresholds.load(
            ASRFixtures.repositoryRoot.appending(path: "docs/asr-eval/thresholds.json"))
        let gate = thresholds.evaluate(baseline)
        #expect(gate.passed, "\(gate.summary())")
    }

    @Test func theCommittedThresholdsAreValidAndCoverEveryEngine() throws {
        let url = ASRFixtures.repositoryRoot.appending(path: "docs/asr-eval/thresholds.json")
        let thresholds = try ASREvaluationThresholds.load(url)
        #expect(Set(thresholds.engines.keys) == Set(ASREvaluationEngineID.allCases.map(\.rawValue)))
        for (id, limits) in thresholds.engines {
            #expect(limits.maxWER != nil, "\(id) has no WER limit")
            #expect(limits.maxRealTimeFactor != nil, "\(id) has no RTF limit")
            #expect(limits.maxEndOfUtteranceP95Ms != nil, "\(id) has no end-of-utterance limit")
            for category in limits.maxCategoryWER?.keys.sorted() ?? [] {
                #expect(["clean", "cafe", "tv", "accented"].contains(category), "\(id): unknown category \(category)")
            }
        }
        #expect(thresholds.engines["parakeet-eou-320ms"]?.maxFirstPartialP95Ms != nil)
    }
}
