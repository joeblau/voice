import BlauCore
import Foundation
import Testing

@testable import BlauTopics

/// The engine's rules, one at a time, on synthetic embeddings: topic `t` is a
/// vector along axis `t` plus seeded noise, so similarities are clear-cut
/// and every test is deterministic.
@Suite("TopicSegmenter")
struct TopicSegmenterTests {
    /// Runs `topics` (one topic index per unit) through a segmenter.
    static func run(
        _ topics: [Int],
        every spacing: Duration = .seconds(20),
        config: TopicConfig = .default,
        finish: Bool = true
    ) throws -> SegmenterRun {
        var vectors = TopicVectors()
        var run = SegmenterRun(config: config)
        for (unit, topic) in zip(makeUnits(topics.count, every: spacing), topics) {
            try run.append(unit, embedding: vectors.vector(topic))
        }
        if finish { run.finish() }
        return run
    }

    static func topics(_ segments: (topic: Int, count: Int)...) -> [Int] {
        segments.flatMap { Array(repeating: $0.topic, count: $0.count) }
    }

    /// Gates other than the one under test switched off.
    static var permissive: TopicConfig {
        var config = TopicConfig.default
        config.minimumSamples = 1
        config.minimumTopicUnits = 1
        config.minimumTopicDuration = .zero
        config.cooldown = .zero
        return config
    }

    // MARK: Basics

    @Test func oneTopicHasNoBoundaries() throws {
        let run = try Self.run(Self.topics((0, 30)))
        #expect(run.confirmed.isEmpty)
        #expect(run.segmenter.currentTopicStart == 0)
    }

    @Test func confirmsAShiftAtTheRightPlace() throws {
        let run = try Self.run(Self.topics((0, 8), (1, 8)))
        #expect(run.confirmedIndices == [8])
        let boundary = try #require(run.confirmed.first)
        #expect(boundary.closedTopic == 0..<8)
        #expect(boundary.time == .seconds(160))
        #expect(boundary.unitID == run.segmenter.units[8].id)
        #expect(boundary.score > boundary.threshold)
        #expect(run.segmenter.boundaries == [boundary])
        #expect(run.segmenter.currentTopicStart == 8)
    }

    @Test func findsEveryShiftInALongConversation() throws {
        let run = try Self.run(Self.topics((0, 7), (1, 6), (2, 9), (3, 5), (4, 8)))
        #expect(run.confirmedIndices == [7, 13, 22, 27])
    }

    @Test func confirmationWaitsForTheSustainUnits() throws {
        let config = TopicConfig.default
        let run = try Self.run(Self.topics((0, 8), (1, 8)))
        let confirmation = try #require(run.entries.first { if case .confirmed = $0.event { true } else { false } })
        // The dip at gap 8 is first scored when unit 8 + rightWindow - 1
        // arrives, then needs sustainUnits more.
        #expect(confirmation.afterUnit >= 8 + config.rightWindow - 1 + config.sustainUnits)
        let candidate = try #require(run.entries.first { if case .candidate = $0.event { true } else { false } })
        #expect(candidate.afterUnit < confirmation.afterUnit)
    }

    @Test func noCandidateBeforeTheStatisticsWarmUp() throws {
        var config = TopicConfig.default
        config.minimumTopicUnits = 1
        config.minimumTopicDuration = .zero
        // A shift right at the start: only scored once minimumSamples depths
        // have settled.
        let run = try Self.run(Self.topics((0, 2), (1, 12)), config: config)
        let first = try #require(run.entries.first)
        let settledAtFirstEvent = first.afterUnit - config.rightWindow - 1
        #expect(settledAtFirstEvent >= config.minimumSamples - 1)

        var segmenter = TopicSegmenter(config: config)
        #expect(segmenter.threshold == nil)
        var vectors = TopicVectors()
        for unit in makeUnits(4) {
            _ = try segmenter.append(unit, embedding: vectors.vector(0))
        }
        #expect(segmenter.depthStatistics.count < config.minimumSamples)
        #expect(segmenter.threshold == nil)
    }

    @Test func thresholdIsTheLargerOfTheFloorAndMuPlusKSigma() throws {
        let run = try Self.run(Self.topics((0, 8), (1, 8), (2, 8)))
        let statistics = run.segmenter.depthStatistics
        let config = run.segmenter.config
        let expected = max(
            config.minimumDepth,
            statistics.mean + config.thresholdSigmas * statistics.standardDeviation
        )
        #expect(abs(try #require(run.segmenter.threshold) - expected) < 1e-12)

        var floored = config
        floored.minimumDepth = 5
        let high = try Self.run(Self.topics((0, 8), (1, 8), (2, 8)), config: floored)
        #expect(high.segmenter.threshold == 5)
        #expect(high.candidates.isEmpty)
    }

    // MARK: Gates

    @Test func aTopicNeedsTheMinimumNumberOfUnits() throws {
        var config = Self.permissive
        config.minimumTopicUnits = 4
        let gated = try Self.run(Self.topics((0, 6), (1, 3), (2, 10)), config: config)
        #expect(gated.confirmedIndices.contains(6))
        #expect(!gated.confirmedIndices.contains(9))
        for boundary in gated.confirmed {
            #expect(boundary.closedTopic.count >= 4)
        }

        config.minimumTopicUnits = 2
        let loose = try Self.run(Self.topics((0, 6), (1, 3), (2, 10)), config: config)
        #expect(loose.confirmedIndices == [6, 9])
    }

    @Test func aTopicNeedsTheMinimumDuration() throws {
        var config = Self.permissive
        config.minimumTopicDuration = .seconds(60)
        // Five 10-second units is a 50-second topic.
        let gated = try Self.run(Self.topics((0, 6), (1, 5), (2, 10)), every: .seconds(10), config: config)
        #expect(!gated.confirmedIndices.contains(11))

        config.minimumTopicDuration = .seconds(40)
        let loose = try Self.run(Self.topics((0, 6), (1, 5), (2, 10)), every: .seconds(10), config: config)
        #expect(loose.confirmedIndices.contains(11))
    }

    @Test func theCooldownDelaysConfirmationButKeepsThePosition() throws {
        var config = Self.permissive
        config.cooldown = .seconds(200)
        let run = try Self.run(Self.topics((0, 8), (1, 6), (2, 22)), every: .seconds(10), config: config)
        #expect(run.confirmedIndices == [8, 14])

        let confirmations = run.entries.filter { if case .confirmed = $0.event { true } else { false } }
        let first = try #require(confirmations.first)
        let second = try #require(confirmations.last)
        // Units end at (index + 1) * 10 s, so the second confirmation can't
        // come before 200 s after the first one.
        let firstEnd = Duration.seconds(10 * (first.afterUnit + 1))
        let secondEnd = Duration.seconds(10 * (second.afterUnit + 1))
        #expect(secondEnd - firstEnd >= .seconds(200))

        config.cooldown = .zero
        let eager = try Self.run(Self.topics((0, 8), (1, 6), (2, 22)), every: .seconds(10), config: config)
        let eagerSecond = try #require(eager.entries.last { if case .confirmed = $0.event { true } else { false } })
        #expect(eagerSecond.afterUnit < second.afterUnit)
    }

    // MARK: Hysteresis

    @Test func aBriefDigressionIsRejectedAsARecovery() throws {
        let run = try Self.run(Self.topics((0, 8), (5, 2), (0, 6), (1, 8)))
        #expect(run.confirmedIndices == [16])
        #expect(run.rejections.map(\.reason) == [.recovered])
        let rejected = try #require(run.rejections.first?.boundary)
        #expect((7...9).contains(rejected.unitIndex))
    }

    @Test func theWayBackFromADigressionDoesNotRaiseAnotherCandidate() throws {
        let run = try Self.run(Self.topics((0, 8), (5, 2), (0, 12)))
        #expect(run.confirmed.isEmpty)
        #expect(run.candidates.count == 1)
    }

    @Test func aDigressionLongerThanTheSustainWindowBecomesATopic() throws {
        // Five exchanges on something else is a topic of its own, even if the
        // conversation comes back afterwards.
        let run = try Self.run(Self.topics((0, 8), (5, 5), (0, 8)))
        #expect(run.confirmedIndices == [8, 13])
    }

    /// After the digression the conversation only half returns (60 % old
    /// topic, 40 % digression). The default exit level (halfway back to the
    /// pre-dip peak) counts that as a recovery; a level at the peak itself
    /// doesn't, and the shift is confirmed.
    @Test func theExitLevelControlsHowFullARecoveryMustBe() throws {
        for (fraction, recovers) in [(0.5, true), (1.0, false)] {
            var config = TopicConfig.default
            config.recoveryFraction = fraction
            var vectors = TopicVectors()
            var run = SegmenterRun(config: config)
            for (index, unit) in makeUnits(18).enumerated() {
                let embedding =
                    switch index {
                    case ..<8: vectors.vector(0)
                    case 8..<10: vectors.vector(5)
                    default: vectors.vector(0, 0, 0, 5, 5)
                    }
                try run.append(unit, embedding: embedding)
            }
            let recovered = run.rejections.contains { $0.reason == .recovered }
            #expect(recovered == recovers, "recoveryFraction \(fraction)")
            #expect(run.confirmed.isEmpty == recovers, "recoveryFraction \(fraction)")
        }
    }

    // MARK: Retroactive placement

    @Test func theBoundaryLandsOnTheDeepestDip() throws {
        // A bridging exchange that touches both topics raises the candidate a
        // gap early; the boundary still lands where the new topic starts.
        var vectors = TopicVectors()
        var run = SegmenterRun()
        let units = makeUnits(18)
        for (index, unit) in units.enumerated() {
            let embedding =
                switch index {
                case ..<8: vectors.vector(0)
                case 8: vectors.vector(0, 0, 1)
                default: vectors.vector(1)
                }
            try run.append(unit, embedding: embedding)
        }
        let boundary = try #require(run.confirmed.first)
        let candidates = (8...10).compactMap { run.segmenter.gapScore(at: $0) }
        let deepest = try #require(candidates.max { $0.depth < $1.depth })
        #expect(boundary.unitIndex == deepest.gap)
    }

    // MARK: End of stream

    @Test func finishRejectsThePendingCandidate() throws {
        let run = try Self.run(Self.topics((0, 8), (1, 2)), finish: false)
        var segmenter = run.segmenter
        let pending = try #require(segmenter.pendingCandidate)
        #expect(segmenter.finish() == [.rejected(pending, reason: .endOfStream)])
        #expect(segmenter.pendingCandidate == nil)
        #expect(segmenter.finish().isEmpty)
    }

    @Test func appendingContinuesAfterFinish() throws {
        var run = try Self.run(Self.topics((0, 8), (1, 2)))
        var vectors = TopicVectors(seed: 99)
        for unit in makeUnits(20).dropFirst(10) {
            try run.append(unit, embedding: vectors.vector(1))
        }
        // finish() rejected the pending shift, but the dip is raised again
        // once units resume and the new topic is confirmed where it began.
        #expect(run.rejections.map(\.reason) == [.endOfStream])
        #expect(run.confirmedIndices == [8])
        #expect(run.segmenter.units.count == 20)
    }

    @Test func resumingAfterFinishMatchesAnUninterruptedRun() throws {
        let topics = Self.topics((0, 8), (1, 12))
        let uninterrupted = try Self.run(topics)

        var vectors = TopicVectors()
        var resumed = SegmenterRun()
        for (index, (unit, topic)) in zip(makeUnits(topics.count), topics).enumerated() {
            if index == 10 { resumed.finish() }
            try resumed.append(unit, embedding: vectors.vector(topic))
        }
        resumed.finish()

        #expect(resumed.confirmedIndices == uninterrupted.confirmedIndices)
        #expect(resumed.confirmedIndices == [8])
    }

    // MARK: Input validation

    @Test func rejectsBadEmbeddingsWithoutChangingState() throws {
        var segmenter = TopicSegmenter()
        let units = makeUnits(3)
        _ = try segmenter.append(units[0], embedding: [1, 0, 0])

        #expect(throws: TopicSegmenterError.emptyEmbedding) {
            try segmenter.append(units[1], embedding: [])
        }
        #expect(throws: TopicSegmenterError.dimensionMismatch(expected: 3, actual: 2)) {
            try segmenter.append(units[1], embedding: [1, 0])
        }
        #expect(throws: TopicSegmenterError.nonFiniteEmbedding) {
            try segmenter.append(units[1], embedding: [.nan, 0, 0])
        }
        #expect(segmenter.units.count == 1)
        _ = try segmenter.append(units[1], embedding: [0, 1, 0])
        #expect(segmenter.units.count == 2)
    }

    @Test func rejectsUnitsOutOfOrder() throws {
        var segmenter = TopicSegmenter()
        let units = makeUnits(3)
        _ = try segmenter.append(units[2], embedding: [1, 0])
        #expect(throws: TopicSegmenterError.outOfOrder(previousStart: .seconds(40), start: .seconds(20))) {
            try segmenter.append(units[1], embedding: [1, 0])
        }
        #expect(segmenter.units.count == 1)
    }

    @Test func zeroEmbeddingsDoNotCrash() throws {
        var segmenter = TopicSegmenter()
        for unit in makeUnits(12) {
            _ = try segmenter.append(unit, embedding: [0, 0, 0, 0])
        }
        #expect(segmenter.boundaries.isEmpty)
        #expect(segmenter.gapScore(at: 5)?.similarity == 0)
    }

    // MARK: Inspection

    @Test func gapScoresAreAvailableOnceTheRightWindowFills() throws {
        let run = try Self.run(Self.topics((0, 6)), finish: false)
        let latest = 6 - run.segmenter.config.rightWindow
        #expect(run.segmenter.gapScore(at: 0) == nil)
        #expect(run.segmenter.gapScore(at: latest + 1) == nil)
        let score = try #require(run.segmenter.gapScore(at: latest))
        #expect(score.gap == latest)
        #expect(score.depth >= 0)
        #expect(score.leftPeak >= score.similarity)
        #expect(score.rightPeak >= score.similarity)
    }

    @Test func runningStatisticsMatchTheDirectFormula() {
        var statistics = RunningStatistics()
        let values = [0.0, 0.5, 0.1, 0.9, 0.3, 0.3]
        for value in values { statistics.add(value) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        #expect(statistics.count == values.count)
        #expect(abs(statistics.mean - mean) < 1e-12)
        #expect(abs(statistics.standardDeviation - variance.squareRoot()) < 1e-12)
        #expect(RunningStatistics().standardDeviation == 0)
    }
}
