import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The segmenter with the real Silero VAD model. Off by default (it needs
/// the downloaded model); point `BLAU_VAD_MODEL_DIR` at an installed
/// `.sileroVAD` directory, for example one fetched with
///
///     BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=sileroVAD \
///       BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
///     BLAU_VAD_MODEL_DIR=/tmp/blau-models/sileroVAD/<revision> swift test --filter SileroLiveTests
///
/// With `BLAU_VAD_RECORD=1` it also rewrites the recorded probabilities
/// (`Fixtures/VAD/*.silero.json`) that the hermetic tests replay.
@Suite(
    "Silero VAD on the fixtures (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_VAD_MODEL_DIR"] != nil),
    .serialized
)
struct SileroLiveTests {
    let directory = URL(
        filePath: ProcessInfo.processInfo.environment["BLAU_VAD_MODEL_DIR"] ?? "/", directoryHint: .isDirectory)
    let records = ProcessInfo.processInfo.environment["BLAU_VAD_RECORD"] == "1"

    @Test("Boundaries within ±100 ms of the labels", arguments: VADFixture.names)
    func boundaries(_ name: String) async throws {
        let fixture = try VADFixture.load(name)
        let silero = try await SileroSpeechProbabilityModel(modelDirectory: directory)
        let recorder = RecordingSpeechProbabilityModel(silero)
        // Record every chunk: no model skipping, so the recording covers
        // the whole fixture with an unbroken model state.
        var configuration = VoiceActivityConfiguration.standard
        configuration.modelSkipLevelDecibels = nil
        let run = await SegmenterRun.run(fixture.frames(), model: recorder, configuration: configuration)

        let accuracy = BoundaryAccuracy(fixture: name, labels: fixture.labels, segments: run.segments)
        print("[silero] \(accuracy)")
        let probabilities = await recorder.probabilities
        print(
            "[silero] \(name) probabilities: \(probabilities.map { String(format: "%.2f", $0) }.joined(separator: " "))"
        )
        #expect(accuracy.isWithinTolerance, "\(accuracy)")

        if records {
            let recorded = RecordedProbabilities(
                model: FluidAudioModels.vadModelBundle, chunkLength: silero.chunkLength, probabilities: probabilities)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = VADFixture.sourceDirectory.appending(path: "\(name).silero.json")
            try encoder.encode(recorded).write(to: url)
            print("[silero] wrote \(url.path())")
        }
    }

    /// The silence criterion's proxy on the Mac: the process CPU time spent
    /// segmenting a minute of room tone (loud enough that the model runs on
    /// every chunk) as a share of the audio's duration. Wall time is
    /// printed but not checked: it includes waiting for the Neural Engine,
    /// which isn't CPU and varies with the machine's load. The device
    /// number comes from Instruments (docs/vad.md).
    @Test func silenceCostsUnderThreePercent() async throws {
        let silero = try await SileroSpeechProbabilityModel(modelDirectory: directory)
        let noise = roomNoise(count: 60 * 16_000, levelDecibels: -50, seed: 7)
        let frames = stride(from: 0, to: noise.count, by: 320).map {
            AudioFrame(samples: Array(noise[$0..<min($0 + 320, noise.count)]), sampleOffset: Int64($0))
        }
        let segmenter = VoiceActivitySegmenter(model: silero, signposter: .disabled(.asr))
        let cpuBefore = ProcessCPUTime.now
        let started = ContinuousClock.now
        for frame in frames {
            await segmenter.process(frame)
        }
        await segmenter.finish()
        let wall = ContinuousClock.now - started
        let cpu = ProcessCPUTime.now - cpuBefore
        let statistics = segmenter.statistics
        let wallShare = wall.timeInterval / 60
        let cpuShare = cpu / 60
        print(
            """
            [silero] 60 s of room tone: \(statistics.chunksAnalyzed) model calls, \(statistics.chunksSkipped) skipped, \
            \(statistics.segments) segments; wall \(wall) (\(String(format: "%.2f", wallShare * 100))% of real time), \
            process CPU \(String(format: "%.3f", cpu)) s (\(String(format: "%.2f", cpuShare * 100))% of one core), \
            model \(String(format: "%.2f", statistics.modelLoad * 100))%
            """
        )
        #expect(statistics.segments == 0, "Room tone is not speech")
        #expect(statistics.chunksAnalyzed == 235)
        #expect(cpuShare < 0.03)
    }
}

/// User plus system CPU time of this process, in seconds.
enum ProcessCPUTime {
    static var now: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
