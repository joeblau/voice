import BlauCore
import BlauTelemetry

/// What a realtime session costs, for the performance HUD's estimate.
///
/// Blau's sessions run with `turn_detection: null` and send the user's
/// words as text, so the bill is the reply audio (per minute) plus one
/// text-input charge per user text item. The estimate counts the audio
/// received, which includes replies cut short by barge-in: Grok generated
/// (and bills) them whether or not they were heard.
public struct RealtimePricing: Sendable, Hashable {
    /// US dollars per minute of speech-to-speech audio.
    public var audioPerMinuteUSD: Double
    /// US dollars per text input.
    public var textInputUSD: Double

    public init(audioPerMinuteUSD: Double, textInputUSD: Double) {
        self.audioPerMinuteUSD = audioPerMinuteUSD
        self.textInputUSD = textInputUSD
    }

    /// xAI's published speech-to-speech rates for `grok-voice-think-fast-2.0`
    /// ($0.08 per minute of audio, $0.004 per text input), from
    /// https://docs.x.ai/developers/pricing as of 2026-10-07. Update them
    /// with the pinned model.
    public static let grokVoice = RealtimePricing(audioPerMinuteUSD: 0.08, textInputUSD: 0.004)

    /// The estimated cost of `usage`, in US dollars.
    public func estimatedCost(of usage: RealtimeUsageTotals) -> Double {
        let minutes = usage.outputAudio.timeInterval / 60
        return minutes * audioPerMinuteUSD + Double(usage.textInputs) * textInputUSD
    }
}

extension TurnSnapshot {
    /// Fills the voice loop's part of the performance HUD: turn state,
    /// connection, session continuity, end of utterance → first audio and
    /// turn time (last / p50 / p95), tokens, the cost estimate and
    /// barge-ins.
    public func fill(_ readings: inout PipelineReadings, pricing: RealtimePricing = .grokVoice) {
        var state = self.state.name
        if queuedUtterances > 0 {
            state += " (\(queuedUtterances) queued)"
        }
        readings.turnState = state
        readings.connection = TurnHUDReadout.describe(connection)
        readings.session = TurnHUDReadout.describe(session)
        readings.firstAudio = LatencyStats(
            last: latency.firstAudio.last, samples: latency.firstAudio.samples,
            totalCount: latency.firstAudio.totalCount)
        readings.turnTime = LatencyStats(
            last: latency.turn.last, samples: latency.turn.samples, totalCount: latency.turn.totalCount)
        readings.usage = PipelineReadings.Usage(
            inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, responses: usage.responses,
            estimatedCostUSD: pricing.estimatedCost(of: usage))
        readings.bargeIn = TurnHUDReadout.describe(bargeIns: bargeIns, last: lastBargeIn)
    }
}
