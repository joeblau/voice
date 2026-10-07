import BlauCore
import BlauTelemetry
import Testing

@testable import BlauRealtime

@Suite("Realtime pricing and the HUD readings")
struct RealtimePricingTests {
    @Test func theEstimateBillsAudioMinutesAndTextInputs() {
        var usage = RealtimeUsageTotals()
        #expect(RealtimePricing.grokVoice.estimatedCost(of: usage) == 0)

        usage.outputAudio = .seconds(90)
        usage.textInputs = 10
        // 1.5 min x $0.08 + 10 x $0.004
        #expect(abs(RealtimePricing.grokVoice.estimatedCost(of: usage) - 0.16) < 1e-9)

        let custom = RealtimePricing(audioPerMinuteUSD: 1, textInputUSD: 0)
        #expect(abs(custom.estimatedCost(of: usage) - 1.5) < 1e-9)
    }

    @Test func theSnapshotFillsTheVoiceLoopRows() throws {
        var snapshot = TurnSnapshot(state: .agentThinking, connection: .connecting(attempt: 2), queuedUtterances: 1)
        var readings = PipelineReadings()
        snapshot.fill(&readings)
        #expect(readings.turnState == "agentThinking (1 queued)")
        #expect(readings.connection == "connecting (2)")
        #expect(readings.firstAudio == nil)
        #expect(readings.turnTime == nil)
        #expect(readings.usage?.estimatedCostUSD == 0)

        for milliseconds in [600, 700, 650, 900] {
            snapshot.latency.recordFirstAudio(.milliseconds(milliseconds))
        }
        snapshot.latency.recordTurn(.milliseconds(2_400))
        snapshot.usage.add(.init(inputTokens: 412, outputTokens: 96, totalTokens: 508))
        snapshot.usage.textInputs = 1
        snapshot.usage.outputAudio = .seconds(30)
        snapshot.fill(&readings)

        let firstAudio = try #require(readings.firstAudio)
        #expect(firstAudio.last == 900)
        #expect(firstAudio.p50 == 675)
        #expect(abs(firstAudio.p95 - 870) < 1e-9)
        #expect(firstAudio.totalCount == 4)
        #expect(readings.turnTime?.last == 2_400)
        let usage = try #require(readings.usage)
        #expect(usage.inputTokens == 412)
        #expect(usage.outputTokens == 96)
        #expect(usage.responses == 1)
        #expect(abs((usage.estimatedCostUSD ?? 0) - 0.044) < 1e-9)

        // The HUD shows the same numbers as the voice loop's own readout.
        let readout = PerformanceHUDReadout(PerformanceHUDSnapshot(pipeline: readings))
        #expect(readout.row("EOU → audio")?.value == TurnHUDReadout(snapshot).value(for: "EOU → audio"))
        #expect(readout.row("Tokens")?.value == "412 in · 96 out · 1 resp")
        #expect(readout.row("Cost")?.value == "$0.044 est.")
        #expect(readout.row("Session")?.value == "idle")
        #expect(readout.row("Barge-in")?.value == "–")
    }

    @Test func theSnapshotFillsSessionContinuityAndBargeIns() {
        var snapshot = TurnSnapshot(state: .listening, connection: .connected)
        snapshot.session.phase = .live
        snapshot.session.sessionAge = .seconds(42 * 60 + 10)
        snapshot.session.resumptions = 2
        snapshot.bargeIns = 2
        snapshot.lastBargeIn = BargeInRecord(
            turn: 3, trigger: BargeInTrigger(onset: .at(1.0, detected: 1.29), receivedAt: .seconds(4)), cut: [],
            cancelledResponse: true, reactionTime: .microseconds(420))
        var readings = PipelineReadings()
        snapshot.fill(&readings)
        #expect(readings.session == "live · 42 min · 2 resumed")
        #expect(readings.bargeIn == "2 · last 0.4 ms to flush (VAD +290 ms)")

        // The HUD shows the same rows as the voice loop's own readout.
        let readout = PerformanceHUDReadout(PerformanceHUDSnapshot(pipeline: readings))
        let voiceLoop = TurnHUDReadout(snapshot)
        #expect(readout.row("Session")?.value == voiceLoop.value(for: "Session"))
        #expect(readout.row("Barge-in")?.value == voiceLoop.value(for: "Barge-in"))
    }
}
