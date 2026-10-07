import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// An hour of looped fixtures through the transcriber with the simulated
/// recognizer (hermetic). It proves the structure behind "flat memory and no
/// growth in per-chunk latency": the recognizer is reset after every
/// utterance, so the history it re-decodes for each partial never exceeds
/// one utterance, and every chunk costs the same in minute 60 as in
/// minute 1. `ParakeetLiveTests.anHourOfSpeechKeepsMemoryAndChunkTimeFlat`
/// measures the same replay on the real model.
@Suite("Streaming transcriber soak")
struct TranscriberSoakTests {
    @Test(.timeLimit(.minutes(10)))
    func anHourOfConversationKeepsTheRecognizersHistoryAndWorkPerChunkFlat() async throws {
        let minutes = Int(ProcessInfo.processInfo.environment["BLAU_ASR_HERMETIC_SOAK_MINUTES"] ?? "") ?? 60
        var block: [Float] = []
        var words: [ScriptedWord] = []
        var vadEvents: [VoiceActivityEvent] = []
        var sentencesPerBlock = 0
        var longestSentence = 0
        for name in VADFixture.names {
            let fixture = try VADFixture.load(name)
            let script = try #require(FixtureScript.all[name])
            let offset = Int64(block.count)
            words += script.words(over: fixture.labels, offset: offset)
            vadEvents += try await recordedVADEvents(for: fixture).map { $0.shifted(by: offset) }
            let sentences = script.sentences(includingUnrecognizable: true)
            sentencesPerBlock += sentences.count
            longestSentence = max(longestSentence, sentences.map { $0.split(separator: " ").count }.max() ?? 0)
            block += fixture.samples
            block += [Float](repeating: 0, count: (4_096 - fixture.samples.count % 4_096) % 4_096)
        }
        let samplesPerMinute = Int64(AudioFrame.captureSampleRate * 60)
        let repeats = Int((Int64(minutes) * samplesPerMinute) / Int64(block.count))
        let source = FixtureAudioSource(block: block, repeats: repeats)
        let events = (0..<repeats).flatMap { index in vadEvents.map { $0.shifted(by: Int64(index * block.count)) } }
        let recognizer = SimulatedEouRecognizer(words: words, period: Int64(block.count))
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
            signposter: .disabled(.asr), clock: ManualClock())

        // Work per chunk, minute by minute: words re-decoded per chunk and
        // the transcriber's own wall time per frame.
        var perMinute: [(redecodedPerChunk: Double, microsecondsPerFrame: Double)] = []
        var previous = (chunks: 0, redecoded: 0)
        var minuteStart = ContinuousClock.now
        let replay = await TranscriptionReplay.run(transcriber, source: source, vadEvents: events) { position in
            guard position % samplesPerMinute == 0 else { return }
            let chunks = await recognizer.chunksRun
            let redecoded = await recognizer.wordsRedecoded
            let elapsed = ContinuousClock.now - minuteStart
            perMinute.append(
                (
                    Double(redecoded - previous.redecoded) / Double(max(chunks - previous.chunks, 1)),
                    elapsed.milliseconds * 1_000 / Double(samplesPerMinute / 320)
                ))
            previous = (chunks, redecoded)
            minuteStart = ContinuousClock.now
        }

        let statistics = replay.statistics
        print(
            """
            [soak] \(minutes) min: \(statistics.utterancesCommitted) utterances, \(statistics.chunksProcessed) chunks, \
            longest recognizer history \(await recognizer.maximumHistory) words; \
            per minute (words re-decoded per chunk, µs per frame): \
            \(perMinute.map { "(\(String(format: "%.2f", $0.0)), \(String(format: "%.1f", $0.1)))" }.joined(separator: " "))
            """
        )

        // Every sentence of every repeat came out.
        #expect(replay.finals.count == sentencesPerBlock * repeats)
        #expect(Set(replay.finals.map(\.text)).count == sentencesPerBlock)
        // The recognizer starts every utterance from an empty history...
        #expect(await recognizer.resets >= replay.finals.count)
        #expect(await recognizer.maximumHistory <= longestSentence)
        // ...so a chunk in the last minutes re-decodes no more than one in the
        // first minutes.
        let early = perMinute.prefix(5).map(\.redecodedPerChunk)
        let late = perMinute.suffix(5).map(\.redecodedPerChunk)
        #expect(late.max() ?? 0 <= (early.max() ?? 0) * 1.5 + 1)
        // Nothing skipped or transcribed twice, in an hour.
        #expect(await recognizer.discontinuities == 0)
        #expect(statistics.samplesMissed == 0)
        #expect(statistics.recognizerFailures == 0)
    }
}
