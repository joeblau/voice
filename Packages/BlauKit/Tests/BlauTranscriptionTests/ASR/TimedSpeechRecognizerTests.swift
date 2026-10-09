import BlauCore
import Testing

@testable import BlauTranscription

/// The soak test's timing of a recognizer that doesn't time itself (#76).
@Suite struct TimedSpeechRecognizerTests {
    /// Takes `cost` of the clock's time per call and reports `output`.
    actor CostlyRecognizer: StreamingSpeechRecognizer {
        nonisolated let chunkSize = ASRChunkSize.ms320
        let clock: ManualClock
        let cost: Duration
        let output: RecognizerOutput
        private(set) var resets = 0

        init(clock: ManualClock, cost: Duration, output: RecognizerOutput) {
            self.clock = clock
            self.cost = cost
            self.output = output
        }

        func append(_ frame: AudioFrame) -> RecognizerOutput {
            clock.advance(by: cost)
            return output
        }

        func finish(keepingTokensThrough cutoff: Int64?) -> RecognizerOutput {
            clock.advance(by: cost)
            return output
        }

        func reset() { resets += 1 }
    }

    let frame = AudioFrame(samples: [Float](repeating: 0, count: 320), sampleOffset: 0)

    @Test func aRecognizerWithoutModelTimeIsTimedByTheCall() async throws {
        let clock = ManualClock()
        let inner = CostlyRecognizer(
            clock: clock, cost: .microseconds(40), output: RecognizerOutput(consumedSamples: 320, chunks: 1))
        let timed = TimedSpeechRecognizer(inner, clock: clock)
        #expect(timed.chunkSize == .ms320)
        let appended = try await timed.append(frame)
        #expect(appended.modelTime == .microseconds(40))
        #expect(appended.consumedSamples == 320)
        let finished = try await timed.finish()
        #expect(finished.modelTime == .microseconds(40))
        await timed.reset()
        #expect(await inner.resets == 1)
    }

    @Test func aRecognizerThatTimesItselfPassesThrough() async throws {
        let clock = ManualClock()
        let inner = CostlyRecognizer(
            clock: clock, cost: .milliseconds(30),
            output: RecognizerOutput(chunks: 1, modelTime: .milliseconds(12)))
        let output = try await TimedSpeechRecognizer(inner, clock: clock).append(frame)
        #expect(output.modelTime == .milliseconds(12))
    }

    @Test func callsWithoutAChunkReportNoTime() async throws {
        let clock = ManualClock()
        let inner = CostlyRecognizer(clock: clock, cost: .milliseconds(1), output: RecognizerOutput(chunks: 0))
        let output = try await TimedSpeechRecognizer(inner, clock: clock).append(frame)
        #expect(output.modelTime == .zero)
    }

    @Test func theAlignedRecognizerGetsAPerChunkTime() async throws {
        let words = [AlignedTranscriptRecognizer.Word(text: "hello", end: 8_000, endsUtterance: true)]
        let timed = TimedSpeechRecognizer(AlignedTranscriptRecognizer(words: words))
        var chunks = 0
        var time = Duration.zero
        var offset: Int64 = 0
        while offset < 32_000 {
            let output = try await timed.append(
                AudioFrame(samples: [Float](repeating: 0, count: 320), sampleOffset: offset))
            chunks += output.chunks
            time += output.modelTime
            offset += 320
        }
        #expect(chunks > 0)
        #expect(time > .zero)
    }
}
