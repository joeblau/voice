import BlauCore
import Foundation
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite("TranscriptScript")
struct TranscriptScriptTests {
    @Test func speaksEachLineWordByWordThenFinal() throws {
        let conversation = ConversationID()
        let script = TranscriptScript.speaking(
            ["hello there", "  ", "how are you"],
            conversationID: conversation,
            startedAt: t0,
            wordDuration: .milliseconds(200),
            endOfUtteranceDelay: .milliseconds(500),
            pauseBetweenLines: .seconds(1)
        )

        let partials = script.steps.compactMap { step -> String? in
            if case .partial(let text, _) = step.event { text } else { nil }
        }
        #expect(partials == ["hello", "hello there", "how", "how are", "how are you"])
        #expect(script.finals.map(\.text) == ["hello there", "how are you"])

        // Line 1: words at 0.2 s and 0.4 s, final 0.5 s later.
        // Line 2 starts 1 s after that final, at 1.9 s.
        #expect(
            script.steps.map(\.delay) == [
                .milliseconds(200), .milliseconds(200), .milliseconds(500),
                .milliseconds(1_200), .milliseconds(200), .milliseconds(200), .milliseconds(500),
            ]
        )
        let second = try #require(script.finals.last)
        #expect(second.timeRange == TimeRange(start: .milliseconds(1_900), end: .milliseconds(2_500)))
        #expect(second.startedAt == t0.addingTimeInterval(1.9))
        #expect(second.conversationID == conversation)
        #expect(second.speaker == .user)
        #expect(second.speakerDecision == .accept)
        #expect(script.duration == .milliseconds(3_000))
    }

    @Test func partialRangesGrowFromTheLineStart() {
        let script = TranscriptScript.speaking(["one two three"], wordDuration: .milliseconds(100))
        let ranges = script.steps.compactMap { step -> TimeRange? in
            if case .partial(_, let range) = step.event { range } else { nil }
        }
        #expect(ranges.map(\.start) == [.zero, .zero, .zero])
        #expect(ranges.map(\.end) == [.milliseconds(100), .milliseconds(200), .milliseconds(300)])
    }

    @Test func agentLinesAreNotVoiceGated() {
        let script = TranscriptScript.speaking(["Sure, let's begin"], speaker: .agent)
        #expect(script.finals.first?.speakerDecision == nil)
    }

    @Test func sampleScriptIsNotEmpty() {
        #expect(TranscriptScript.sample.finals.count == 3)
    }
}

@Suite("FakeTranscriber")
struct FakeTranscriberTests {
    @Test func replaysTheScriptOnTheClock() async throws {
        let clock = ManualClock()
        let script = TranscriptScript.speaking(
            ["hi there"], wordDuration: .seconds(1), endOfUtteranceDelay: .seconds(1))
        let transcriber = FakeTranscriber(script: script, clock: clock)
        try await transcriber.start()
        #expect(transcriber.isRunning)
        #expect(transcriber.startCount == 1)

        var iterator = transcriber.events.makeAsyncIterator()
        await clock.waitForSleepers()
        #expect(transcriber.emittedStepCount == 0, "nothing is emitted before the first delay")

        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == script.steps[0].event)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == script.steps[1].event)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == .final(script.finals[0]))

        #expect(await iterator.next() == nil, "the stream finishes after the last step")
        #expect(!transcriber.isRunning)
        #expect(transcriber.emittedStepCount == script.steps.count)
    }

    @Test func stopPausesAndStartResumes() async throws {
        let clock = ManualClock()
        let script = TranscriptScript.speaking(["a b c"], wordDuration: .seconds(1))
        let transcriber = FakeTranscriber(script: script, clock: clock)
        var iterator = transcriber.events.makeAsyncIterator()

        try await transcriber.start()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == script.steps[0].event)

        await clock.waitForSleepers()
        await transcriber.stop()
        #expect(!transcriber.isRunning)
        // The cancelled replay's sleeper goes away; nothing more is emitted.
        while clock.sleeperCount > 0 { await Task.yield() }
        clock.advance(by: .seconds(10))
        #expect(transcriber.emittedStepCount == 1)

        try await transcriber.start()
        #expect(transcriber.startCount == 2)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == script.steps[1].event)
    }

    @Test func startingTwiceDoesNotReplayTwice() async throws {
        let clock = ManualClock()
        let transcriber = FakeTranscriber(script: .speaking(["x"], wordDuration: .seconds(1)), clock: clock)
        try await transcriber.start()
        try await transcriber.start()
        await clock.waitForSleepers()
        #expect(clock.sleeperCount == 1)
        #expect(transcriber.startCount == 1)
        transcriber.finish()
    }

    @Test func finishEndsTheStreamEarly() async throws {
        let clock = ManualClock()
        let transcriber = FakeTranscriber(script: .sample, clock: clock)
        try await transcriber.start()
        transcriber.finish()
        var iterator = transcriber.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        try await transcriber.start()
        #expect(!transcriber.isRunning, "a finished transcriber can't restart")
    }

    @Test func startErrorIsThrown() async {
        let transcriber = FakeTranscriber(
            script: .sample, startError: ServiceUnavailableError(subsystem: "transcription"))
        await #expect(throws: ServiceUnavailableError(subsystem: "transcription")) {
            try await transcriber.start()
        }
        #expect(!transcriber.isRunning)
    }

    @Test func recordsLifecycleTransitions() async {
        let transcriber = FakeTranscriber(script: .sample)
        let transition = AppPhaseTransition(from: .active, to: .background)
        await transcriber.appPhaseDidChange(transition)
        #expect(transcriber.receivedTransitions == [transition])
    }
}
