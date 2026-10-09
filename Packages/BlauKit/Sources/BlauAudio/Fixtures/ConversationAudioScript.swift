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
        /// The exchange's topic (`ScriptedConversation.Exchange.topic`).
        public let topic: String
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

    /// A stretch where the user says nothing, inserted after every few
    /// lines: someone else talking in the room (a TV), then silence. The
    /// long-session soak test (#76) plays one after every topic, so the
    /// pipeline hears background speech it must ignore and long silences
    /// it must sit through.
    public struct Interlude: Hashable, Sendable {
        /// An interlude comes before every `every`th line (never before the
        /// first), after the time left for the previous line's reply.
        public var every: Int
        /// Silence on both sides of the background speech, which keeps it
        /// apart from the user's lines.
        public var margin: Duration
        /// How long the background speech lasts: bursts of a few seconds
        /// with short pauses, like dialogue on a TV.
        public var background: Duration
        /// Room noise only, after the background speech.
        public var silence: Duration
        /// The background voice's gain relative to its clip (the user's
        /// voice plays at 1).
        public var backgroundGain: Float

        /// - Precondition: `every >= 1`.
        public init(
            every: Int = 6,
            margin: Duration = .seconds(2),
            background: Duration = .seconds(30),
            silence: Duration = .seconds(30),
            backgroundGain: Float = 0.5
        ) {
            precondition(every >= 1, "An interlude needs at least one line before it")
            self.every = every
            self.margin = margin
            self.background = background
            self.silence = silence
            self.backgroundGain = backgroundGain
        }

        /// The interlude's whole length.
        public var duration: Duration { margin + background + margin + silence }

        /// Thirty seconds of TV dialogue and thirty of silence every six
        /// lines: once per topic of the scripted conversation.
        public static let tvAndSilence = Interlude()
    }

    /// Who is speaking at some point of the script.
    public enum Talker: Hashable, Sendable {
        /// One of the user's lines.
        case user
        /// Background speech in an interlude.
        case background
        /// Nobody: room noise.
        case nobody
    }

    public static let sampleRate = AudioFrame.captureSampleRate

    public let lines: [Line]
    /// Background speech bursts (absolute 16 kHz sample ranges), in order.
    /// Empty without an interlude.
    public let backgroundBursts: [Range<Int64>]
    /// The length of the capture: the last reply and turn gap included.
    public let totalSamples: Int64
    /// Where the speech came from (`AudioFixture.source`).
    public var source: String {
        guard let topicVoice = topicVoices.values.first else { return voice.source }
        return "\(topicVoice.source), a clip per topic"
    }

    private let voice: AudioFixture
    private let topicVoices: [String: AudioFixture]
    private let backgroundVoice: AudioFixture
    private let backgroundGain: Float
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
    ///   - interlude: Background speech and silence between lines, or `nil`
    ///     (the default) for none.
    ///   - backgroundVoice: The speech the background is cut from, looped:
    ///     another speaker than `voice`.
    ///   - topicVoices: Speech to cut a topic's lines from instead of
    ///     `voice`, by topic name (`ScriptedConversation.Topic.name`), looped
    ///     the same way. For a real speech model: synthesized speech of the
    ///     topic's own sentences (`topicPassages(exchangesPerTopic:topics:)`)
    ///     gives it words to transcribe, and the topic segmenter the topic's
    ///     vocabulary. Topics without one use `voice`.
    public init(
        conversation: ScriptedConversation,
        timing: Timing = .standard,
        voice: AudioFixture = AudioFixture.syntheticSignal(duration: .seconds(12), pauses: false),
        noiseLevel: Float = 0.002,
        interlude: Interlude? = nil,
        backgroundVoice: AudioFixture = Self.defaultBackgroundVoice,
        topicVoices: [String: AudioFixture] = [:]
    ) {
        precondition(!voice.samples.isEmpty, "The voice clip must not be empty")
        precondition(!backgroundVoice.samples.isEmpty, "The background voice clip must not be empty")
        precondition(topicVoices.values.allSatisfy { !$0.samples.isEmpty }, "A topic's voice clip must not be empty")
        let rate = Self.sampleRate
        var position = timing.leadIn.sampleCount(sampleRate: rate)
        var lines: [Line] = []
        var bursts: [Range<Int64>] = []
        var burstRandom = SeededRandomGenerator(seed: 0x0007_E1E5)
        lines.reserveCapacity(conversation.exchanges.count)
        for exchange in conversation.exchanges {
            if let interlude, !lines.isEmpty, lines.count.isMultiple(of: interlude.every) {
                let start = position + interlude.margin.sampleCount(sampleRate: rate)
                bursts += Self.bursts(
                    from: start, lasting: interlude.background.sampleCount(sampleRate: rate), random: &burstRandom)
                position += interlude.duration.sampleCount(sampleRate: rate)
            }
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
                    exchange: exchange.index, topic: exchange.topic, text: words.joined(separator: " "),
                    sampleRange: start..<end,
                    words: aligned, reply: exchange.agent, replyDuration: replyDuration))
            position =
                end + (timing.responseDelay + replyDuration + timing.turnGap).sampleCount(sampleRate: rate)
        }
        self.lines = lines
        self.backgroundBursts = bursts
        self.totalSamples = position
        self.voice = voice
        self.topicVoices = topicVoices
        self.backgroundVoice = backgroundVoice
        self.backgroundGain = interlude?.backgroundGain ?? 0
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
        voice: AudioFixture = AudioFixture.syntheticSignal(duration: .seconds(12), pauses: false),
        interlude: Interlude? = nil,
        backgroundVoice: AudioFixture = Self.defaultBackgroundVoice,
        topicVoices: [String: AudioFixture] = [:]
    ) -> ConversationAudioScript {
        let target = duration.sampleCount(sampleRate: sampleRate)
        // Every exchange takes several seconds, so this many always suffice;
        // a shorter conversation is a prefix of a longer one with the same
        // seed, so the count can be cut afterwards.
        var upper = max(1, Int(duration / .seconds(4)) + 1)
        while true {
            let full = ConversationAudioScript(
                conversation: ScriptedConversation(exchanges: upper, exchangesPerTopic: exchangesPerTopic),
                timing: timing, voice: voice, interlude: interlude)
            // Where a script cut after each line ends: its reply and the
            // turn gap (the next line's start, unless an interlude comes
            // before it).
            let ends = full.lines.map { line in
                line.sampleRange.upperBound
                    + (timing.responseDelay + line.replyDuration + timing.turnGap).sampleCount(sampleRate: sampleRate)
            }
            if let last = ends.firstIndex(where: { $0 >= target }) {
                return ConversationAudioScript(
                    conversation: ScriptedConversation(exchanges: last + 1, exchangesPerTopic: exchangesPerTopic),
                    timing: timing, voice: voice, interlude: interlude, backgroundVoice: backgroundVoice,
                    topicVoices: topicVoices)
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
        // Speech where a line is spoken, from its topic's clip if it has
        // one. Each line starts at a different place in the clip so
        // consecutive lines don't sound alike.
        var lineIndex = firstLine(endingAfter: lower)
        while lineIndex < lines.count, lines[lineIndex].sampleRange.lowerBound < upper {
            let line = lines[lineIndex]
            let clip = topicVoices[line.topic]?.samples ?? voice.samples
            let clipCount = Int64(clip.count)
            let from = max(line.sampleRange.lowerBound, lower)
            let to = min(line.sampleRange.upperBound, upper)
            let clipStart = Int64(line.exchange) * 7_919
            for offset in from..<to {
                let clipIndex = Int((clipStart + offset - line.sampleRange.lowerBound) % clipCount)
                samples[Int(offset - lower)] += clip[clipIndex]
            }
            lineIndex += 1
        }
        // Background speech in the interludes, from another voice.
        if backgroundGain > 0 {
            let backgroundCount = Int64(backgroundVoice.samples.count)
            var burstIndex = firstBurst(endingAfter: lower)
            while burstIndex < backgroundBursts.count, backgroundBursts[burstIndex].lowerBound < upper {
                let burst = backgroundBursts[burstIndex]
                for offset in max(burst.lowerBound, lower)..<min(burst.upperBound, upper) {
                    samples[Int(offset - lower)] +=
                        backgroundVoice.samples[Int(offset % backgroundCount)] * backgroundGain
                }
                burstIndex += 1
            }
        }
        return samples
    }

    /// Who is speaking for most of `range`: the user, the background or
    /// nobody. A speech segment's voice ID verdict is checked against it.
    public func talker(in range: Range<Int64>) -> Talker {
        func overlap(_ other: Range<Int64>) -> Int64 {
            max(0, min(range.upperBound, other.upperBound) - max(range.lowerBound, other.lowerBound))
        }
        var user: Int64 = 0
        var lineIndex = firstLine(endingAfter: range.lowerBound)
        while lineIndex < lines.count, lines[lineIndex].sampleRange.lowerBound < range.upperBound {
            user += overlap(lines[lineIndex].sampleRange)
            lineIndex += 1
        }
        var background: Int64 = 0
        var burstIndex = firstBurst(endingAfter: range.lowerBound)
        while burstIndex < backgroundBursts.count, backgroundBursts[burstIndex].lowerBound < range.upperBound {
            background += overlap(backgroundBursts[burstIndex])
            burstIndex += 1
        }
        if user == 0 && background == 0 { return .nobody }
        return user >= background ? .user : .background
    }

    /// The default background voice: the synthetic speech signal with
    /// another seed and with pauses, like dialogue.
    public static let defaultBackgroundVoice = AudioFixture.syntheticSignal(
        duration: .seconds(12), seed: 0x0007_1EE5, pauses: true)

    /// Text to synthesize each topic's voice from (`topicVoices`): the
    /// user's lines of the topic's first visit in a `ScriptedConversation`
    /// with `exchangesPerTopic`, as sentences. Spoken, each is about half a
    /// minute of speech in the topic's vocabulary.
    public static func topicPassages(
        exchangesPerTopic: Int = 6, topics: [ScriptedConversation.Topic] = ScriptedConversation.standardTopics
    ) -> [String: String] {
        let conversation = ScriptedConversation(
            exchanges: exchangesPerTopic * topics.count, exchangesPerTopic: exchangesPerTopic, topics: topics)
        return Dictionary(grouping: conversation.exchanges, by: \.topic).mapValues { exchanges in
            exchanges.map { $0.user.hasSuffix(".") ? $0.user : $0.user + "." }.joined(separator: " ")
        }
    }

    /// Bursts of 3 to 8 seconds with 1 to 3 seconds between them, filling
    /// `length` samples from `start`.
    private static func bursts(
        from start: Int64, lasting length: Int64, random: inout SeededRandomGenerator
    ) -> [Range<Int64>] {
        let rate = Double(sampleRate)
        var bursts: [Range<Int64>] = []
        var position = start
        let end = start + length
        while position < end {
            let burstEnd = min(end, position + Int64(rate * (3 + 5 * random.nextUnit())))
            // A sliver under a second at the end isn't dialogue; leave it out.
            if burstEnd - position >= Int64(rate) {
                bursts.append(position..<burstEnd)
            }
            position = burstEnd + Int64(rate * (1 + 2 * random.nextUnit()))
        }
        return bursts
    }

    /// Index of the first background burst ending after `offset` (binary
    /// search; `backgroundBursts.count` if none).
    private func firstBurst(endingAfter offset: Int64) -> Int {
        var low = 0
        var high = backgroundBursts.count
        while low < high {
            let middle = (low + high) / 2
            if backgroundBursts[middle].upperBound <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
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
