import BlauCore
import Foundation
import Synchronization

@testable import BlauVoiceID

/// Who is talking when, on the capture timeline, and what voice ID scores
/// them: the script behind ``ScriptedVerifier``.
struct SpeakerTimeline: Sendable {
    /// A talker's scores: `short` for embeddings under 3 s, `long` from 3 s.
    struct Voice: Sendable, Hashable {
        var short: Float
        var long: Float

        /// The owner, close to the phone: accepted at once.
        static let owner = Voice(short: 0.62, long: 0.70)
        /// The owner across the room: uncertain at 1.5 s, accepted at 3 s.
        static let ownerFar = Voice(short: 0.30, long: 0.48)
        /// A TV, a podcast or someone else: rejected.
        static let other = Voice(short: 0.05, long: 0.08)
        /// Someone who sounds a bit like the owner: uncertain throughout.
        static let borderline = Voice(short: 0.30, long: 0.33)
        /// Uncertain at 1.5 s, rejected at 3 s.
        static let fadingOut = Voice(short: 0.30, long: 0.10)
    }

    var parts: [(start: Double, end: Double, voice: Voice)]

    init(_ parts: [(start: Double, end: Double, voice: Voice)]) {
        self.parts = parts
    }

    /// The voice at `seconds`, if anyone talks then.
    func voice(at seconds: Double) -> Voice? {
        parts.first { $0.start <= seconds && seconds < $0.end }?.voice
    }
}

/// Scores speech from a ``SpeakerTimeline`` instead of a model, with the
/// calibrated thresholds, after an optional delay.
final class ScriptedVerifier: SpeechVerifying {
    let timeline: SpeakerTimeline
    let config: VoiceIDConfig
    let delay: Duration
    let clock: any BlauClock
    /// Speech that fails to embed, by start time in seconds.
    let failing: Set<Double>
    private let recorded = Mutex<[Range<Int64>]>([])
    private let silences = Mutex<[Int]>([])

    init(
        _ timeline: SpeakerTimeline, config: VoiceIDConfig = .calibrated, delay: Duration = .zero,
        clock: any BlauClock = SystemClock(), failing: Set<Double> = []
    ) {
        self.timeline = timeline
        self.config = config
        self.delay = delay
        self.clock = clock
        self.failing = failing
    }

    /// The sample ranges scored, in order.
    var calls: [Range<Int64>] { recorded.withLock { $0 } }
    /// How many samples of each scored range were exactly zero (silence the
    /// gate filled in), in the order of ``calls``.
    var silentSamples: [Int] { silences.withLock { $0 } }

    func verify(_ speech: AudioFrame) async throws -> SpeakerScore {
        recorded.withLock { $0.append(speech.sampleOffset..<speech.nextSampleOffset) }
        let silent = speech.samples.reduce(0) { $1 == 0 ? $0 + 1 : $0 }
        silences.withLock { $0.append(silent) }
        if delay > .zero { try await clock.sleep(for: delay) }
        let start = Double(speech.sampleOffset) / Double(speech.sampleRate)
        guard !failing.contains(start) else { throw SpeakerEmbedderError.invalidOutput }
        let voice = timeline.voice(at: start) ?? SpeakerTimeline.Voice(short: 0, long: 0)
        let score = speech.duration >= .seconds(3) ? voice.long : voice.short
        let thresholds = config.thresholds(forAudioDuration: speech.duration)
        return SpeakerScore(
            score: score, decision: thresholds.decision(for: score), audioDuration: speech.duration,
            thresholds: thresholds)
    }
}

/// VAD's speech-audio events for scripted segments.
enum SpeechScript {
    static let rate = AudioFrame.captureSampleRate

    static func offset(_ seconds: Double) -> Int64 { Int64((seconds * Double(rate)).rounded()) }

    static func onset(_ id: Int, at start: Double, continuation: Bool = false) -> SpeechOnset {
        SpeechOnset(
            segmentID: id, startOffset: offset(start), sampleRate: rate, isContinuation: continuation,
            detectedAt: offset(start) + offset(0.3))
    }

    static func ended(_ id: Int, from start: Double, to end: Double, reason: SpeechSegment.EndReason = .silence)
        -> SpeechSegment
    {
        SpeechSegment(
            id: id, sampleRange: offset(start)..<offset(end), sampleRate: rate, endReason: reason,
            detectedAt: offset(end) + offset(0.3), peakProbability: 0.9, meanProbability: 0.8)
    }

    /// Audio from `start` to `end` in 100 ms frames (`samples` fills them,
    /// by absolute sample offset).
    static func audio(
        from start: Double, to end: Double, samples: (@Sendable (Int64) -> Float)? = nil
    ) -> [SpeechAudioEvent] {
        var events: [SpeechAudioEvent] = []
        var position = offset(start)
        let stop = offset(end)
        while position < stop {
            let count = Int(min(Int64(rate / 10), stop - position))
            let values = (0..<count).map { samples?(position + Int64($0)) ?? 0.01 }
            events.append(.audio(AudioFrame(samples: values, sampleOffset: position)))
            position += Int64(count)
        }
        return events
    }

    /// A whole segment: its start, its audio through the 300 ms hangover,
    /// and its end.
    static func segment(
        _ id: Int, from start: Double, to end: Double, continuation: Bool = false,
        samples: (@Sendable (Int64) -> Float)? = nil
    ) -> [SpeechAudioEvent] {
        [.started(onset(id, at: start, continuation: continuation))]
            + audio(from: start, to: end + 0.3, samples: samples)
            + [.ended(ended(id, from: start, to: end))]
    }
}

/// A final utterance from `start` to `end` seconds on the capture timeline.
func finalUtterance(_ text: String, from start: Double, to end: Double) -> Utterance {
    Utterance(
        conversationID: ConversationID(), speaker: .user, text: text,
        timeRange: TimeRange(
            start: .samples(SpeechScript.offset(start), sampleRate: SpeechScript.rate),
            end: .samples(SpeechScript.offset(end), sampleRate: SpeechScript.rate)),
        startedAt: Date(timeIntervalSinceReferenceDate: start))
}

extension VerificationGate {
    /// Feeds `events` in order.
    func feed(_ events: [SpeechAudioEvent]) async {
        for event in events {
            await handle(event)
        }
    }
}
