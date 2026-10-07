import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// The VAD fixtures through the **real** `SpeechAnalyzer` /
/// `SpeechTranscriber` on this machine. Off by default: it needs the
/// system's English speech model, which the first run may download
/// (`AppleSpeechAssets.prepare`), and it plays the audio in real time.
///
///     BLAU_APPLE_ASR_LIVE=1 swift test --filter AppleSpeechLiveTests
///
/// Optional: `BLAU_APPLE_ASR_PACE` plays faster than real time (e.g. `4`).
/// Results are recorded in docs/apple-asr.md.
@Suite(
    "Apple speech live",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_APPLE_ASR_LIVE"] == "1"),
    .serialized
)
struct AppleSpeechLiveTests {
    static let environment = ProcessInfo.processInfo.environment

    var pace: Double {
        Self.environment["BLAU_APPLE_ASR_PACE"].flatMap(Double.init) ?? 1
    }

    @Test func theEnglishModelIsAvailable() async throws {
        let availability = await AppleSpeechAssets.availability(for: Locale(identifier: "en-US"))
        print("[apple-asr] availability: \(availability)")
        #expect(availability.isSupported)
        let locale = try await AppleSpeechAssets.prepare(for: Locale(identifier: "en-US"))
        #expect(locale.identifier.hasPrefix("en"))
    }

    @Test(arguments: VADFixture.names, [false, true])
    func transcribesTheFixture(_ name: String, withVAD: Bool) async throws {
        let fixture = try VADFixture.load(name)
        let script = try #require(FixtureScript.all[name])
        let vadEvents = withVAD ? try await recordedVADEvents(for: fixture) : []
        let locale = try await AppleSpeechAssets.prepare(for: Locale(identifier: "en-US"))
        let source = FixtureAudioSource(block: fixture.samples)
        let vad = SettableVoiceActivity()
        let transcriber = AppleTranscriber(
            engine: SystemSpeechAnalyzerEngine(locale: locale), audio: source,
            voiceActivity: withVAD ? vad : nil,
            vocabulary: StaticRecognitionVocabulary(["Blau", "Grok"]),
            signposter: .disabled(.asr))

        // Note where the audio was when each final came out.
        let emitted = Mutex<[(Utterance, Int64)]>([])
        let collector = Task {
            for await event in transcriber.events {
                guard case .final(let utterance) = event else { continue }
                let position = await transcriber.transcribedPosition ?? 0
                emitted.withLock { $0.append((utterance, position)) }
            }
        }

        try await transcriber.start()
        let started = ContinuousClock.now
        var pending = vadEvents.sorted { $0.detectedAt < $1.detectedAt }[...]
        let frameLength = 320
        var offset: Int64 = 0
        while offset < source.totalSamples {
            while let next = pending.first, next.detectedAt <= offset {
                vad.send(next)
                pending.removeFirst()
            }
            let frame = source.frame(at: offset, length: frameLength)
            source.publish(frame)
            offset = frame.nextSampleOffset
            // Real time (or `pace` times faster), on the wall clock.
            let due = started + .seconds(Double(offset) / 16_000 / pace)
            try await Task.sleep(until: due)
        }
        source.finishFrames()
        try await waitUntil(timeout: .seconds(30)) { await transcriber.isRunning == false }
        await transcriber.finish()
        await collector.value

        let finals = emitted.withLock { $0 }
        let text = finals.map(\.0.text).joined(separator: " ")
        let reference = script.sentences(includingUnrecognizable: true).joined(separator: " ")
        let wer = wordErrorRate(text, reference: reference)
        let statistics = transcriber.statistics
        print("[apple-asr] \(name) (\(withVAD ? "with VAD" : "no VAD"), pace \(pace)×): WER \(wer)")
        for (utterance, position) in finals {
            let end = utterance.timeRange.end.sampleCount(sampleRate: 16_000)
            let label = fixture.labels.min { abs($0.upperBound - end) < abs($1.upperBound - end) }
            let sinceSpeech = label.map { samplesToMilliseconds(position - $0.upperBound) } ?? .nan
            print(
                "[apple-asr]   final \(Int(sinceSpeech)) ms after the labelled end of speech (\(Int(samplesToMilliseconds(position - end))) ms after its range): \"\(utterance.text)\""
            )
        }
        print(
            """
            [apple-asr]   commits \(statistics.commits.map { "\($0.key.rawValue)=\($0.value)" }.sorted()), \
            finalization requests \(statistics.finalizationRequests), unfinalized \(statistics.unfinalizedCommits), \
            partials \(statistics.partialsEmitted), results \(statistics.volatileResults)/\(statistics.finalResults)
            """
        )

        #expect(!finals.isEmpty)
        #expect(wer < 0.35, "\(name): \"\(text)\"")
        #expect(statistics.engineFailures == 0)
    }
}
