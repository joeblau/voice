import Foundation
import Testing

@testable import BlauMemory

/// The memory evaluation with an answer stage: what `make eval-memory` and
/// the nightly `memory-eval` CI job run (docs/memory-eval.md). Off unless
/// `BLAU_MEMORY_EVAL=1`.
///
/// Environment:
///
/// | Variable | Default | |
/// | --- | --- | --- |
/// | `BLAU_MEMORY_EVAL_READER` | `auto` | `auto` (Apple's on-device model if it can run here, else none), `foundation-models`, `xai`, `none` |
/// | `BLAU_MEMORY_EVAL_JUDGE` | the reader's | The same choices; `auto` follows the reader |
/// | `BLAU_MEMORY_EVAL_XAI_MODEL` | required for `xai` | The xAI model id, e.g. the Grok text model to test |
/// | `XAI_API_KEY` | required for `xai` | Never set in CI |
/// | `BLAU_MEMORY_EVAL_REQUIRE_ANSWERS` | `0` | `1` fails when no reader can run |
/// | `BLAU_MEMORY_EVAL_TYPES` | all | Comma-separated question types |
/// | `BLAU_MEMORY_EVAL_QUESTIONS` | all | Comma-separated question ids |
/// | `BLAU_MEMORY_EVAL_LIMIT` | all | Only the first N questions |
/// | `BLAU_MEMORY_EVAL_DATASET` | the bundled set | Another dataset directory |
/// | `BLAU_MEMORY_EVAL_VECTORS` | the bundled recording | Another recorded-vectors file; `none` for BM25 only |
/// | `BLAU_MEMORY_EVAL_OUTPUT` | a temporary directory | Where `report.json`, `report.md` and `summary.txt` go |
/// | `BLAU_MEMORY_EVAL_THRESHOLDS` | none | The regression gate (`docs/memory-eval/thresholds.json`) |
/// | `BLAU_MEMORY_EVAL_GATE` | `1` | `0` reports the gate without failing |
/// | `BLAU_MEMORY_EVAL_BASELINE` | none | A previous `report.json` to compare with (`docs/memory-eval/baseline.json`) |
/// | `BLAU_MEMORY_EVAL_COMMIT` | `GITHUB_SHA` | The commit recorded in the report |
@Suite(
    "Memory evaluation run",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_MEMORY_EVAL"] == "1"),
    .serialized
)
struct MemoryEvalRunTests {
    static let environment = ProcessInfo.processInfo.environment

    /// The variable's value; empty counts as unset (`make` passes every
    /// variable, set or not).
    static func value(_ key: String) -> String? {
        environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func list(_ key: String) -> [String]? {
        value(key).map { value in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test(.timeLimit(.minutes(60)))
    func evaluateMemory() async throws {
        var dataset =
            try Self.value("BLAU_MEMORY_EVAL_DATASET").map {
                try MemoryEvalDataset.load(directory: URL(filePath: $0, directoryHint: .isDirectory))
            } ?? MemoryEvalFixtures.dataset()
        let types = try Self.list("BLAU_MEMORY_EVAL_TYPES").map { names in
            Set(
                try names.map { name in
                    try #require(
                        MemoryEvalDataset.QuestionType(rawValue: name),
                        "Unknown question type \(name); known: \(MemoryEvalDataset.QuestionType.allCases.map(\.rawValue))"
                    )
                })
        }
        let ids = Self.list("BLAU_MEMORY_EVAL_QUESTIONS").map(Set.init)
        let limit = Self.value("BLAU_MEMORY_EVAL_LIMIT").flatMap(Int.init)
        let total = dataset.questions.count
        dataset = dataset.limited(toTypes: types, ids: ids, first: limit)
        let partial = dataset.questions.count != total
        print("[memory-eval] \(dataset.name): \(dataset.questions.count) of \(total) questions")

        let vectorsSetting = Self.value("BLAU_MEMORY_EVAL_VECTORS")
        let embeddings: MemoryEvalRecordedEmbeddings? =
            vectorsSetting == "none"
            ? nil
            : try MemoryEvalRecordedEmbeddings.load(
                vectorsSetting.map { URL(filePath: $0) } ?? MemoryEvalFixtures.vectorsURL())

        let stage = try AnswerStage.resolve(dataset: dataset)
        if Self.environment["BLAU_MEMORY_EVAL_REQUIRE_ANSWERS"] == "1" {
            #expect(stage.reader != nil, "No reader can run: \(stage.skipped ?? "")")
        }
        print(
            "[memory-eval] answers: \(stage.reader.map { "reader \($0.identifier), judge \(stage.judge?.identifier ?? "")" } ?? "skipped (\(stage.skipped ?? ""))")"
        )

        let started = ContinuousClock.now
        var report = try await MemoryEvaluator(dataset: dataset).run(
            embeddings: embeddings, reader: stage.reader, judge: stage.judge, answersSkipped: stage.skipped,
            commit: Self.value("BLAU_MEMORY_EVAL_COMMIT") ?? Self.value("GITHUB_SHA"),
            progress: { print("[memory-eval] \($0)") })
        print("[memory-eval] evaluated in \(ContinuousClock.now - started)")

        if let path = Self.value("BLAU_MEMORY_EVAL_THRESHOLDS") {
            report.gate = try MemoryEvalThresholds.load(URL(filePath: path)).evaluate(
                report, partial: partial, requireAnswers: Self.environment["BLAU_MEMORY_EVAL_REQUIRE_ANSWERS"] == "1")
        }

        let output =
            Self.value("BLAU_MEMORY_EVAL_OUTPUT").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "blau-memory-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var markdown = report.markdown()
        var table = report.table()
        if let path = Self.value("BLAU_MEMORY_EVAL_BASELINE") {
            let baseline = try MemoryEvalReport.decode(Data(contentsOf: URL(filePath: path)))
            table += "\n\nAgainst the baseline:\n" + report.comparisonTable(with: baseline, markdown: false)
            markdown += "\n## Against the baseline\n\n" + report.comparisonTable(with: baseline, markdown: true) + "\n"
        }
        try report.jsonData().write(to: output.appending(path: "report.json"))
        try Data(markdown.utf8).write(to: output.appending(path: "report.md"))
        try Data((table + "\n").utf8).write(to: output.appending(path: "summary.txt"))
        print("\n" + table + "\n")
        print("[memory-eval] wrote report.json, report.md and summary.txt to \(output.path(percentEncoded: false))")

        if let gate = report.gate, Self.environment["BLAU_MEMORY_EVAL_GATE"] != "0" {
            #expect(gate.passed, "\(gate.summary())")
        }
    }

    /// The reader and judge the environment asks for.
    struct AnswerStage {
        var reader: (any MemoryEvalReader)?
        var judge: (any MemoryEvalJudge)?
        var skipped: String?

        static func resolve(dataset: MemoryEvalDataset) throws -> AnswerStage {
            let readerChoice = MemoryEvalRunTests.value("BLAU_MEMORY_EVAL_READER") ?? "auto"
            let judgeChoice = MemoryEvalRunTests.value("BLAU_MEMORY_EVAL_JUDGE") ?? "auto"
            var skipped: String?
            guard let readerModel = try model(readerChoice, skipped: &skipped) else {
                return AnswerStage(skipped: skipped)
            }
            let judgeModel =
                judgeChoice == "auto" || judgeChoice == readerChoice
                ? readerModel : try model(judgeChoice, skipped: &skipped)
            guard let judgeModel else { return AnswerStage(skipped: skipped) }
            return AnswerStage(
                reader: LLMMemoryEvalReader(model: readerModel, userName: dataset.userName, timeZone: dataset.timeZone),
                judge: LLMMemoryEvalJudge(model: judgeModel))
        }

        static func model(_ choice: String, skipped: inout String?) throws -> (any MemoryEvalLanguageModel)? {
            switch choice {
            case "none":
                skipped = "BLAU_MEMORY_EVAL_READER=none"
                return nil
            case "auto", "foundation-models":
                #if canImport(FoundationModels)
                    let model = FoundationModelsEvalLanguageModel()
                    if model.isAvailable { return model }
                    skipped = "Apple's on-device model is unavailable here (\(model.availabilityDescription))"
                #else
                    skipped = "this SDK has no FoundationModels"
                #endif
                if choice == "foundation-models" {
                    Issue.record("BLAU_MEMORY_EVAL_READER=foundation-models: \(skipped ?? "")")
                }
                return nil
            case "xai":
                let model = try #require(
                    MemoryEvalRunTests.value("BLAU_MEMORY_EVAL_XAI_MODEL"), "Set BLAU_MEMORY_EVAL_XAI_MODEL for xai")
                let key = try #require(MemoryEvalRunTests.value("XAI_API_KEY"), "Set XAI_API_KEY for xai")
                return ChatCompletionsEvalLanguageModel(model: model, apiKey: key)
            default:
                Issue.record("Unknown reader or judge \(choice): auto, foundation-models, xai or none")
                skipped = "unknown choice \(choice)"
                return nil
            }
        }
    }
}
