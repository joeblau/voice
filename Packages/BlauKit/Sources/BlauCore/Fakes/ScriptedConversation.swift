import Foundation

/// A deterministic, multi-topic conversation between the user and Blau, for
/// replays and benchmarks: the performance suite's scripted session (#73)
/// and the topic engine's micro-benchmarks.
///
/// Each topic has its own vocabulary, so consecutive exchanges about one
/// topic share content words and a topic change drops that overlap, which
/// is what the topic segmenter (TextTiling depth) looks for. The same
/// `seed` and sizes give the same text on every run and platform.
///
/// ```swift
/// let conversation = ScriptedConversation(exchanges: 24, exchangesPerTopic: 6)
/// for exchange in conversation.exchanges {
///     print(exchange.topic, exchange.user, exchange.agent)
/// }
/// ```
public struct ScriptedConversation: Hashable, Sendable {
    /// A subject the conversation can be about, with the words that make it
    /// recognizable.
    public struct Topic: Hashable, Sendable {
        public let name: String
        public let words: [String]

        public init(name: String, words: [String]) {
            precondition(words.count >= 4, "A topic needs at least four words")
            self.name = name
            self.words = words
        }
    }

    /// One exchange: what the user says and what Blau answers.
    public struct Exchange: Hashable, Sendable {
        /// Position in the conversation, from 0.
        public let index: Int
        /// The topic's `name`.
        public let topic: String
        /// Whether this exchange opens a new topic (the first exchange
        /// does).
        public let startsTopic: Bool
        public let user: String
        public let agent: String

        public init(index: Int, topic: String, startsTopic: Bool, user: String, agent: String) {
            self.index = index
            self.topic = topic
            self.startsTopic = startsTopic
            self.user = user
            self.agent = agent
        }
    }

    public let exchanges: [Exchange]

    /// - Parameters:
    ///   - exchanges: How many exchanges.
    ///   - exchangesPerTopic: Exchanges before the conversation moves on to
    ///     the next topic.
    ///   - topics: The topics, visited in order and then again from the
    ///     start.
    ///   - seed: Picks the sentences and words.
    /// - Precondition: `exchanges >= 0`, `exchangesPerTopic > 0` and
    ///   `topics` is not empty.
    public init(
        exchanges count: Int,
        exchangesPerTopic: Int = 6,
        topics: [Topic] = ScriptedConversation.standardTopics,
        seed: UInt64 = 0xB1A0_5C21
    ) {
        precondition(count >= 0, "The exchange count can't be negative")
        precondition(exchangesPerTopic > 0, "Each topic needs at least one exchange")
        precondition(!topics.isEmpty, "A conversation needs at least one topic")
        var random = SeededRandomGenerator(seed: seed)
        var exchanges: [Exchange] = []
        exchanges.reserveCapacity(count)
        for index in 0..<count {
            let topicIndex = (index / exchangesPerTopic) % topics.count
            let topic = topics[topicIndex]
            let startsTopic = index % exchangesPerTopic == 0
            var user = Self.fill(random.pick(Self.userTemplates), from: topic, using: &random)
            if startsTopic, index > 0 {
                user = "Let's switch gears and talk about the \(topic.name). " + user
            }
            let agent = Self.fill(random.pick(Self.agentTemplates), from: topic, using: &random)
            exchanges.append(
                Exchange(index: index, topic: topic.name, startsTopic: startsTopic, user: user, agent: agent))
        }
        self.exchanges = exchanges
    }

    /// Every word the user says, in order.
    public var userWordCount: Int {
        exchanges.reduce(0) { $0 + Self.words(in: $1.user).count }
    }

    /// The words of `text`, split on whitespace.
    public static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// Replaces each `{}` in `template` with a different word of `topic`.
    private static func fill(
        _ template: String, from topic: Topic, using random: inout SeededRandomGenerator
    ) -> String {
        var words = random.shuffled(topic.words)[...]
        var result = ""
        var remainder = template[...]
        while let range = remainder.range(of: "{}") {
            result += remainder[..<range.lowerBound]
            if words.isEmpty { words = random.shuffled(topic.words)[...] }
            result += words.removeFirst()
            remainder = remainder[range.upperBound...]
        }
        return result + remainder
    }

    static let userTemplates = [
        "I keep thinking about the {} and whether the {} is ready before the {}",
        "Can you help me plan the {} so the {} and the {} line up this week",
        "What should I change about the {} if the {} keeps slipping behind the {}",
        "Remind me what we decided about the {} and why the {} mattered for the {}",
        "I talked to the team about the {} today and the {} came up again with the {}",
        "How would you compare the {} with the {} given what we know about the {}",
    ]

    static let agentTemplates = [
        "Start with the {}. The {} depends on it, so once that is settled the {} and the {} get much easier to judge.",
        "Last time you said the {} mattered most. I would compare the {} with the {} and keep the {} simple for now.",
        "It sounds like the {} is the real constraint. Write down what the {} needs, then decide on the {} and the {}.",
        "Two things stand out: the {} and the {}. If you fix those first, the {} should follow and the {} can wait.",
        "I would not change the {} yet. Look at how the {} behaved last week, then revisit the {} and the {} together.",
    ]

    /// Eight everyday topics with distinct vocabularies.
    public static let standardTopics: [Topic] = [
        Topic(
            name: "fundraising",
            words: [
                "investors", "seed round", "valuation", "term sheet", "pitch deck", "runway", "dilution",
                "lead investor",
                "safe notes", "board seat", "cap table", "warm intros",
            ]),
        Topic(
            name: "hiring",
            words: [
                "engineers", "interview loop", "offer letter", "recruiter", "job description", "onboarding",
                "referrals",
                "candidates", "salary bands", "equity grant", "take home", "hiring manager",
            ]),
        Topic(
            name: "marathon training",
            words: [
                "long run", "tempo pace", "running shoes", "hamstring", "recovery week", "race day", "intervals",
                "hydration", "mileage", "taper", "heart rate", "stretching",
            ]),
        Topic(
            name: "kitchen renovation",
            words: [
                "countertops", "cabinets", "contractor", "permit", "backsplash", "plumbing", "lighting", "appliances",
                "flooring", "budget overrun", "tile samples", "island",
            ]),
        Topic(
            name: "product launch",
            words: [
                "launch date", "beta testers", "landing page", "press kit", "app store listing", "pricing page",
                "waitlist", "release notes", "feature flags", "crash reports", "onboarding flow", "screenshots",
            ]),
        Topic(
            name: "travel to Japan",
            words: [
                "flights", "rail pass", "Kyoto", "ryokan", "itinerary", "ramen shops", "cherry blossoms", "luggage",
                "Shinkansen", "temples", "Osaka", "currency",
            ]),
        Topic(
            name: "learning piano",
            words: [
                "scales", "sight reading", "metronome", "chord voicings", "practice routine", "sonata", "left hand",
                "pedal", "teacher", "recital", "arpeggios", "sheet music",
            ]),
        Topic(
            name: "family budget",
            words: [
                "groceries", "mortgage", "savings account", "credit card", "childcare", "insurance", "utilities",
                "emergency fund", "spreadsheet", "subscriptions", "tax refund", "allowance",
            ]),
    ]
}

/// SplitMix64: a tiny, fast, seedable random number generator, so scripted
/// fixtures are identical on every run and platform.
public struct SeededRandomGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `0..<1`.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// A uniform integer in `0..<upperBound`. Unlike the standard library's
    /// `random(in:using:)`, the algorithm is fixed here, so the values never
    /// change with the toolchain.
    ///
    /// - Precondition: `upperBound > 0`.
    public mutating func nextIndex(below upperBound: Int) -> Int {
        precondition(upperBound > 0, "The upper bound must be positive")
        return Int(next() % UInt64(upperBound))
    }

    /// One element of `elements`.
    ///
    /// - Precondition: `elements` is not empty.
    public mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[nextIndex(below: elements.count)]
    }

    /// `elements` in a random order (Fisher-Yates with `nextIndex(below:)`).
    public mutating func shuffled<Element>(_ elements: [Element]) -> [Element] {
        var result = elements
        var index = result.count - 1
        while index > 0 {
            result.swapAt(index, nextIndex(below: index + 1))
            index -= 1
        }
        return result
    }
}
