import BlauCore
import Foundation
import Synchronization

/// An ``EnrollmentAudioSource`` that synthesizes speech-like audio, for
/// tests, previews and UI tests (no microphone).
///
/// Each subscription to ``frames()`` (one per enrollment clip) plays the
/// next ``Voice`` in the script: a lead-in of room noise, then "syllables"
/// (bursts of a harmonic tone at the voice's fundamental) separated by short
/// pauses, then silence. ``ScriptedSpeakerEmbedder`` maps the fundamental to
/// a speaker, so a script can put a different speaker on one clip.
public final class ScriptedEnrollmentAudio: EnrollmentAudioSource {
    /// One clip's synthetic voice.
    public struct Voice: Hashable, Sendable {
        /// The tone's fundamental in Hz: the "speaker".
        public var fundamental: Double
        /// Peak amplitude of a syllable (0.1 is about -23 dBFS RMS).
        public var amplitude: Float
        /// Peak amplitude of the background noise.
        public var noise: Float
        /// Room noise before the speech starts.
        public var leadIn: Duration
        /// How long the syllables go on.
        public var speech: Duration

        public init(
            fundamental: Double = 140, amplitude: Float = 0.1, noise: Float = 0.0005,
            leadIn: Duration = .milliseconds(600),
            speech: Duration = .seconds(6)
        ) {
            self.fundamental = fundamental
            self.amplitude = amplitude
            self.noise = noise
            self.leadIn = leadIn
            self.speech = speech
        }

        /// The default voice.
        public static let owner = Voice()
        /// Someone else.
        public static let other = Voice(fundamental: 230)
        /// Background only: no speech.
        public static let silence = Voice(speech: .zero)
    }

    private struct State {
        var started = false
        var startCount = 0
        var stopCount = 0
        var subscriptions = 0
    }

    private let voices: [Voice]
    private let frameInterval: Duration?
    private let clock: any BlauClock
    private let state = Mutex(State())
    private let startError: (any Error & Sendable)?

    /// - Parameters:
    ///   - voices: The voice of each clip in turn; the last one repeats.
    ///   - speed: Real-time multiple for pacing frames on `clock`; `nil`
    ///     yields frames as fast as they are read (unit tests).
    ///   - clock: Paces the frames.
    ///   - startError: Thrown by ``start()``, to simulate a denied
    ///     microphone.
    public init(
        voices: [Voice] = [.owner], speed: Double? = 1, clock: any BlauClock = SystemClock(),
        startError: (any Error & Sendable)? = nil
    ) {
        precondition(!voices.isEmpty, "The script needs at least one voice")
        self.voices = voices
        self.frameInterval = speed.map { .milliseconds(20) / $0 }
        self.clock = clock
        self.startError = startError
    }

    /// How often ``start()`` and ``stop()`` were called.
    public var startCount: Int { state.withLock { $0.startCount } }
    public var stopCount: Int { state.withLock { $0.stopCount } }
    public var isStarted: Bool { state.withLock { $0.started } }

    public func start() async throws {
        if let startError { throw startError }
        state.withLock {
            $0.started = true
            $0.startCount += 1
        }
    }

    public func stop() async {
        state.withLock {
            $0.started = false
            $0.stopCount += 1
        }
    }

    public func frames() -> AsyncStream<AudioFrame> {
        let index = state.withLock { state in
            defer { state.subscriptions += 1 }
            return state.subscriptions
        }
        let synthesizer = SynthesizerBox(
            Synthesizer(voice: voices[min(index, voices.count - 1)], seed: UInt64(index + 1)))
        let interval = frameInterval
        let clock = clock
        return AsyncStream(unfolding: {
            if let interval {
                do { try await clock.sleep(for: interval) } catch { return nil }
            }
            return synthesizer.next()
        })
    }

    private final class SynthesizerBox: Sendable {
        private let synthesizer: Mutex<Synthesizer>
        init(_ synthesizer: Synthesizer) { self.synthesizer = Mutex(synthesizer) }
        func next() -> AudioFrame { synthesizer.withLock { $0.next() } }
    }

    /// Renders a voice into 20 ms frames.
    struct Synthesizer: Sendable {
        static let frameLength = 320
        static let sampleRate = AudioFrame.captureSampleRate
        /// A syllable and the pause after it.
        static let syllable = 180
        static let pause = 70

        let voice: Voice
        var random: UInt64
        var offset: Int64 = 0

        init(voice: Voice, seed: UInt64) {
            self.voice = voice
            self.random = seed &* 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> AudioFrame {
            var samples = [Float](repeating: 0, count: Self.frameLength)
            let leadIn = Int64(voice.leadIn.sampleCount(sampleRate: Self.sampleRate))
            let speechEnd = leadIn + voice.speech.sampleCount(sampleRate: Self.sampleRate)
            let msPerSample = 1000.0 / Double(Self.sampleRate)
            for index in samples.indices {
                let position = offset + Int64(index)
                var value = voice.noise * nextNoise()
                if position >= leadIn, position < speechEnd {
                    let milliseconds = Int(Double(position - leadIn) * msPerSample)
                    let cycle = milliseconds % (Self.syllable + Self.pause)
                    if cycle < Self.syllable {
                        let time = Double(position) / Double(Self.sampleRate)
                        let envelope = Float(sin(Double.pi * Double(cycle) / Double(Self.syllable)))
                        let tone =
                            sin(2 * .pi * voice.fundamental * time) + 0.5 * sin(4 * .pi * voice.fundamental * time)
                        value += voice.amplitude * envelope * Float(tone / 1.5)
                    }
                }
                samples[index] = value
            }
            let frame = AudioFrame(samples: samples, sampleRate: Self.sampleRate, sampleOffset: offset)
            offset += Int64(Self.frameLength)
            return frame
        }

        /// Uniform noise in -1...1 (xorshift).
        mutating func nextNoise() -> Float {
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            return Float(Double(random % 2_000_001) / 1_000_000 - 1)
        }
    }
}
