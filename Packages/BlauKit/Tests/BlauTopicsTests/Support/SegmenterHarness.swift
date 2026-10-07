import BlauCore
import BlauTopics
import Foundation

/// Runs units through a `TopicSegmenter` and keeps every event, tagged with
/// the index of the unit whose arrival produced it.
struct SegmenterRun {
    struct Entry: Equatable {
        let afterUnit: Int
        let event: TopicSegmentationEvent
    }

    var segmenter: TopicSegmenter
    private(set) var entries: [Entry] = []

    init(config: TopicConfig = .default) {
        segmenter = TopicSegmenter(config: config)
    }

    mutating func append(_ unit: TopicUnit, embedding: [Float]) throws {
        let index = segmenter.units.count
        for event in try segmenter.append(unit, embedding: embedding) {
            entries.append(Entry(afterUnit: index, event: event))
        }
    }

    mutating func finish() {
        let index = segmenter.units.count - 1
        for event in segmenter.finish() {
            entries.append(Entry(afterUnit: index, event: event))
        }
    }

    var events: [TopicSegmentationEvent] { entries.map(\.event) }

    var confirmed: [TopicBoundary] {
        events.compactMap { if case .confirmed(let boundary) = $0 { boundary } else { nil } }
    }

    var candidates: [TopicBoundary] {
        events.compactMap { if case .candidate(let boundary) = $0 { boundary } else { nil } }
    }

    var rejections: [(boundary: TopicBoundary, reason: TopicRejectionReason)] {
        events.compactMap { if case .rejected(let boundary, let reason) = $0 { (boundary, reason) } else { nil } }
    }

    var confirmedIndices: [Int] { confirmed.map(\.unitIndex) }

    /// Runs a scripted transcript through the lexical embedder.
    static func run(_ transcript: ScriptedTranscript, config: TopicConfig = .default) throws -> SegmenterRun {
        let embedder = LexicalTextEmbedder()
        var run = SegmenterRun(config: config)
        for unit in transcript.units() {
            try run.append(unit, embedding: embedder.vector(for: unit.text))
        }
        run.finish()
        return run
    }
}

/// Units on a regular timeline, for tests that supply their own embeddings.
func makeUnits(_ count: Int, every spacing: Duration = .seconds(20), userTexts: [Int: String] = [:]) -> [TopicUnit] {
    (0..<count).map { index in
        TopicUnit(
            userText: userTexts[index] ?? "unit \(index)",
            agentText: "",
            timeRange: TimeRange(start: spacing * index, duration: spacing),
            startedAt: Date(timeIntervalSinceReferenceDate: Double(index) * spacing.timeInterval)
        )
    }
}

/// Deterministic SplitMix64, so seeded tests produce the same data on every
/// run and platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Embeddings for synthetic topics: topic `t` points along axis `t`, plus a
/// little seeded noise on every axis.
struct TopicVectors {
    let dimension: Int
    let noise: Float
    private var generator: SplitMix64

    init(dimension: Int = 16, noise: Float = 0.15, seed: UInt64 = 52) {
        self.dimension = dimension
        self.noise = noise
        self.generator = SplitMix64(seed: seed)
    }

    /// A vector for `topic`, or the normalized blend when given several.
    mutating func vector(_ topics: Int...) -> [Float] {
        var vector = (0..<dimension).map { _ in Float.random(in: -noise...noise, using: &generator) }
        for topic in topics {
            vector[topic % dimension] += 1 / Float(topics.count)
        }
        return vector
    }
}
