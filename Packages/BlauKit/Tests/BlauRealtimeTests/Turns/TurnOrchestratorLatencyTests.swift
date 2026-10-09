import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// The latency budget (#74): each turn measured from the end of the user's
/// speech (the transcriber's `LatencyMarks`) to the reply's first rendered
/// frame (the player's `PlayedItem.firstRenderedAt`).
@Suite("Turn latency budget")
struct TurnOrchestratorLatencyTests {
    static let item = PlaybackItemID(itemID: "item_1")
    static let builtIn = AudioHardwareLatency(
        inputMilliseconds: 11, outputMilliseconds: 19, ioBufferMilliseconds: 10.7, sampleRate: 48_000,
        route: "builtInMic -> builtInSpeaker")

    /// Commits an utterance at uptime zero, after the transcriber decided
    /// its end at `endOfUtterance` (`nil`: no marks), and has Grok answer
    /// with audio `firstAudioAfter` the commit. Returns once the response
    /// is done; the reply is still "playing".
    static func answeredTurn(
        _ harness: TurnHarness, endOfSpeech: Duration? = .milliseconds(-640),
        endOfUtterance: Duration? = .milliseconds(-10), firstAudioAfter: Duration = .milliseconds(600)
    ) async throws -> FakeSocket {
        harness.audio.setIdle(false)
        let socket = try await harness.start()
        #expect(harness.clock.uptime == .zero)
        let question = harness.utterance("What should I focus on this week?", from: 0, to: 2)
        if let endOfUtterance {
            harness.latencyMarks.record(
                .init(endOfSpeech: endOfSpeech, endOfUtterance: endOfUtterance), for: question.id)
        }
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)

        harness.clock.advance(by: firstAudioAfter)
        for event in ServerEvents.reply(
            "Start with the launch checklist.", response: "resp_1", item: "item_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("response done") { await harness.snapshot().completedTurns == 1 }
        return socket
    }

    @Test func aTurnIsMeasuredFromTheEndOfSpeechToTheFirstRenderedFrame() async throws {
        let harness = TurnHarness()
        harness.latencyTracker.setHardwareLatencyProvider { Self.builtIn }
        _ = try await Self.answeredTurn(harness)
        #expect(harness.latencyMarks.count == 0, "The commit takes the marks")
        // Nothing is sampled until the reply's first frame has had its
        // chance to play.
        #expect(harness.latencyTracker.samples.isEmpty)

        harness.audio.setFirstRendered(Self.item, at: .milliseconds(640))
        harness.audio.setIdle(true)
        try await harness.waitForState(.listening)

        let sample = try #require(harness.latencyTracker.samples.first)
        #expect(harness.latencyTracker.samples.count == 1)
        #expect(sample.turn == 1)
        #expect(sample.endOfUtteranceMilliseconds == 630)
        #expect(sample.voiceGateMilliseconds == 10)
        #expect(sample.firstAudioMilliseconds == 600)
        #expect(sample.firstBufferMilliseconds == 40)
        #expect(sample.totalMilliseconds == 1_280)
        #expect(sample.hardware == Self.builtIn)
        #expect(sample.acousticTotalMilliseconds == 1_310)
        #expect(sample.recordedAt == turnT0.addingTimeInterval(0.6))

        // The HUD's windows.
        let snapshot = await harness.snapshot()
        #expect(snapshot.latency.endToEnd.last == .milliseconds(1_280))
        #expect(snapshot.latency.endOfUtterance.last == .milliseconds(630))
        #expect(snapshot.latency.voiceGate.last == .milliseconds(10))
        #expect(snapshot.latency.firstBuffer.last == .milliseconds(40))
        #expect(snapshot.latency.firstAudio.last == .milliseconds(600))
        var readings = PipelineReadings()
        snapshot.fill(&readings)
        #expect(readings.latencyHops[.total]?.p50 == 1_280)
        #expect(readings.latencyHops[.voiceGate]?.p50 == 10)
        #expect(Set(readings.latencyHops.keys) == Set(LatencyHop.allCases))

        // Within budget: no over-budget event.
        #expect(!harness.signposts.events.contains("realtime.overBudget"))
    }

    @Test func aTotalOverTheBudgetIsFlaggedInInstruments() async throws {
        let harness = TurnHarness()
        _ = try await Self.answeredTurn(harness, endOfSpeech: .milliseconds(-1_100), firstAudioAfter: .seconds(1))
        harness.audio.setFirstRendered(Self.item, at: .milliseconds(1_050))
        harness.audio.setIdle(true)
        try await harness.waitForState(.listening)

        #expect(harness.latencyTracker.samples.first?.totalMilliseconds == 2_150)
        #expect(harness.signposts.events.contains("realtime.overBudget"))
    }

    @Test func withoutTheTranscribersMarksOnlyTheHopsFromTheCommitCount() async throws {
        // Apple's SpeechTranscriber fallback, or a final sent directly.
        let harness = TurnHarness()
        _ = try await Self.answeredTurn(harness, endOfUtterance: nil)
        harness.audio.setFirstRendered(Self.item, at: .milliseconds(645))
        harness.audio.setIdle(true)
        try await harness.waitForState(.listening)

        let sample = try #require(harness.latencyTracker.samples.first)
        #expect(sample.endOfUtteranceMilliseconds == nil)
        #expect(sample.voiceGateMilliseconds == nil)
        #expect(sample.totalMilliseconds == nil)
        #expect(sample.firstAudioMilliseconds == 600)
        #expect(sample.firstBufferMilliseconds == 45)
        #expect(await harness.snapshot().latency.endToEnd.totalCount == 0)
    }

    @Test func aReplyCutByBargeInIsStillMeasured() async throws {
        let harness = TurnHarness()
        _ = try await Self.answeredTurn(harness)
        harness.audio.setFirstRendered(Self.item, at: .milliseconds(642))
        harness.audio.setPlayed(Self.item, milliseconds: 200)

        let trigger = BargeInTrigger(onset: .at(3.0, detected: 3.3, segment: 7), receivedAt: harness.clock.uptime)
        _ = try #require(await harness.orchestrator.bargeIn(trigger))

        let sample = try #require(harness.latencyTracker.samples.first)
        #expect(harness.latencyTracker.samples.count == 1)
        #expect(sample.firstBufferMilliseconds == 42)
        #expect(sample.totalMilliseconds == 1_282)
    }

    @Test func aReplyCutBeforeItsFirstFrameHasNoTotal() async throws {
        let harness = TurnHarness()
        _ = try await Self.answeredTurn(harness)
        let trigger = BargeInTrigger(onset: .at(3.0, detected: 3.3, segment: 7), receivedAt: harness.clock.uptime)
        _ = try #require(await harness.orchestrator.bargeIn(trigger))

        let sample = try #require(harness.latencyTracker.samples.first)
        #expect(sample.firstAudioMilliseconds == 600)
        #expect(sample.firstBufferMilliseconds == nil)
        #expect(sample.totalMilliseconds == nil)
    }

    @Test func aTextOnlyReplyIsNotATurnSample() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        let question = harness.utterance("Spell it", from: 0, to: 1)
        harness.latencyMarks.record(.init(endOfSpeech: .zero, endOfUtterance: .zero), for: question.id)
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)
        socket.push(ServerEvents.responseCreated("resp_1", turn: socket.turnTag()))
        socket.push(
            .responseOutputTextDelta(.init(responseID: "resp_1", itemID: "item_1", contentIndex: 0, delta: "B-L-A-U")))
        socket.push(ServerEvents.responseDone("resp_1"))
        try await waitUntil("completed") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)

        #expect(harness.latencyTracker.samples.isEmpty)
        #expect(harness.latencyMarks.count == 0)
    }

    @Test func aRejectedFinalsMarksAreDroppedToo() async throws {
        let harness = TurnHarness()
        _ = try await harness.start()
        let tv = harness.utterance("Breaking news", from: 0, to: 1, decision: .reject)
        harness.latencyMarks.record(.init(endOfSpeech: .zero, endOfUtterance: .zero), for: tv.id)
        await harness.orchestrator.handle(.final(tv))
        #expect(harness.latencyMarks.count == 0)
        #expect(harness.latencyTracker.samples.isEmpty)
    }
}
