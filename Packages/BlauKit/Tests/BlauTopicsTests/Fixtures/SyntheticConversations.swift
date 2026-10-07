import BlauCore
import BlauTopics
import Foundation

/// Seeded, generated conversations for testing the segmenter on many more
/// transcripts than anyone would write by hand.
///
/// Each topic has its own vocabulary. An exchange mixes words from its
/// topic's vocabulary with filler, a few words every topic shares and the
/// odd word from another topic, so neighbouring topics overlap a little the
/// way real ones do. Some topics contain a two-exchange digression into
/// another topic that returns to the first one; the reference segmentation
/// doesn't count those as boundaries.
struct SyntheticConversation: Sendable {
    let units: [TopicUnit]
    let boundaries: [Int]
    let digressions: [Range<Int>]

    static let vocabularies: [[String]] = [
        [
            "sourdough", "starter", "flour", "dough", "loaf", "crust", "crumb", "yeast", "proof", "knead", "oven",
            "gluten", "bake", "rye", "levain", "scoring", "hydration", "banneton", "bread", "ferment",
        ],
        [
            "marathon", "mileage", "tempo", "interval", "stride", "cadence", "shoes", "pace", "taper", "hamstring",
            "runner", "race", "trail", "splits", "recovery", "sprint", "hill", "jog", "endurance", "finish",
        ],
        [
            "mortgage", "refinance", "lender", "escrow", "principal", "appraisal", "equity", "closing", "rate",
            "amortization", "points", "underwriting", "loan", "credit", "payment", "balance", "fixed", "adjustable",
            "title", "insurance",
        ],
        [
            "kubernetes", "pod", "container", "cluster", "deployment", "kubectl", "manifest", "autoscaler", "node",
            "ingress", "helm", "replica", "namespace", "probe", "rollout", "service", "image", "registry", "memory",
            "cpu",
        ],
        [
            "tomato", "garden", "compost", "seedling", "mulch", "pepper", "aphid", "prune", "harvest", "soil",
            "watering", "basil", "trellis", "weeds", "fertilizer", "raised", "bed", "sprout", "zucchini", "squash",
        ],
        [
            "japan", "tokyo", "kyoto", "osaka", "shinkansen", "temple", "shrine", "ramen", "sushi", "ryokan", "yen",
            "suica", "blossom", "nara", "hiroshima", "itinerary", "hotel", "train", "onsen", "sake",
        ],
        [
            "puppy", "leash", "crate", "treats", "recall", "obedience", "bark", "chew", "harness", "trainer",
            "sit", "heel", "potty", "kennel", "collar", "fetch", "socialize", "vet", "breed", "dog",
        ],
        [
            "podcast", "microphone", "episode", "audio", "editing", "guest", "listeners", "rss", "hosting",
            "interview", "recording", "intro", "transcript", "spotify", "headphones", "mixer", "sponsor",
            "download", "feed", "studio",
        ],
        [
            "piano", "scales", "chords", "metronome", "sheet", "music", "pedal", "keys", "fingering", "sonata",
            "practice", "teacher", "recital", "tempo", "melody", "octave", "rhythm", "arpeggio", "etude", "chopin",
        ],
        [
            "taxes", "deduction", "freelance", "irs", "refund", "receipts", "schedule", "estimated", "quarterly",
            "accountant", "filing", "income", "retirement", "ira", "withholding", "audit", "expense", "invoice",
            "bracket", "extension",
        ],
    ]

    /// Words every topic uses now and then.
    static let shared = ["plan", "week", "money", "home", "family", "weekend", "cost", "advice", "problem", "morning"]

    /// Filler the lexical embedder ignores.
    static let filler = [
        "yeah", "so", "the", "and", "i", "think", "really", "you", "know", "it", "is", "a", "to", "that", "what",
        "should", "about", "just", "like", "okay", "well", "maybe", "how", "do", "we",
    ]

    /// Generates a conversation of `topicCount` topics from `seed`.
    static func generate(seed: UInt64, topicCount: Int = 5, digressionProbability: Double = 0.3) -> Self {
        var random = SplitMix64(seed: seed)
        let topics = Array((0..<vocabularies.count).shuffled(using: &random).prefix(topicCount))
        var plan: [Int] = []
        var boundaries: [Int] = []
        var digressions: [Range<Int>] = []

        for (position, topic) in topics.enumerated() {
            if position > 0 { boundaries.append(plan.count) }
            let length = Int.random(in: 6...10, using: &random)
            let digressAt =
                Double.random(in: 0..<1, using: &random) < digressionProbability
                ? Int.random(in: 3...(length - 3), using: &random) : nil
            for index in 0..<length {
                if index == digressAt {
                    let other = (topic + Int.random(in: 1..<vocabularies.count, using: &random)) % vocabularies.count
                    digressions.append(plan.count..<(plan.count + 2))
                    plan.append(other)
                    plan.append(other)
                }
                plan.append(topic)
            }
        }

        var units: [TopicUnit] = []
        var clock = Duration.zero
        for (index, topic) in plan.enumerated() {
            let duration = Duration.seconds(Int.random(in: 14...30, using: &random))
            let user = sentence(topic: topic, words: Int.random(in: 8...14, using: &random), using: &random)
            let agent = sentence(topic: topic, words: Int.random(in: 14...26, using: &random), using: &random)
            units.append(
                TopicUnit(
                    id: UUID(),
                    userText: user,
                    agentText: agent,
                    timeRange: TimeRange(start: clock, duration: duration),
                    startedAt: Date(timeIntervalSinceReferenceDate: Double(index) * 20)
                )
            )
            clock += duration
        }
        return Self(units: units, boundaries: boundaries, digressions: digressions)
    }

    private static func sentence(topic: Int, words: Int, using random: inout SplitMix64) -> String {
        (0..<words).map { _ in
            let roll = Double.random(in: 0..<1, using: &random)
            return switch roll {
            case ..<0.40: vocabularies[topic].randomElement(using: &random)!
            case ..<0.85: filler.randomElement(using: &random)!
            case ..<0.95: shared.randomElement(using: &random)!
            default: vocabularies.randomElement(using: &random)!.randomElement(using: &random)!
            }
        }
        .joined(separator: " ")
    }
}
