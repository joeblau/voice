import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The second pass on the **real** Parakeet TDT v3 model. Off by default (it
/// needs the 480 MB model); run it with the model `ModelManager` installed:
///
///     BLAU_MODEL_DOWNLOAD_SMOKE=1 BLAU_MODEL_DOWNLOAD_SMOKE_MODELS=parakeetTDTv3,parakeetRealtimeEOU \
///       BLAU_MODEL_DOWNLOAD_SMOKE_DIR=/tmp/blau-models swift test --filter ModelDownloadSmokeTests
///     BLAU_TDT_MODEL_DIR=/tmp/blau-models/parakeetTDTv3/<revision> \
///       BLAU_ASR_MODEL_DIR=/tmp/blau-models/parakeetRealtimeEOU/<revision> \
///       swift test --filter SecondPassLiveTests
///
/// The end-to-end test also needs `BLAU_ASR_MODEL_DIR` (the streaming
/// model). Results are recorded in docs/asr.md.
@Suite(
    "Second pass live",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_TDT_MODEL_DIR"] != nil),
    .serialized
)
struct SecondPassLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    func loadTdt() async throws -> ParakeetTdtRecognizer {
        let directory = URL(filePath: Self.environment["BLAU_TDT_MODEL_DIR"]!, directoryHint: .isDirectory)
        return try await ParakeetTdtRecognizer.load(modelDirectory: directory)
    }

    /// Every labelled sentence of the fixtures, transcribed alone the way
    /// the second pass reads it (with its padding): punctuated, capitalized
    /// and accurate.
    @Test func eachSentenceComesBackPunctuatedAndCapitalized() async throws {
        let tdt = try await loadTdt()
        let padding = (
            SecondPassConfiguration.standard.leadingPaddingSamples,
            SecondPassConfiguration.standard.trailingPaddingSamples
        )
        var hypotheses: [String] = []
        var references: [String] = []
        var audioSeconds = 0.0
        var modelTime = Duration.zero
        let clock = ContinuousClock()
        for name in VADFixture.names {
            let fixture = try VADFixture.load(name)
            let script = try #require(FixtureScript.all[name])
            for (label, lines) in zip(fixture.labels, script.segments) where lines.allSatisfy(\.isRecognizable) {
                let lower = Int(max(0, label.lowerBound - padding.0))
                let upper = Int(min(Int64(fixture.samples.count), label.upperBound + padding.1))
                let samples = Array(fixture.samples[lower..<upper])
                let started = clock.now
                let text = try await tdt.transcribe(samples).text
                modelTime += clock.now - started
                audioSeconds += Double(samples.count) / 16_000
                let reference = lines.map(\.text).joined(separator: " ")
                print("[tdt] \(name): \"\(text)\" (reference \"\(reference)\")")
                hypotheses.append(text)
                references.append(reference)
                #expect(text.first?.isUppercase == true, "\(name): \(text)")
                #expect(text.last.map { ".?!".contains($0) } == true, "\(name): \(text)")
            }
        }
        let wer = wordErrorRate(hypotheses.joined(separator: " "), reference: references.joined(separator: " "))
        print(
            "[tdt] \(hypotheses.count) sentences, WER \(wer), \(audioSeconds) s of audio in \(modelTime) (RTF \(modelTime.timeInterval / audioSeconds))"
        )
        #expect(wer <= 0.15)
    }

    /// The whole path on the fixtures: the real streaming model commits
    /// lowercase finals, which go out at once, and the real TDT v3 second
    /// pass follows with punctuated, capitalized text for each of them.
    @Test(.enabled(if: environment["BLAU_ASR_MODEL_DIR"] != nil))
    func streamingFinalsAreRefinedEndToEnd() async throws {
        let tdt = try await loadTdt()
        let asrDirectory = URL(filePath: Self.environment["BLAU_ASR_MODEL_DIR"]!, directoryHint: .isDirectory)
        var streamingText: [String] = []
        var refinedText: [String] = []
        var references: [String] = []
        for name in VADFixture.names {
            let fixture = try VADFixture.load(name)
            let script = try #require(FixtureScript.all[name])
            let vadEvents = try await recordedVADEvents(for: fixture)
            let recognizer = try await ParakeetEouRecognizer.load(
                modelDirectory: asrDirectory, signposter: .disabled(.asr))
            let source = FixtureAudioSource(block: fixture.samples)
            let streaming = ParakeetStreamingTranscriber(
                recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
                signposter: .disabled(.asr), clock: ManualClock())
            let transcriber = SecondPassTranscriber(
                wrapping: streaming, audio: source, recognizer: { tdt }, thermalState: { .nominal },
                signposter: .disabled(.asr))
            let log = EventLog(transcriber.events)

            var pending = vadEvents.sorted { $0.detectedAt < $1.detectedAt }[...]
            var offset: Int64 = 0
            while offset < source.totalSamples {
                let frame = source.frame(at: offset, length: 320)
                var due: [VoiceActivityEvent] = []
                while let next = pending.first, next.detectedAt <= frame.sampleOffset {
                    due.append(next)
                    pending.removeFirst()
                }
                source.position = frame.nextSampleOffset
                await streaming.ingest(due, frame: frame)
                offset = frame.nextSampleOffset
            }
            await streaming.audioDidEnd(pending: Array(pending))
            await streaming.finish()
            await log.finished()

            let refinedByID = Dictionary(uniqueKeysWithValues: log.refined.map { ($0.id, $0) })
            for final in log.finals {
                let refined = refinedByID[final.id]
                print("[second-pass] \(name): \"\(final.text)\" → \"\(refined?.text ?? "(kept)")\"")
                streamingText.append(final.text)
                refinedText.append(refined?.text ?? final.text)
                if let refined {
                    #expect(refined.timeRange == final.timeRange)
                    #expect(refined.text.first?.isUppercase == true, "\(name): \(refined.text)")
                    #expect(refined.text.last.map { ".?!".contains($0) } == true, "\(name): \(refined.text)")
                }
            }
            references += script.sentences
            let statistics = transcriber.statistics
            print(
                """
                [second-pass] \(name): \(statistics.utterancesRefined) refined, \(statistics.utterancesUnchanged) \
                unchanged, skipped \(statistics.skipped); mean \(statistics.meanModelTime), slowest \
                \(statistics.slowestUtterance), RTF \(statistics.realTimeFactor)
                """
            )
            // Every final gets a second pass that is taken.
            #expect(statistics.utterancesRefined == Int64(log.finals.count), "\(name): \(statistics)")
        }
        let reference = references.joined(separator: " ")
        let streamingWER = wordErrorRate(streamingText.joined(separator: " "), reference: reference)
        let refinedWER = wordErrorRate(refinedText.joined(separator: " "), reference: reference)
        print("[second-pass] WER streaming \(streamingWER), refined \(refinedWER)")
        #expect(refinedWER <= streamingWER + 0.02)
    }
}
