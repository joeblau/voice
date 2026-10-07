import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The ASR evaluation with the **real models**: what `make eval-asr` and the
/// nightly `asr-eval` CI job run (docs/asr-eval.md). Off unless
/// `BLAU_ASR_EVAL=1`.
///
/// Environment:
///
/// | Variable | Default | |
/// | --- | --- | --- |
/// | `BLAU_ASR_EVAL_MODELS` | required | Model store root (`ModelStore` layout: `<root>/<model>/<revision>`) |
/// | `BLAU_ASR_EVAL_DOWNLOAD` | `0` | `1` downloads missing models into the root first (hundreds of MB) |
/// | `BLAU_ASR_EVAL_ENGINES` | every engine | Comma-separated engine ids |
/// | `BLAU_ASR_EVAL_MANIFEST` | the bundled fixtures | Another set, e.g. the owner's recordings |
/// | `BLAU_ASR_EVAL_CATEGORIES` | all | Comma-separated categories to run |
/// | `BLAU_ASR_EVAL_OUTPUT` | a temporary directory | Where `report.json`, `report.md` and `summary.txt` go |
/// | `BLAU_ASR_EVAL_THRESHOLDS` | none | The regression gate (`docs/asr-eval/thresholds.json`) |
/// | `BLAU_ASR_EVAL_GATE` | `1` | `0` reports the gate without failing |
/// | `BLAU_ASR_EVAL_BASELINE` | none | A previous `report.json` to compare with (`docs/asr-eval/baseline.json`) |
/// | `BLAU_ASR_EVAL_COMMIT` | `GITHUB_SHA` | The commit recorded in the report |
@Suite(
    "ASR evaluation run (real models)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_ASR_EVAL"] == "1"),
    .serialized
)
struct ASREvaluationRunTests {
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
    func evaluateTheEnginesOnTheFixtures() async throws {
        let environment = Self.environment
        let engineIDs = Self.list("BLAU_ASR_EVAL_ENGINES") ?? ASREvaluationEngineID.allCases.map(\.rawValue)
        let engines = try engineIDs.map { id in
            try #require(
                ASREvaluationEngineID(rawValue: id), "Unknown engine \(id); known: \(ASREvaluationEngineID.allCases)")
        }

        let manifest = try Self.value("BLAU_ASR_EVAL_MANIFEST").map { URL(filePath: $0) } ?? ASRFixtures.manifestURL()
        let dataset = try ASREvaluationDataset.load(
            manifest: manifest, categories: Self.list("BLAU_ASR_EVAL_CATEGORIES").map(Set.init))
        print(
            "[asr-eval] \(dataset.name): \(dataset.fixtures.count) fixtures, \(dataset.utteranceCount) utterances, "
                + "\(String(format: "%.1f", dataset.audioSeconds)) s")

        let root = try #require(
            Self.value("BLAU_ASR_EVAL_MODELS").map { URL(filePath: $0, directoryHint: .isDirectory) },
            "Set BLAU_ASR_EVAL_MODELS to a model store root (make eval-asr does)")
        let needed = Set(engines.flatMap(\.models))
        let directories = try await ASREvaluationModels.directories(
            for: needed, root: root, download: environment["BLAU_ASR_EVAL_DOWNLOAD"] == "1")

        var loaded: [any ASREvaluationEngine] = []
        for engine in engines {
            loaded.append(try await engine.load(directories))
        }

        let started = ContinuousClock.now
        var report = try await ASREvaluator(dataset: dataset).run(
            loaded, commit: Self.value("BLAU_ASR_EVAL_COMMIT") ?? Self.value("GITHUB_SHA"),
            progress: { print("[asr-eval] \($0)") })
        print("[asr-eval] evaluated in \(ContinuousClock.now - started)")

        if let path = Self.value("BLAU_ASR_EVAL_THRESHOLDS") {
            let thresholds = try ASREvaluationThresholds.load(URL(filePath: path))
            report.gate = thresholds.evaluate(
                report, engineIDs: Set(engineIDs), categories: Self.list("BLAU_ASR_EVAL_CATEGORIES").map(Set.init))
        }

        let output =
            Self.value("BLAU_ASR_EVAL_OUTPUT").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "blau-asr-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var markdown = report.markdown()
        var table = report.table()
        if let path = Self.value("BLAU_ASR_EVAL_BASELINE") {
            let baseline = try ASREvaluationReport.decode(Data(contentsOf: URL(filePath: path)))
            table += "\n\n" + report.comparisonTable(with: baseline, markdown: false)
            markdown += "\n## Against the baseline\n\n" + report.comparisonTable(with: baseline, markdown: true) + "\n"
        }
        try report.jsonData().write(to: output.appending(path: "report.json"))
        try Data(markdown.utf8).write(to: output.appending(path: "report.md"))
        try Data((table + "\n").utf8).write(to: output.appending(path: "summary.txt"))
        print("\n" + table + "\n")
        print("[asr-eval] wrote report.json, report.md and summary.txt to \(output.path(percentEncoded: false))")

        for engine in report.engines {
            #expect(engine.overall.failures == 0, "\(engine.descriptor.id) failed on some fixtures")
        }
        if let gate = report.gate, environment["BLAU_ASR_EVAL_GATE"] != "0" {
            #expect(gate.passed, "\(gate.summary())")
        }
    }
}

/// The engines the harness knows how to build from installed models.
enum ASREvaluationEngineID: String, CaseIterable, CustomStringConvertible {
    case parakeetEOU = "parakeet-eou-320ms"
    case parakeetTDTv3 = "parakeet-tdt-v3"

    var description: String { rawValue }

    var models: [ModelID] {
        switch self {
        case .parakeetEOU: [.parakeetRealtimeEOU, .sileroVAD]
        case .parakeetTDTv3: [.parakeetTDTv3]
        }
    }

    func load(_ directories: [ModelID: URL]) async throws -> any ASREvaluationEngine {
        let manifest = ModelManifest.pinned
        switch self {
        case .parakeetEOU:
            return try await StreamingASREvaluationEngine.parakeetRealtimeEOU(
                modelDirectory: try #require(directories[.parakeetRealtimeEOU]),
                vadModelDirectory: try #require(directories[.sileroVAD]),
                revision: manifest[.parakeetRealtimeEOU]?.revision)
        case .parakeetTDTv3:
            return try await OfflineASREvaluationEngine.parakeetTDTv3(
                modelDirectory: try #require(directories[.parakeetTDTv3]),
                revision: manifest[.parakeetTDTv3]?.revision)
        }
    }
}

/// Finds (and optionally downloads) the pinned models in a model store.
enum ASREvaluationModels {
    @MainActor
    static func directories(for ids: Set<ModelID>, root: URL, download: Bool) async throws -> [ModelID: URL] {
        let manifest = ModelManifest(models: ModelManifest.pinned.models.filter { ids.contains($0.id) })
        let store = ModelStore(root: root)
        var directories: [ModelID: URL] = [:]
        for descriptor in manifest.models {
            directories[descriptor.id] = store.installation(of: descriptor)?.directory
        }
        let missing = manifest.models.filter { directories[$0.id] == nil }.map(\.id)
        guard !missing.isEmpty else { return directories }
        guard download else {
            Issue.record(
                """
                Models missing from \(root.path(percentEncoded: false)): \(missing.map(\.rawValue)). \
                Set BLAU_ASR_EVAL_DOWNLOAD=1 (make eval-asr does) to download them.
                """)
            throw ASREvaluationModelsError.missing(missing)
        }

        print("[asr-eval] downloading \(missing.map(\.rawValue)) into \(root.path(percentEncoded: false))")
        FluidAudioModels.disableImplicitDownloads()
        let manager = ModelManager(
            manifest: manifest, store: store,
            preferencesStore: InMemoryModelPreferencesStore(
                ModelPreferences(downloadPolicy: .anyNetwork, downloadsOptionalModels: true)))
        await manager.start()
        await manager.waitUntilIdle()
        for id in missing {
            guard let directory = manager.directory(for: id) else {
                Issue.record("Couldn't install \(id.rawValue): \(manager.state(of: id))")
                throw ASREvaluationModelsError.missing([id])
            }
            directories[id] = directory
        }
        return directories
    }
}

enum ASREvaluationModelsError: Error {
    case missing([ModelID])
}
