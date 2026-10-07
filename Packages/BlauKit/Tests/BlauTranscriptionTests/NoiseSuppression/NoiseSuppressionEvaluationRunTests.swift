import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The ASR side of the noise suppression A/B (#51) with the real models:
/// every ASR engine alone and behind each suppressor, over the ASR fixtures,
/// plus what each suppressor costs. What `scripts/eval-noise-suppression.sh`
/// (`make eval-noise`) runs; off unless `BLAU_NOISE_EVAL=1`.
///
/// | Variable | Default | |
/// | --- | --- | --- |
/// | `BLAU_ASR_EVAL_MODELS` | required | ASR model store root, as for `make eval-asr` |
/// | `BLAU_ASR_EVAL_DOWNLOAD` | `0` | `1` downloads missing ASR models |
/// | `BLAU_ASR_EVAL_ENGINES` | every engine | Comma-separated base engine ids |
/// | `BLAU_ASR_EVAL_CATEGORIES` | all | Comma-separated fixture categories |
/// | `BLAU_DFN3_MODEL_DIR` | none | DeepFilterNet3 (`scripts/fetch-deepfilternet3.sh`); without it `dfn3` is skipped |
/// | `BLAU_NOISE_EVAL_SUPPRESSORS` | every available one | e.g. `dfn3,apple-voice-isolation` |
/// | `BLAU_NOISE_EVAL_OUTPUT` | a temporary directory | `report.json`, `report.md`, `comparison.md`, `cost.md` |
@Suite(
    "Noise suppression A/B on the ASR fixtures (real models)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_NOISE_EVAL"] == "1"),
    .serialized
)
struct NoiseSuppressionEvaluationRunTests {
    static func value(_ key: String) -> String? { ASREvaluationRunTests.value(key) }

    static var deepFilterNet3Directory: URL? {
        value("BLAU_DFN3_MODEL_DIR").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func suppressors() throws -> [NoiseSuppressorKind] {
        if let list = value("BLAU_NOISE_EVAL_SUPPRESSORS") { return try NoiseSuppressorKind.list(list) }
        return NoiseSuppressorKind.allCases.filter { $0 != .deepFilterNet3 || deepFilterNet3Directory != nil }
    }

    static var output: URL {
        value("BLAU_NOISE_EVAL_OUTPUT").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "blau-noise-eval-\(UUID().uuidString)")
    }

    @Test(.timeLimit(.minutes(60)))
    func compareTheSuppressorsOnTheASRFixtures() async throws {
        let engineIDs =
            ASREvaluationRunTests.list("BLAU_ASR_EVAL_ENGINES") ?? ASREvaluationEngineID.allCases.map(\.rawValue)
        let engines = try engineIDs.map { id in
            try #require(ASREvaluationEngineID(rawValue: id), "Unknown engine \(id)")
        }
        let dataset = try ASREvaluationDataset.load(
            manifest: ASRFixtures.manifestURL(),
            categories: ASREvaluationRunTests.list("BLAU_ASR_EVAL_CATEGORIES").map(Set.init))
        let root = try #require(
            Self.value("BLAU_ASR_EVAL_MODELS").map { URL(filePath: $0, directoryHint: .isDirectory) },
            "Set BLAU_ASR_EVAL_MODELS to a model store root")
        let directories = try await ASREvaluationModels.directories(
            for: Set(engines.flatMap(\.models)), root: root,
            download: ProcessInfo.processInfo.environment["BLAU_ASR_EVAL_DOWNLOAD"] == "1")

        var factories: [(NoiseSuppressorKind, NoiseSuppressorFactory)] = []
        for kind in try Self.suppressors() {
            factories.append((kind, try await kind.factory(deepFilterNet3Directory: Self.deepFilterNet3Directory)))
        }

        var loaded: [any ASREvaluationEngine] = []
        for engine in engines {
            let base = try await engine.load(directories)
            loaded.append(base)
            for (_, factory) in factories {
                loaded.append(try NoiseSuppressedASREvaluationEngine(base: base, makeSuppressor: factory))
            }
        }
        print("[noise-eval] engines: \(loaded.map(\.descriptor.id).joined(separator: ", "))")

        let report = try await ASREvaluator(dataset: dataset).run(
            loaded, commit: Self.value("BLAU_ASR_EVAL_COMMIT"), progress: { print("[noise-eval] \($0)") })
        let comparison = NoiseSuppressionComparison(report)

        let cost = try await Self.measureCost(Self.suppressors())

        let output = Self.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try report.jsonData().write(to: output.appending(path: "report.json"))
        try Data(report.markdown().utf8).write(to: output.appending(path: "report.md"))
        try Data((comparison.markdown() + "\n").utf8).write(to: output.appending(path: "comparison.md"))
        try Data((cost.markdownSummary + "\n").utf8).write(to: output.appending(path: "cost.md"))
        try cost.jsonData().write(to: output.appending(path: "cost.json"))
        print("\n" + report.table() + "\n\n" + comparison.markdown() + "\n\n" + cost.markdownSummary)
        print("[noise-eval] wrote \(output.path(percentEncoded: false))")

        for engine in report.engines {
            #expect(engine.overall.failures == 0, "\(engine.descriptor.id) failed on some fixtures")
        }
    }

    /// Compute per 20 ms frame for each suppressor, DeepFilterNet3 on the
    /// Neural Engine and on the CPU alone (the background fallback).
    static func measureCost(_ kinds: [NoiseSuppressorKind]) async throws -> BenchmarkReport {
        let dataset = try ASREvaluationDataset.load(manifest: ASRFixtures.manifestURL())
        let speech = dataset.fixtures.flatMap(\.samples)
        let audio = AudioFixtureStore(fixture: AudioFixture(samples: speech, source: "the ASR fixtures, concatenated"))
        var cases: [any BenchmarkCase] = []
        for kind in kinds {
            switch kind {
            case .deepFilterNet3:
                for units in [NoiseSuppressionComputeUnits.cpuAndNeuralEngine, .cpuOnly, .all] {
                    cases.append(
                        NoiseSuppressionBenchmark.deepFilterNet3(
                            directory: deepFilterNet3Directory, computeUnits: units, audio: audio))
                }
            case .appleVoiceIsolation:
                cases.append(NoiseSuppressionBenchmark.soundIsolation(.voice, audio: audio))
            case .appleVoiceIsolationHighQuality:
                cases.append(NoiseSuppressionBenchmark.soundIsolation(.highQualityVoice, audio: audio))
            }
        }
        let runner = BenchmarkRunner()
        var results: [BenchmarkResult] = []
        for benchmark in cases {
            let result = await runner.run(benchmark)
            #expect(result.outcome.isCompleted, "\(benchmark.id): \(result.outcome)")
            results.append(result)
        }
        return BenchmarkReport(
            device: BenchmarkDevice.current, startedAt: results.first?.startedAt ?? .now, results: results,
            buildConfiguration: "debug (swift test)")
    }
}
