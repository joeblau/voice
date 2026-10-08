import BlauCore
import Foundation

/// A scripted conversation's user side laid out on the 16 kHz capture
/// timeline: where each line is spoken, where each word ends, and the
/// microphone audio itself, generated on demand.
///
/// Built for replays of a whole session (the performance suite's scripted
/// session, #73): the audio a microphone would capture while the user reads
/// the lines, with Blau's reply in between. The reply plays through the
/// speaker; voice processing cancels it from the microphone, so the capture
/// holds only a faint noise floor while Blau speaks.
///
/// Speech comes from `voice`, a clip looped across the lines (by default
/// `AudioFixture.syntheticSignal`, which is hermetic; pass synthesized or
/// recorded speech for a real model). Nothing longer than `voice` and one
/// second of noise is ever stored, so an hour costs no more memory than a
/// minute.
///
/// ```swift
/// let script = ConversationAudioScript(conversation: ScriptedConversation(exchanges: 24))
/// let frame = script.frame(at: 0, length: 320)   // 20 ms of capture audio
/// ```
public struct ConversationAudioScript: Sendable {
    /// One spoken word and where it ends on the capture timeline.
    public struct Word: Hashable, Sendable {
        public let text: String
        /// Absolute sample offset where the word ends.
        public let end: Int64
        /// Whether it is the line's last word.
        public let endsLine: Bool
    }

    /// One user line: what is said and when.
    public struct Line: Hashable, Sendable {
        /// The exchange it belongs to (`ScriptedConversation.Exchange.index`).
        public let exchange: Int
        public let text: String
        /// The speech, in absolute 16 kHz sample offsets.
        public let sampleRange: Range<Int64>
        public let words: [Word]
        /// Blau's reply to it.
        public let reply: String
        /// How long the reply takes to say: the silence the script leaves
        /// for it.
        public let replyDuration: Duration
    }

    /// How the lines are spaced.
    public struct Timing: Hashable, Sendable {
        /// Silence before the first line.
        public var leadIn: Duration
        /// How long the user takes per word.
        public var userWordDuration: Duration
        /// Silence after a line before Blau answers: end-of-utterance
        /// detection plus Grok's time to first audio.
        public var responseDelay: Duration
        /// How long Blau takes per word of its reply.
        public var agentWordDuration: Duration
        /// Silence after Blau's reply before the user speaks again.
        public var turnGap: Duration

        public init(
            leadIn: Duration = .seconds(1),
            userWordDuration: Duration = .milliseconds(320),
            responseDelay: Duration = .milliseconds(1_200),
            agentWordDuration: Duration = .milliseconds(340),
            turnGap: Duration = .milliseconds(900)
        ) {
            self.leadIn = leadIn
            self.userWordDuration = userWordDuration
            self.responseDelay = responseDelay
            self.agentWordDuration = agentWordDuration
            self.turnGap = turnGap
        }

        public static let standard = Timing()
    }

    public static let sampleRate = AudioFrame.captureSampleRate

    public let lines: [Line]
    /// The length of the capture: the last reply and turn gap included.
    public let totalSamples: Int64
    /// Where the speech came from (`AudioFixture.source`).
    public var source: String { voice.source }

    private let voice: AudioFixture
    private let noise: [Float]

    /// - Parameters:
    ///   - conversation: What is said.
    ///   - timing: How the lines are spaced.
    ///   - voice: The speech every line is cut from, looped. Must not be
    ///     empty.
    ///   - noiseLevel: RMS of the room noise between lines: about -54 dBFS
    ///     by default, a quiet room through voice processing. It stays above
    ///     the VAD's model-skip level (-65 dBFS), so voice activity
    ///     detection analyses the gaps and tracks a real noise floor, as it
    ///     does live.
    public init(
        conversation: ScriptedConversation,
        timing: Timing = .standard,
        voice: AudioFixture = AudioFixture.syntheticSignal(duration: .seconds(12), pauses: false),
        noiseLevel: Float = 0.002
    ) {
        precondition(!voice.samples.isEmpty, "The voice clip must not be empty")
        let rate = Self.sampleRate
        var position = timing.leadIn.sampleCount(sampleRate: rate)
        var lines: [Line] = []
        lines.reserveCapacity(conversation.exchanges.count)
        for exchange in conversation.exchanges {
            let words = ScriptedConversation.words(in: exchange.user)
            guard !words.isEmpty else { continue }
            let wordSamples = timing.userWordDuration.sampleCount(sampleRate: rate)
            let start = position
            let aligned = words.enumerated().map { index, word in
                Word(
                    text: String(word), end: start + wordSamples * Int64(index + 1), endsLine: index == words.count - 1)
            }
            let end = aligned.last!.end
            let replyWords = ScriptedConversation.words(in: exchange.agent).count
            let replyDuration = timing.agentWordDuration * replyWords
            lines.append(
                Line(
                    exchange: exchange.index, text: words.joined(separator: " "), sampleRange: start..<end,
                    words: aligned, reply: exchange.agent, replyDuration: replyDuration))
            position =
                end + (timing.responseDelay + replyDuration + timing.turnGap).sampleCount(sampleRate: rate)
        }
        self.lines = lines
        self.totalSamples = position
        self.voice = voice
        var random = SeededRandomGenerator(seed: 0x0015_E5EE)
        // Uniform noise in ±a has an RMS of a / √3.
        let amplitude = noiseLevel * Float(3.0.squareRoot())
        self.noise = (0..<rate).map { _ in Float(random.nextUnit() * 2 - 1) * amplitude }
    }

    /// A script of at least `duration` of capture: the fewest exchanges of
    /// `ScriptedConversation` whose last reply ends at or after it.
    public static func session(
        lasting duration: Duration,
        exchangesPerTopic: Int = 6,
        timing: Timing = .standard,
        voice: AudioFixture = AudioFixture.syntheticSignal(duration: .seconds(12), pauses: false)
    ) -> ConversationAudioScript {
        let target = duration.sampleCount(sampleRate: sampleRate)
        // Every exchange takes several seconds, so this many always suffice;
        // a shorter conversation is a prefix of a longer one with the same
        // seed, so the count can be cut afterwards.
        var upper = max(1, Int(duration / .seconds(4)) + 1)
        while true {
            let full = ConversationAudioScript(
                conversation: ScriptedConversation(exchanges: upper, exchangesPerTopic: exchangesPerTopic),
                timing: timing, voice: voice)
            let ends = full.lines.indices.map { index in
                index + 1 < full.lines.count ? full.lines[index + 1].sampleRange.lowerBound : full.totalSamples
            }
            if let last = ends.firstIndex(where: { $0 >= target }) {
                return ConversationAudioScript(
                    conversation: ScriptedConversation(exchanges: last + 1, exchangesPerTopic: exchangesPerTopic),
                    timing: timing, voice: voice)
            }
            upper *= 2
        }
    }

    public var duration: Duration { .samples(totalSamples, sampleRate: Self.sampleRate) }

    /// Every word of every line, in order.
    public var words: [Word] { lines.flatMap(\.words) }

    /// The capture audio in `range` (clamped to the script).
    public func samples(in range: Range<Int64>) -> [Float] {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, totalSamples)
        guard lower < upper else { return [] }
        var samples = [Float](repeating: 0, count: Int(upper - lower))
        // Noise everywhere, looped from one second.
        let noiseCount = Int64(noise.count)
        for index in samples.indices {
            samples[index] = noise[Int((lower + Int64(index)) % noiseCount)]
        }
        // Speech where a line is spoken. Each line starts at a different
        // place in the voice clip so consecutive lines don't sound alike.
        let voiceCount = Int64(voice.samples.count)
        var lineIndex = firstLine(endingAfter: lower)
        while lineIndex < lines.count, lines[lineIndex].sampleRange.lowerBound < upper {
            let line = lines[lineIndex]
            let from = max(line.sampleRange.lowerBound, lower)
            let to = min(line.sampleRange.upperBound, upper)
            let clipStart = Int64(line.exchange) * 7_919
            for offset in from..<to {
                let clipIndex = Int((clipStart + offset - line.sampleRange.lowerBound) % voiceCount)
                samples[Int(offset - lower)] += voice.samples[clipIndex]
            }
            lineIndex += 1
        }
        return samples
    }

    /// `length` samples of capture audio starting at `offset`, as the
    /// capture engine would deliver them (shorter at the end).
    public func frame(at offset: Int64, length: Int) -> AudioFrame {
        AudioFrame(samples: samples(in: offset..<(offset + Int64(length))), sampleOffset: offset)
    }

    /// The line being spoken at `offset`, if any.
    public func line(at offset: Int64) -> Line? {
        let index = firstLine(endingAfter: offset)
        guard index < lines.count, lines[index].sampleRange.contains(offset) else { return nil }
        return lines[index]
    }

    /// Index of the first line whose speech ends after `offset` (binary
    /// search; `lines.count` if none).
    private func firstLine(endingAfter offset: Int64) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].sampleRange.upperBound <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
