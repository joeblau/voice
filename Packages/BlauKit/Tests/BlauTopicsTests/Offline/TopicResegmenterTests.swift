import BlauCore
import BlauTopics
import Foundation
import Testing

/// The re-segmentation engine's rules (#55), one at a time, on synthetic
/// embeddings: topic `t` points along axis `t` plus seeded noise
/// (`TopicVectors`), so every test is deterministic.
@Suite("TopicResegmenter")
struct TopicResegmenterTests {
    /// About as much noise per exchange as the distance between two
    /// topics, as with real exchange embeddings. With less, any mix of two
    /// topics in one stretch is a clear change.
    static let noise: Float = 0.45

    /// Embeddings and time ranges for `topics` (one topic index per unit).
    static func conversation(
        _ topics: [Int], every spacing: Duration = .seconds(20), seed: UInt64 = 52
    ) -> (embeddings: [[Float]], timeRanges: [TimeRange]) {
        var vectors = TopicVectors(noise: Self.noise, seed: seed)
        let embeddings = topics.map { vectors.vector($0) }
        let timeRanges = makeUnits(topics.count, every: spacing).map(\.timeRange)
        return (embeddings, timeRanges)
    }

    static func topics(_ segments: (topic: Int, count: Int)...) -> [Int] {
        segments.flatMap { Array(repeating: $0.topic, count: $0.count) }
    }

    static func resegment(
        _ topics: [Int],
        boundaries: [Int],
        locked: [Range<Int>] = [],
        pinned: Set<Int> = [],
        every spacing: Duration = .seconds(20),
        configuration: TopicResegmenter.Configuration = .standard
    ) -> TopicResegmentation {
        let (embeddings, timeRanges) = conversation(topics, every: spacing)
        return TopicResegmenter(configuration: configuration).resegment(
            embeddings: embeddings, timeRanges: timeRanges, boundaries: boundaries, locked: locked, pinned: pinned)
    }

    // MARK: Leaving good topics alone

    @Test func aCorrectSegmentationIsUnchanged() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [8, 16])
        #expect(result.isUnchanged)
        #expect(result.boundaries == [8, 16])
        #expect(result.original == [8, 16])
    }

    @Test(arguments: 1...20)
    func oneTopicIsNeverSplit(seed: Int) {
        let (embeddings, timeRanges) = Self.conversation(Self.topics((0, 40)), seed: UInt64(seed))
        let result = TopicResegmenter().resegment(embeddings: embeddings, timeRanges: timeRanges, boundaries: [])
        #expect(result.boundaries.isEmpty)
    }

    // MARK: Merge

    /// The streaming segmenter split a topic where a two-exchange digression
    /// started; with the whole conversation in view both sides are the
    /// same topic, so the break goes.
    @Test func aBreakAtADigressionIsMergedAway() {
        let result = Self.resegment(Self.topics((0, 8), (1, 2), (0, 8)), boundaries: [8])
        #expect(result.changes == [.removed(8)])
        #expect(result.boundaries.isEmpty)
    }

    @Test func aBreakBetweenTwoPartsOfOneTopicIsMergedAway() {
        let result = Self.resegment(Self.topics((0, 16), (1, 8)), boundaries: [7, 16])
        #expect(result.changes == [.removed(7)])
        #expect(result.boundaries == [16])
    }

    // MARK: Move

    @Test func aBoundaryTwoExchangesLateMovesToTheChange() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8)), boundaries: [10])
        #expect(result.changes == [.moved(from: 10, to: 8)])
        #expect(result.boundaries == [8])
    }

    @Test func aBoundaryOneExchangeEarlyMovesToTheChange() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [7, 16])
        #expect(result.changes == [.moved(from: 7, to: 8)])
    }

    @Test func movesStayWithinTheRadius() {
        var configuration = TopicResegmenter.Configuration.standard
        configuration.moveRadius = 0
        let result = Self.resegment(Self.topics((0, 8), (1, 8)), boundaries: [10], configuration: configuration)
        #expect(result.boundaries == [10])
    }

    // MARK: Split

    @Test func aMissedChangeOfSubjectIsAdded() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [8])
        #expect(result.changes == [.added(16)])
        #expect(result.boundaries == [8, 16])
    }

    /// TreeSeg's divisive step recurses into both halves.
    @Test func severalMissedChangesAreAddedTopDown() {
        let result = Self.resegment(Self.topics((0, 6), (1, 6), (2, 6), (3, 6)), boundaries: [])
        #expect(result.boundaries == [6, 12, 18])
        #expect(result.changes == [.added(6), .added(12), .added(18)])
    }

    @Test func aNewTopicMustHaveTheMinimumNumberOfExchanges() {
        // Three exchanges of the new subject at the end: too short.
        let result = Self.resegment(Self.topics((0, 10), (1, 3)), boundaries: [])
        #expect(result.boundaries.isEmpty)
    }

    @Test func aNewTopicMustLastTheMinimumDuration() {
        // Five 10-second exchanges: 50 s, under the 60 s minimum. A cut
        // there would be clearer, but the new topic would be too short; one
        // a little earlier is long enough.
        let short = Self.resegment(Self.topics((0, 10), (1, 5)), boundaries: [], every: .seconds(10))
        #expect(!short.boundaries.contains(10))
        for boundary in short.boundaries {
            #expect(boundary <= 9, "The topic from \(boundary) is under 60 s")
        }
        let long = Self.resegment(Self.topics((0, 10), (1, 7)), boundaries: [], every: .seconds(10))
        #expect(long.boundaries == [10])
    }

    @Test func theShortestTopicComesFromTheSegmentersConfig() {
        var topicConfig = TopicConfig.default
        topicConfig.minimumTopicUnits = 2
        topicConfig.minimumTopicDuration = .seconds(30)
        let configuration = TopicResegmenter.Configuration.standard.matching(topicConfig)
        #expect(configuration.minimumTopicUnits == 2)
        #expect(configuration.minimumTopicDuration == .seconds(30))
        #expect(configuration.splitThreshold == TopicResegmenter.Configuration.standard.splitThreshold)

        let result = Self.resegment(Self.topics((0, 10), (1, 3)), boundaries: [], configuration: configuration)
        #expect(result.boundaries == [10])
    }

    // MARK: What the user owns

    @Test func aLockedTopicIsNeverSplit() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8)), boundaries: [], locked: [0..<16])
        #expect(result.isUnchanged)
    }

    @Test func theEdgesOfALockedTopicNeverMoveOrGoAway() {
        // The break at the digression would be merged away, and the one at
        // 10 moved to 8, if the topics around them weren't locked.
        let merge = Self.resegment(Self.topics((0, 8), (1, 2), (0, 8)), boundaries: [8], locked: [0..<8])
        #expect(merge.isUnchanged)
        let move = Self.resegment(Self.topics((0, 8), (1, 8)), boundaries: [10], locked: [10..<16])
        #expect(move.isUnchanged)
    }

    @Test func aBoundaryNeverMovesIntoALockedTopic() {
        let result = Self.resegment(
            Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [7, 16], locked: [16..<24])
        #expect(result.changes == [.moved(from: 7, to: 8)])
        // The free topics around a locked one can still be fixed.
        let split = Self.resegment(Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [16], locked: [16..<24])
        #expect(split.changes == [.added(8)])
    }

    @Test func aPinnedBoundaryStays() {
        let result = Self.resegment(Self.topics((0, 8), (1, 2), (0, 8)), boundaries: [8], pinned: [8])
        #expect(result.isUnchanged)
    }

    // MARK: Input

    @Test func inconsistentInputIsLeftUnchanged() {
        let (embeddings, timeRanges) = Self.conversation(Self.topics((0, 8), (1, 2), (0, 8)))
        let resegmenter = TopicResegmenter()
        // A locked range that isn't a whole topic.
        #expect(
            resegmenter.resegment(
                embeddings: embeddings, timeRanges: timeRanges, boundaries: [8], locked: [2..<5]
            ).isUnchanged)
        // Time ranges that don't match the embeddings.
        #expect(
            resegmenter.resegment(
                embeddings: embeddings, timeRanges: Array(timeRanges.dropLast()), boundaries: [8]
            ).isUnchanged)
        // Embeddings of different lengths.
        var mixed = embeddings
        mixed[3] = [1, 0]
        #expect(resegmenter.resegment(embeddings: mixed, timeRanges: timeRanges, boundaries: [8]).isUnchanged)
        // Nothing to work with.
        #expect(resegmenter.resegment(embeddings: [], timeRanges: [], boundaries: []).boundaries.isEmpty)
    }

    @Test func boundariesAreNormalized() {
        let result = Self.resegment(Self.topics((0, 8), (1, 8), (2, 8)), boundaries: [16, 0, 8, 8, 24, 99])
        #expect(result.original == [8, 16])
        #expect(result.isUnchanged)
    }

    @Test func isDeterministic() {
        let topics = Self.topics((0, 8), (1, 2), (0, 8), (3, 9), (4, 7))
        let first = Self.resegment(topics, boundaries: [8, 21])
        let second = Self.resegment(topics, boundaries: [8, 21])
        #expect(first == second)
    }

    /// A two-hour conversation (400 exchanges, 1,024-d like the lexical
    /// embedder, 20 topics) the streaming segmenter got badly wrong: every
    /// other boundary missing and a false one inside every remaining topic.
    /// Re-segmentation runs once per conversation, off the audio path;
    /// measured 0.5 s in a debug build on an M3 Max (budget 2 s here).
    @Test func aLongConversationIsQuick() {
        var vectors = TopicVectors(dimension: 1024, noise: 0.03, seed: 7)
        let topics = (0..<400).map { $0 / 20 }
        let embeddings = topics.map { vectors.vector($0) }
        let timeRanges = makeUnits(400).map(\.timeRange)
        let streaming = stride(from: 40, to: 400, by: 40).flatMap { [$0, $0 + 10] }
        let clock = ContinuousClock()
        var result: TopicResegmentation?
        let elapsed = clock.measure {
            result = TopicResegmenter().resegment(
                embeddings: embeddings, timeRanges: timeRanges, boundaries: streaming)
        }
        #expect(result?.boundaries == Array(stride(from: 20, to: 400, by: 20)), "\(String(describing: result))")
        #expect(elapsed < .seconds(2), "Took \(elapsed)")
        if ProcessInfo.processInfo.environment["BLAU_PRINT_RESEGMENTATION"] == "1" {
            print("Re-segmented 400 exchanges in \(elapsed)")
        }
    }

    @Test func configurationValidation() {
        #expect(TopicResegmenter.Configuration.standard.validationError == nil)
        var configuration = TopicResegmenter.Configuration.standard
        configuration.mergeThreshold = configuration.splitThreshold + 1
        #expect(configuration.validationError != nil)
        configuration = .standard
        configuration.splitThreshold = 0
        #expect(configuration.validationError != nil)
        configuration = .standard
        configuration.moveRadius = -1
        #expect(configuration.validationError != nil)
        configuration = .standard
        configuration.minimumTopicUnits = 0
        #expect(configuration.validationError != nil)
    }
}
