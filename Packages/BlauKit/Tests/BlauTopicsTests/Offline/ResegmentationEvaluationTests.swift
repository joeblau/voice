import BlauCore
import BlauTopics
import Foundation
import Testing

/// The acceptance test for #55: on the fixture set (the five scripted
/// transcripts and the 60 synthetic conversations the streaming segmenter
/// is evaluated on), re-segmenting the streaming topics at the end lowers
/// Pk, and makes no conversation worse. A further 240 conversations the
/// thresholds weren't tuned on check that it generalizes.
///
/// All through `LexicalTextEmbedder`, so the numbers are the same on every
/// machine. docs/topics.md has the table.
@Suite("Offline re-segmentation evaluation")
struct ResegmentationEvaluationTests {
    struct Conversation {
        let name: String
        let units: [TopicUnit]
        let embeddings: [[Float]]
        let reference: [Int]
        let digressions: [Range<Int>]
        /// What the streaming segmenter confirmed.
        let streaming: [Int]

        var count: Int { units.count }

        func resegmented(_ configuration: TopicResegmenter.Configuration = .standard) -> TopicResegmentation {
            TopicResegmenter(configuration: configuration).resegment(
                embeddings: embeddings, timeRanges: units.map(\.timeRange), boundaries: streaming)
        }

        func pk(_ hypothesis: [Int]) -> Double {
            SegmentationMetrics.pk(reference: reference, hypothesis: hypothesis, count: count)
        }

        func windowDiff(_ hypothesis: [Int]) -> Double {
            SegmentationMetrics.windowDiff(reference: reference, hypothesis: hypothesis, count: count)
        }

        /// Digressions a hypothesis turned into a boundary.
        func splitDigressions(_ hypothesis: [Int]) -> Int {
            digressions.count { digression in
                let span = (digression.lowerBound - 1)...(digression.upperBound + 1)
                return hypothesis.contains { span.contains($0) && !reference.contains($0) }
            }
        }
    }

    static func streamed(
        name: String, units: [TopicUnit], reference: [Int], digressions: [Range<Int>]
    ) throws -> Conversation {
        let embedder = LexicalTextEmbedder()
        let embeddings = units.map { embedder.vector(for: $0.text) }
        var run = SegmenterRun()
        for (unit, embedding) in zip(units, embeddings) {
            try run.append(unit, embedding: embedding)
        }
        run.finish()
        return Conversation(
            name: name, units: units, embeddings: embeddings, reference: reference, digressions: digressions,
            streaming: run.confirmedIndices)
    }

    static func scripted() throws -> [Conversation] {
        try ScriptedTranscript.all.map { transcript in
            try streamed(
                name: transcript.name, units: transcript.units(), reference: transcript.boundaries,
                digressions: transcript.digression.map { [$0] } ?? [])
        }
    }

    static func synthetic(_ seeds: ClosedRange<UInt64>) throws -> [Conversation] {
        try seeds.map { seed in
            let conversation = SyntheticConversation.generate(seed: seed)
            return try streamed(
                name: "synthetic \(seed)", units: conversation.units, reference: conversation.boundaries,
                digressions: conversation.digressions)
        }
    }

    struct Score {
        var streamingPk = 0.0
        var resegmentedPk = 0.0
        var streamingWindowDiff = 0.0
        var resegmentedWindowDiff = 0.0
        var streamingSplitDigressions = 0
        var resegmentedSplitDigressions = 0
        var improved: [String] = []
        var worsened: [String] = []
        var conversations = 0

        init(_ conversations: [Conversation]) {
            for conversation in conversations {
                let after = conversation.resegmented().boundaries
                let before = conversation.streaming
                let pkBefore = conversation.pk(before)
                let pkAfter = conversation.pk(after)
                streamingPk += pkBefore
                resegmentedPk += pkAfter
                streamingWindowDiff += conversation.windowDiff(before)
                resegmentedWindowDiff += conversation.windowDiff(after)
                streamingSplitDigressions += conversation.splitDigressions(before)
                resegmentedSplitDigressions += conversation.splitDigressions(after)
                if pkAfter < pkBefore - 1e-12 { improved.append(conversation.name) }
                if pkAfter > pkBefore + 1e-12 { worsened.append(conversation.name) }
                self.conversations += 1
            }
            let count = Double(max(1, self.conversations))
            streamingPk /= count
            resegmentedPk /= count
            streamingWindowDiff /= count
            resegmentedWindowDiff /= count
        }
    }

    // MARK: Acceptance

    /// Pk improves on the fixture set vs streaming-only.
    @Test func pkImprovesOnTheFixtureSet() throws {
        let score = Score(try Self.scripted() + Self.synthetic(1...60))
        // Measured: Pk 0.0279 → 0.0095, WindowDiff 0.0283 → 0.0099,
        // 10 conversations better and none worse, digressions split 6 → 3.
        #expect(score.conversations == 65)
        #expect(score.resegmentedPk < score.streamingPk)
        #expect(score.resegmentedPk <= 0.6 * score.streamingPk, "Pk \(score.streamingPk) → \(score.resegmentedPk)")
        #expect(score.resegmentedWindowDiff < score.streamingWindowDiff)
        #expect(score.worsened.isEmpty, "Worse after re-segmentation: \(score.worsened)")
        #expect(score.improved.count >= 5)
        #expect(score.resegmentedSplitDigressions < score.streamingSplitDigressions)
    }

    /// The scripted transcripts already segment exactly; re-segmentation
    /// must not move anything.
    @Test func theScriptedTranscriptsAreLeftAlone() throws {
        for conversation in try Self.scripted() {
            let result = conversation.resegmented()
            #expect(result.isUnchanged, "\(conversation.name): \(result.changes)")
        }
    }

    /// Conversations the thresholds weren't tuned on.
    @Test func itGeneralizesToHeldOutConversations() throws {
        let score = Score(try Self.synthetic(61...300))
        // Measured: Pk 0.0422 → 0.0145, 57 better, none worse.
        #expect(score.resegmentedPk <= 0.6 * score.streamingPk, "Pk \(score.streamingPk) → \(score.resegmentedPk)")
        #expect(score.resegmentedWindowDiff < score.streamingWindowDiff)
        #expect(score.worsened.count <= 2, "Worse after re-segmentation: \(score.worsened)")
    }

    /// Prints the evaluation table for docs/topics.md:
    /// `BLAU_PRINT_RESEGMENTATION=1 swift test --filter ResegmentationEvaluationTests`.
    @Test func printTheTable() throws {
        guard ProcessInfo.processInfo.environment["BLAU_PRINT_RESEGMENTATION"] == "1" else { return }
        let sets: [(String, [Conversation])] = [
            ("scripted", try Self.scripted()),
            ("synthetic 1–60", try Self.synthetic(1...60)),
            ("held out 61–300", try Self.synthetic(61...300)),
        ]
        for (name, conversations) in sets {
            let score = Score(conversations)
            print(
                """
                \(name): \(score.conversations) conversations, \
                Pk \(score.streamingPk) → \(score.resegmentedPk), \
                WindowDiff \(score.streamingWindowDiff) → \(score.resegmentedWindowDiff), \
                split digressions \(score.streamingSplitDigressions) → \(score.resegmentedSplitDigressions), \
                better \(score.improved.count), worse \(score.worsened.count) \(score.worsened)
                """
            )
        }
    }
}
