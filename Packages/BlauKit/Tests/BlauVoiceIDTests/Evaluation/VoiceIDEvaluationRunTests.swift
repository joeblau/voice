import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// Runs the voice ID evaluation harness with the real WeSpeaker model over an
/// evaluation set and writes the report (docs/voice-id-eval.md). Opt-in: it
/// needs the downloaded model and a dataset manifest.
///
///     BLAU_SPEAKER_MODEL_DIR=<speakerEmbedding model dir> \
///     BLAU_VOICEID_EVAL_MANIFEST=<dir>/blau-voiceid-manifest.json \
///     BLAU_VOICEID_EVAL_OUTPUT=<output dir> \
///       swift test --filter VoiceIDEvaluationRunTests
///
/// Optional:
/// - `BLAU_VOICEID_EVAL_DATE`: the date stamped on the report (default today).
/// - `BLAU_VOICEID_EVAL_CHECK_COMMITTED=1`: fail if the proposed thresholds
///   differ from `VoiceIDConfig.calibrated` (for re-running the reference
///   calibration set after a change).
@Suite(
    "Voice ID evaluation run (opt-in)",
    .enabled(if: VoiceIDEvaluationEnvironment.isConfigured),
    .serialized
)
struct VoiceIDEvaluationRunTests {
    @Test func evaluateAndCalibrate() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelDirectory = try #require(SpeakerModelEnvironment.modelDirectory)
        let manifest = try #require(VoiceIDEvaluationEnvironment.manifest)
        let output = VoiceIDEvaluationEnvironment.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let dataset = try VoiceIDEvaluationDataset.load(manifest: manifest)
        let embedder = try await WeSpeakerEmbedder.load(modelDirectory: modelDirectory)
        let date = environment["BLAU_VOICEID_EVAL_DATE"] ?? Date.now.formatted(.iso8601.year().month().day())
        let started = ContinuousClock.now
        let report = try await VoiceIDEvaluator(embedder: embedder).run(dataset, date: date) { line in
            print("[voiceid-eval] \(line)")
        }
        print("[voiceid-eval] finished in \(ContinuousClock.now - started)")

        try VoiceIDEvaluationEnvironment.write(report, to: output)
        let proposed = report.calibration.config
        print(
            """
            [voiceid-eval] wrote \(output.path(percentEncoded: false))
            [voiceid-eval] proposed short: T_hi \(proposed.short.accept) T_lo \(proposed.short.reject); \
            long: T_hi \(proposed.long.accept) T_lo \(proposed.long.reject)
            """)

        #expect(report.metrics.contains { $0.condition == VoiceIDEvaluationPlan.pooled })
        if environment["BLAU_VOICEID_EVAL_CHECK_COMMITTED"] == "1" {
            let committed = VoiceIDConfig.calibrated
            #expect(committed.short == proposed.short, "VoiceIDConfig.calibrated.short is out of date")
            #expect(committed.long == proposed.long, "VoiceIDConfig.calibrated.long is out of date")
            #expect(committed.scoring == proposed.scoring)
            #expect(committed.modelIdentifier == proposed.modelIdentifier)
        }
    }
}

/// Re-renders a stored run's Markdown and charts without running the model
/// again (after a change to the report or plot code):
///
///     BLAU_VOICEID_EVAL_REPORT=<dir>/report.json BLAU_VOICEID_EVAL_OUTPUT=<dir> \
///       swift test --filter VoiceIDEvaluationRenderTests
@Suite(
    "Voice ID evaluation re-render (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_VOICEID_EVAL_REPORT"] != nil)
)
struct VoiceIDEvaluationRenderTests {
    @Test func renderStoredReport() throws {
        let path = try #require(ProcessInfo.processInfo.environment["BLAU_VOICEID_EVAL_REPORT"])
        let report = try JSONDecoder().decode(VoiceIDEvaluationReport.self, from: Data(contentsOf: URL(filePath: path)))
        let output = VoiceIDEvaluationEnvironment.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try VoiceIDEvaluationEnvironment.write(report, to: output)
    }
}

/// Where the opt-in evaluation run finds its inputs and puts its output.
enum VoiceIDEvaluationEnvironment {
    static var isConfigured: Bool { SpeakerModelEnvironment.modelDirectory != nil && manifest != nil }

    /// `BLAU_VOICEID_EVAL_MANIFEST`: the dataset manifest.
    static var manifest: URL? {
        ProcessInfo.processInfo.environment["BLAU_VOICEID_EVAL_MANIFEST"].map { URL(filePath: $0) }
    }

    /// `BLAU_VOICEID_EVAL_OUTPUT`, or a fresh temporary directory.
    static var output: URL {
        if let path = ProcessInfo.processInfo.environment["BLAU_VOICEID_EVAL_OUTPUT"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FileManager.default.temporaryDirectory.appending(path: "blau-voiceid-eval", directoryHint: .isDirectory)
    }

    /// Writes the report as Markdown and JSON, plus the SVG charts
    /// docs/voice-id-eval.md embeds.
    static func write(_ report: VoiceIDEvaluationReport, to directory: URL) throws {
        func save(_ text: String, _ name: String) throws {
            try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        try save(report.markdown(), "report.md")
        try report.json().write(to: directory.appending(path: "report.json"))
        try save(VoiceIDEvaluationPlots.detByWindow(report), "det-windows.svg")
        try save(VoiceIDEvaluationPlots.detByScoring(report), "det-scoring.svg")
        for histogram in report.histograms {
            let name = VoiceIDEvaluationReport.seconds(histogram.window).replacingOccurrences(of: " ", with: "")
            try save(
                VoiceIDEvaluationPlots.detByCondition(report, window: histogram.window), "det-conditions-\(name).svg")
            try save(
                VoiceIDEvaluationPlots.histogram(
                    histogram,
                    title:
                        "Scores at \(VoiceIDEvaluationReport.seconds(histogram.window)): \(report.calibration.scoring)"
                ),
                "scores-\(name).svg")
        }
    }
}
