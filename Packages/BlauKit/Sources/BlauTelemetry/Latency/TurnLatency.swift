import Foundation

/// The moments one turn passed through, on the pipeline's monotonic clock
/// (`BlauClock.uptime`; `SystemClock` in the app, whose readings every
/// stage shares).
///
/// The streaming transcriber supplies the first two (`LatencyMarks`), the
/// turn orchestrator the commit and the first audio delta, and the playback
/// engine the first rendered frame (`PlayedItem.firstRenderedAt`).
public struct TurnLatencyTimeline: Sendable, Hashable {
    /// When the last sample of the user's speech was captured: the
    /// utterance's end on the audio timeline, placed on the uptime timeline
    /// from the capture's host time. `nil` when the transcriber doesn't
    /// report it (Apple's `SpeechTranscriber` fallback).
    public var endOfSpeech: Duration?
    /// When the transcriber decided the utterance had ended and emitted
    /// its final.
    public var endOfUtterance: Duration?
    /// When the turn orchestrator committed the utterance to Grok.
    public var committed: Duration
    /// When the reply's first `response.output_audio.delta` arrived.
    public var firstAudio: Duration?
    /// When the reply's first frame was rendered for the output.
    public var firstBuffer: Duration?

    public init(
        endOfSpeech: Duration? = nil, endOfUtterance: Duration? = nil, committed: Duration,
        firstAudio: Duration? = nil, firstBuffer: Duration? = nil
    ) {
        self.endOfSpeech = endOfSpeech
        self.endOfUtterance = endOfUtterance
        self.committed = committed
        self.firstAudio = firstAudio
        self.firstBuffer = firstBuffer
    }

    /// How long `hop` took, or `nil` when one of its ends is unknown.
    /// Never negative: two stages' clocks can disagree by a tick, which is
    /// rounded to zero.
    public func duration(of hop: LatencyHop) -> Duration? {
        let span: (Duration?, Duration?) =
            switch hop {
            case .endOfUtterance: (endOfSpeech, endOfUtterance)
            case .voiceGate: (endOfUtterance, committed)
            case .firstAudio: (committed, firstAudio)
            case .firstBuffer: (firstAudio, firstBuffer)
            case .total: (endOfSpeech, firstBuffer)
            }
        guard let start = span.0, let end = span.1 else { return nil }
        return max(.zero, end - start)
    }
}

/// The audio hardware's own latency, which no signpost sees: from the
/// microphone to the capture timestamp, and from the rendered frame to the
/// speaker. `AVAudioSession.inputLatency`, `outputLatency` and
/// `ioBufferDuration` for the route in use.
///
/// Add `inputMilliseconds + outputMilliseconds` to a turn's total for what
/// a listener would measure acoustically, mouth to ear.
public struct AudioHardwareLatency: Codable, Sendable, Hashable {
    /// `AVAudioSession.inputLatency`, in milliseconds.
    public var inputMilliseconds: Double
    /// `AVAudioSession.outputLatency`, in milliseconds.
    public var outputMilliseconds: Double
    /// `AVAudioSession.ioBufferDuration`, in milliseconds: one I/O cycle.
    public var ioBufferMilliseconds: Double
    /// `AVAudioSession.sampleRate`, in hertz.
    public var sampleRate: Double
    /// The route's port kinds, e.g. `builtInMic -> builtInSpeaker`
    /// (`AudioRoute.summary`: no device names).
    public var route: String

    public init(
        inputMilliseconds: Double, outputMilliseconds: Double, ioBufferMilliseconds: Double, sampleRate: Double,
        route: String
    ) {
        self.inputMilliseconds = inputMilliseconds
        self.outputMilliseconds = outputMilliseconds
        self.ioBufferMilliseconds = ioBufferMilliseconds
        self.sampleRate = sampleRate
        self.route = route
    }

    /// Input plus output latency: what the hardware adds to a turn.
    public var roundTripMilliseconds: Double { inputMilliseconds + outputMilliseconds }
}

/// One measured turn: how long each hop took, in milliseconds, and the
/// audio route it ran on. What the latency report (`LatencyBudgetReport`)
/// is made of.
public struct TurnLatencySample: Codable, Sendable, Hashable {
    /// The turn's number in its conversation.
    public var turn: Int
    /// Wall-clock time the sample was taken.
    public var recordedAt: Date
    public var endOfUtteranceMilliseconds: Double?
    public var voiceGateMilliseconds: Double?
    public var firstAudioMilliseconds: Double?
    public var firstBufferMilliseconds: Double?
    public var totalMilliseconds: Double?
    /// The audio hardware's latency at the time, when known.
    public var hardware: AudioHardwareLatency?

    public init(
        turn: Int, recordedAt: Date, endOfUtteranceMilliseconds: Double? = nil,
        voiceGateMilliseconds: Double? = nil, firstAudioMilliseconds: Double? = nil,
        firstBufferMilliseconds: Double? = nil, totalMilliseconds: Double? = nil,
        hardware: AudioHardwareLatency? = nil
    ) {
        self.turn = turn
        self.recordedAt = recordedAt
        self.endOfUtteranceMilliseconds = endOfUtteranceMilliseconds
        self.voiceGateMilliseconds = voiceGateMilliseconds
        self.firstAudioMilliseconds = firstAudioMilliseconds
        self.firstBufferMilliseconds = firstBufferMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.hardware = hardware
    }

    /// The hops of `timeline`.
    public init(turn: Int, recordedAt: Date, timeline: TurnLatencyTimeline, hardware: AudioHardwareLatency? = nil) {
        self.init(
            turn: turn, recordedAt: recordedAt,
            endOfUtteranceMilliseconds: timeline.duration(of: .endOfUtterance)?.milliseconds,
            voiceGateMilliseconds: timeline.duration(of: .voiceGate)?.milliseconds,
            firstAudioMilliseconds: timeline.duration(of: .firstAudio)?.milliseconds,
            firstBufferMilliseconds: timeline.duration(of: .firstBuffer)?.milliseconds,
            totalMilliseconds: timeline.duration(of: .total)?.milliseconds,
            hardware: hardware)
    }

    /// How long `hop` took, in milliseconds, when it was measured.
    public func milliseconds(for hop: LatencyHop) -> Double? {
        switch hop {
        case .endOfUtterance: endOfUtteranceMilliseconds
        case .voiceGate: voiceGateMilliseconds
        case .firstAudio: firstAudioMilliseconds
        case .firstBuffer: firstBufferMilliseconds
        case .total: totalMilliseconds
        }
    }

    /// The total plus the hardware's input and output latency: end of
    /// speech at the microphone → the reply's first sound at the speaker.
    public var acousticTotalMilliseconds: Double? {
        guard let totalMilliseconds, let hardware else { return nil }
        return totalMilliseconds + hardware.roundTripMilliseconds
    }

    /// `end of speech → EOU 640 · gate 12 · first audio 610 · first buffer 45 · total 1307 ms`,
    /// for the log. Hops that weren't measured are left out.
    public var summary: String {
        let parts: [(String, Double?)] = [
            ("end of speech → EOU", endOfUtteranceMilliseconds),
            ("gate", voiceGateMilliseconds),
            ("first audio", firstAudioMilliseconds),
            ("first buffer", firstBufferMilliseconds),
            ("total", totalMilliseconds),
        ]
        let measured = parts.compactMap { label, value in value.map { "\(label) \(Int($0.rounded()))" } }
        return measured.isEmpty ? "no hops measured" : measured.joined(separator: " · ") + " ms"
    }
}
