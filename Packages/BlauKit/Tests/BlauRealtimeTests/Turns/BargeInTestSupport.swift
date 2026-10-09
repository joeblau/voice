import BlauAudio
import BlauCore
import Foundation
import Synchronization

@testable import BlauRealtime

// MARK: - Fakes

/// Stands in for the turn orchestrator: says whether Grok is speaking and
/// records each barge-in.
final class FakeBargeInTarget: BargeInTarget {
    private struct State {
        var speaking = true
        var triggers: [BargeInTrigger] = []
    }

    private let state = Mutex(State())
    private let changes = AsyncStream.makeStream(of: Bool.self)

    var triggers: [BargeInTrigger] { state.withLock { $0.triggers } }

    func setSpeaking(_ speaking: Bool) {
        state.withLock { $0.speaking = speaking }
    }

    /// Sets whether Grok is speaking and tells `agentSpeakingChanges()`,
    /// as the orchestrator's state change would.
    func announceSpeaking(_ speaking: Bool) {
        setSpeaking(speaking)
        changes.continuation.yield(speaking)
    }

    func agentSpeakingChanges() -> AsyncStream<Bool> { changes.stream }

    var isAgentSpeaking: Bool {
        get async { state.withLock { $0.speaking } }
    }

    func bargeIn(_ trigger: BargeInTrigger) async -> BargeInRecord? {
        state.withLock { state in
            guard state.speaking else { return nil }
            state.triggers.append(trigger)
            state.speaking = false
            return BargeInRecord(turn: 1, trigger: trigger, cut: [], cancelledResponse: true, reactionTime: .zero)
        }
    }
}

/// How long "the agent" has been audible, set by the test.
final class FakePlayback: AgentPlaybackObserving {
    private let audible = Mutex<Duration?>(nil)

    init(audible: Duration?) {
        self.audible.withLock { $0 = audible }
    }

    func set(audible: Duration?) {
        self.audible.withLock { $0 = audible }
    }

    var audibleDuration: Duration? { audible.withLock { $0 } }
}

/// A capture history with fixed contents from sample 0.
final class FakeMicrophone: CaptureFrameSource {
    let samples: [Float]

    init(_ samples: [Float]) {
        self.samples = samples
    }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        AsyncStream { $0.finish() }
    }

    func history(in range: Range<Int64>) -> AudioFrame? {
        let lower = max(0, Int(range.lowerBound))
        let upper = min(samples.count, Int(range.upperBound))
        guard lower < upper else { return nil }
        return AudioFrame(samples: Array(samples[lower..<upper]), sampleOffset: Int64(lower), hostTime: nil)
    }
}

/// Voice ID's verdict, fixed by the test.
struct FakeSpeakerGate: BargeInSpeakerGate {
    var decision: SpeakerDecision?

    func bargeInDecision(for onset: SpeechOnset) async -> SpeakerDecision? { decision }
}

// MARK: - Signals

/// Builds 16 kHz test signals out of tones at given RMS levels.
enum MicSignal {
    static let rate = AudioFrame.captureSampleRate

    /// `seconds` of a 220 Hz tone whose RMS is `decibels` dBFS.
    static func tone(_ decibels: Float, seconds: Double) -> [Float] {
        let amplitude = Float(2).squareRoot() * pow(10, decibels / 20)
        let count = Int(seconds * Double(rate))
        return (0..<count).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    /// Speech-like echo: alternating 100 ms syllables at `loud` and `soft`
    /// dBFS, as the agent's voice leaks through the echo canceller.
    static func echo(loud: Float, soft: Float, seconds: Double) -> [Float] {
        var samples: [Float] = []
        var loudNext = true
        while Double(samples.count) < seconds * Double(rate) {
            samples += tone(loudNext ? loud : soft, seconds: 0.1)
            loudNext.toggle()
        }
        return Array(samples.prefix(Int(seconds * Double(rate))))
    }

    /// The agent's voice leaking through with normal speech pauses: 120 ms
    /// syllables at `syllable` dBFS, then 180 ms of pause at `pause` dBFS
    /// (the noise floor). The typical (median) level is the pause; VAD trips
    /// on the syllables.
    static func leak(syllable: Float, pause: Float, seconds: Double) -> [Float] {
        var samples: [Float] = []
        while Double(samples.count) < seconds * Double(rate) {
            samples += tone(syllable, seconds: 0.12)
            samples += tone(pause, seconds: 0.18)
        }
        return Array(samples.prefix(Int(seconds * Double(rate))))
    }

    /// `seconds` of the room's noise floor (fully cancelled echo, nobody
    /// talking).
    static func floor(seconds: Double) -> [Float] { tone(-65, seconds: seconds) }

    /// Sample offset of `seconds`.
    static func offset(_ seconds: Double) -> Int64 { Int64((seconds * Double(rate)).rounded()) }
}

extension SpeechOnset {
    /// An onset at `start` seconds, confirmed at `detected` seconds.
    static func at(_ start: Double, detected: Double, segment: Int = 0) -> SpeechOnset {
        SpeechOnset(
            segmentID: segment, startOffset: MicSignal.offset(start), sampleRate: MicSignal.rate,
            isContinuation: false, detectedAt: MicSignal.offset(detected))
    }
}

extension SpeechSegment {
    /// Segment `id`, from `start` to `end` seconds, ended by silence.
    static func ended(_ id: Int, from start: Double, to end: Double) -> SpeechSegment {
        SpeechSegment(
            id: id, sampleRange: MicSignal.offset(start)..<MicSignal.offset(end), sampleRate: MicSignal.rate,
            endReason: .silence, detectedAt: MicSignal.offset(end + 0.3), peakProbability: 0.9,
            meanProbability: 0.8)
    }
}
