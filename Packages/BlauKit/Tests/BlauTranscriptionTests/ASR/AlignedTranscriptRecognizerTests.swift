import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// The scripted-session path of the performance suite (#73): a
/// `ConversationAudioScript` played into a real `CaptureHub`, segmented by
/// the real VAD (energy model) and transcribed by the real
/// `ParakeetStreamingTranscriber` running on `AlignedTranscriptRecognizer`.
@Suite struct AlignedTranscriptRecognizerTests {
    static func words(of script: ConversationAudioScript) -> [AlignedTranscriptRecognizer.Word] {
        script.words.map { .init(text: $0.text, end: $0.end, endsUtterance: $0.endsLine) }
    }

    @Test func replayedConversationIsTranscribedLineByLine() async throws {
        let script = ConversationAudioScript(conversation: ScriptedConversation(exchanges: 5, exchangesPerTopic: 5))
        let hub = CaptureHub()
        let vad = VoiceActivitySegmenter(model: EnergySpeechProbabilityModel(), signposter: .disabled(.asr))
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: AlignedTranscriptRecognizer(words: Self.words(of: script)), audio: hub, voiceActivity: vad,
            signposter: .disabled(.asr))
        let events = transcriber.events
        let collector = Task {
            var finals: [Utterance] = []
            var partials = 0
            for await event in events {
                switch event {
                case .final(let utterance): finals.append(utterance)
                case .partial: partials += 1
                case .refined: break
                }
            }
            return (finals, partials)
        }
        try await transcriber.start()
        // Subscribed before the first frame, so VAD's sample count is a stream
        // position (`run(on:)` would subscribe whenever its task starts).
        let vadFrames = hub.frames()
        let vadTask = Task {
            for await frame in vadFrames { await vad.process(frame) }
            await vad.finish()
        }

        let feeder = CaptureReplayFeeder(script: script, speed: nil)
        try await feeder.feed(into: hub) {
            min(vad.statistics.samplesProcessed, await transcriber.receivedPosition ?? 0)
        }
        hub.finish()
        await vadTask.value
        await transcriber.finish()
        let (finals, partials) = await collector.value

        #expect(finals.map(\.text) == script.lines.map(\.text))
        #expect(partials > script.words.count / 2)
        #expect(finals.allSatisfy { $0.speaker == .user })
        // Each utterance covers its line on the stream's timeline.
        for (utterance, line) in zip(finals, script.lines) {
            let start = Duration.samples(line.sampleRange.lowerBound, sampleRate: 16_000)
            let end = Duration.samples(line.sampleRange.upperBound, sampleRate: 16_000)
            #expect(utterance.timeRange.start <= start + .milliseconds(300))
            #expect(utterance.timeRange.end >= end - .milliseconds(400))
        }
        // The model's end-of-utterance rule committed them, not the stream's end.
        #expect(transcriber.statistics.utterancesCommitted == Int64(script.lines.count))
    }

    @Test func endOfUtteranceFiresAfterTheDebounce() async {
        let words: [AlignedTranscriptRecognizer.Word] = [
            .init(text: "hello", end: 4_000, endsUtterance: false),
            .init(text: "there", end: 8_000, endsUtterance: true),
        ]
        let recognizer = AlignedTranscriptRecognizer(words: words, debounce: .milliseconds(640))
        var outputs: [RecognizerOutput] = []
        var offset: Int64 = 0
        while offset < 48_000 {
            let frame = AudioFrame(samples: [Float](repeating: 0, count: 1_600), sampleOffset: offset)
            let output = await recognizer.append(frame)
            outputs.append(output)
            offset += Int64(output.consumedSamples)
            if output.isEndOfUtterance { break }
        }
        let end = outputs.firstIndex(where: \.isEndOfUtterance)
        #expect(end != nil)
        #expect(outputs.last?.transcript == "hello there")
        // Confirmed only once 640 ms of decoded audio passed after the word.
        let decodedAtEnd = outputs.last?.decodedSamples ?? 0
        #expect(decodedAtEnd >= 8_000 + 10_240)
        #expect(outputs.first(where: { $0.transcript == "hello" }) != nil)

        // `finish` keeps only the words up to a cutoff and forgets the rest.
        await recognizer.reset()
        _ = await recognizer.append(AudioFrame(samples: [Float](repeating: 0, count: 6_000), sampleOffset: 0))
        let finished = await recognizer.finish(keepingTokensThrough: 5_000)
        #expect(finished.transcript == "hello")
    }
}
