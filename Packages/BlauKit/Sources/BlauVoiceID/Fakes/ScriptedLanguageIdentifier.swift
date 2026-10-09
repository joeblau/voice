import BlauCore
import Foundation
import Synchronization

/// A ``SpokenLanguageIdentifying`` without a model, for tests and previews.
///
/// It follows a script of who speaks which language when: the language whose
/// stretch of the timeline overlaps the audio most gets `confidence`, and the
/// rest is spread evenly over the other languages. Audio outside every
/// stretch is `fallback`.
public final class ScriptedLanguageIdentifier: SpokenLanguageIdentifying {
    /// A stretch of the timeline (16 kHz sample offsets) in one language.
    public struct Stretch: Sendable {
        public let samples: Range<Int64>
        public let language: SpokenLanguage
        /// The probability of `language`.
        public let confidence: Float
        /// The probability of English, when set: the rest is spread evenly
        /// over the other languages.
        public let english: Float?

        public init(samples: Range<Int64>, language: SpokenLanguage, confidence: Float = 0.95, english: Float? = nil) {
            self.samples = samples
            self.language = language
            self.confidence = confidence
            self.english = english
        }
    }

    private let timeline: [Stretch]
    private let fallback: SpokenLanguage
    private let delay: Duration
    private let clock: any BlauClock
    private let failure: (any Error)?
    private let calls = Mutex<[AudioFrame]>([])

    /// - Parameters:
    ///   - timeline: Who speaks which language when.
    ///   - fallback: The language of audio outside the timeline.
    ///   - delay: How long each call takes, on `clock`.
    ///   - failure: Thrown by every call instead, when set.
    public init(
        timeline: [Stretch] = [], fallback: SpokenLanguage = .english, delay: Duration = .zero,
        clock: any BlauClock = SystemClock(), failure: (any Error)? = nil
    ) {
        self.timeline = timeline
        self.fallback = fallback
        self.delay = delay
        self.clock = clock
        self.failure = failure
    }

    /// Every clip identified so far.
    public var identifiedAudio: [AudioFrame] { calls.withLock { $0 } }

    public func identify(_ audio: AudioFrame) async throws -> LanguageIdentification {
        calls.withLock { $0.append(audio) }
        if delay > .zero { try await clock.sleep(for: delay) }
        if let failure { throw failure }
        let range = audio.sampleOffset..<audio.nextSampleOffset
        let overlaps = timeline.map { stretch in
            (
                stretch,
                max(
                    0,
                    min(range.upperBound, stretch.samples.upperBound)
                        - max(range.lowerBound, stretch.samples.lowerBound))
            )
        }
        let best = overlaps.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
        return Self.identification(
            best?.language ?? fallback, confidence: best?.confidence ?? 0.95, english: best?.english,
            audioDuration: audio.duration)
    }

    /// `language` at `confidence` (and English at `english`, when set), the
    /// rest spread evenly.
    public static func identification(
        _ language: SpokenLanguage, confidence: Float, english: Float? = nil, audioDuration: Duration
    ) -> LanguageIdentification {
        var fixed: [SpokenLanguage: Float] = [language: confidence]
        if let english, language != .english { fixed[.english] = english }
        let rest = max(0, 1 - fixed.values.reduce(0, +)) / Float(SpokenLanguage.all.count - fixed.count)
        var probabilities: [SpokenLanguage: Float] = [:]
        for candidate in SpokenLanguage.all {
            probabilities[candidate] = fixed[candidate] ?? rest
        }
        return LanguageIdentification(probabilities: probabilities, audioDuration: audioDuration)
    }
}
