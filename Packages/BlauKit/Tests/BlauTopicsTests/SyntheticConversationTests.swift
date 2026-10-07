import BlauTopics
import Testing

/// The segmenter on 60 seeded, generated conversations (about 2,600
/// exchanges, 240 boundaries and 100 digressions), so the tuning isn't
/// overfitted to the hand-written fixtures.
@Suite("Synthetic conversations")
struct SyntheticConversationTests {
    struct Score {
        var pk = 0.0
        var windowDiff = 0.0
        var digressions = 0
        var splitDigressions = 0
        var conversations = 0
    }

    static func score(seeds: ClosedRange<UInt64>) throws -> Score {
        let embedder = LexicalTextEmbedder()
        var score = Score()
        for seed in seeds {
            let conversation = SyntheticConversation.generate(seed: seed)
            var run = SegmenterRun()
            for unit in conversation.units {
                try run.append(unit, embedding: embedder.vector(for: unit.text))
            }
            run.finish()

            let found = run.confirmedIndices
            let count = conversation.units.count
            score.pk += SegmentationMetrics.pk(reference: conversation.boundaries, hypothesis: found, count: count)
            score.windowDiff += SegmentationMetrics.windowDiff(
                reference: conversation.boundaries,
                hypothesis: found,
                count: count
            )
            for digression in conversation.digressions {
                score.digressions += 1
                let span = (digression.lowerBound - 1)...(digression.upperBound + 1)
                if found.contains(where: { span.contains($0) && !conversation.boundaries.contains($0) }) {
                    score.splitDigressions += 1
                }
            }
            score.conversations += 1
        }
        return score
    }

    @Test func meanErrorStaysLow() throws {
        let score = try Self.score(seeds: 1...60)
        let meanPk = score.pk / Double(score.conversations)
        let meanWindowDiff = score.windowDiff / Double(score.conversations)
        // Measured: Pk 0.030, WindowDiff 0.031.
        #expect(meanPk <= 0.06)
        #expect(meanWindowDiff <= 0.06)
    }

    @Test func digressionsRarelyBecomeTopics() throws {
        let score = try Self.score(seeds: 1...60)
        #expect(score.digressions >= 80)
        // Measured: 6 of 101.
        #expect(Double(score.splitDigressions) / Double(score.digressions) <= 0.1)
    }

    @Test func generationIsSeeded() {
        let first = SyntheticConversation.generate(seed: 7)
        let second = SyntheticConversation.generate(seed: 7)
        #expect(first.units.map(\.text) == second.units.map(\.text))
        #expect(first.boundaries == second.boundaries)
    }
}
