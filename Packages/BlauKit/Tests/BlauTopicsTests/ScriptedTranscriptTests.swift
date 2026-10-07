import BlauCore
import BlauTopics
import Testing

/// The acceptance tests for #52: scripted transcripts with labelled
/// boundaries, scored with Pk and WindowDiff, run through the reference
/// `LexicalTextEmbedder` so the result is the same on every machine.
@Suite("Scripted transcripts")
struct ScriptedTranscriptTests {
    /// Per-transcript ceilings. Every fixture currently segments exactly
    /// (Pk 0, WindowDiff 0); the margin lets a deliberate tuning change move
    /// a boundary by one exchange without rewriting the tests.
    static let maximumPk = 0.1
    static let maximumWindowDiff = 0.1

    @Test(arguments: ScriptedTranscript.all)
    func meetsTheErrorBudget(transcript: ScriptedTranscript) throws {
        let run = try SegmenterRun.run(transcript)
        let found = run.confirmedIndices
        let pk = SegmentationMetrics.pk(reference: transcript.boundaries, hypothesis: found, count: transcript.count)
        let windowDiff = SegmentationMetrics.windowDiff(
            reference: transcript.boundaries,
            hypothesis: found,
            count: transcript.count
        )
        #expect(pk <= Self.maximumPk, "Pk \(pk); reference \(transcript.boundaries), found \(found)")
        #expect(
            windowDiff <= Self.maximumWindowDiff,
            "WindowDiff \(windowDiff); reference \(transcript.boundaries), found \(found)"
        )
    }

    @Test(arguments: ScriptedTranscript.all)
    func findsEveryLabelledBoundaryWithinOneExchange(transcript: ScriptedTranscript) throws {
        let found = try SegmenterRun.run(transcript).confirmedIndices
        #expect(found.count == transcript.boundaries.count, "reference \(transcript.boundaries), found \(found)")
        for boundary in transcript.boundaries {
            #expect(found.contains { abs($0 - boundary) <= 1 }, "missed \(boundary); found \(found)")
        }
    }

    @Test func aSingleTopicIsNeverSplit() throws {
        let run = try SegmenterRun.run(.singleTopic)
        #expect(run.confirmed.isEmpty)
        // Within-topic dips may raise candidates, but each one is dropped.
        #expect(run.rejections.count == run.candidates.count)
    }

    /// "No flapping on a fixture with a brief digression": the two-exchange
    /// espresso detour raises one candidate, which the hysteresis rejects as
    /// a recovery. The return to the interview doesn't raise another one, and
    /// the real change of subject afterwards is still found.
    @Test func aBriefDigressionDoesNotFlap() throws {
        let transcript = ScriptedTranscript.briefDigression
        let digression = try #require(transcript.digression)
        let run = try SegmenterRun.run(transcript)

        #expect(run.confirmedIndices == [12])

        let nearDigression = (digression.lowerBound - 1)...(digression.upperBound + 1)
        let digressionCandidates = run.candidates.filter { nearDigression.contains($0.unitIndex) }
        #expect(digressionCandidates.count == 1)
        let digressionRejections = run.rejections.filter { nearDigression.contains($0.boundary.unitIndex) }
        #expect(digressionRejections.map(\.reason) == [.recovered])
        #expect(!run.confirmed.contains { nearDigression.contains($0.unitIndex) })
    }

    /// In `threeTopics` the "flat loaf" exchange dips first and raises the
    /// candidate two exchanges early. The boundary is still placed
    /// retroactively at the deeper dip where the marathon talk starts.
    @Test func theBoundaryMovesBackToTheDeepestDip() throws {
        let run = try SegmenterRun.run(.threeTopics)
        let firstCandidate = try #require(run.candidates.first)
        let firstBoundary = try #require(run.confirmed.first)
        #expect(firstCandidate.unitIndex == 4)
        #expect(firstBoundary.unitIndex == 6)
        #expect(firstBoundary.depth > firstCandidate.depth)
    }

    @Test func explicitCuesAreFlaggedAndBoostTheScore() throws {
        let run = try SegmenterRun.run(.explicitCues)
        #expect(run.confirmedIndices == [5, 10])
        for boundary in run.confirmed {
            #expect(boundary.hasExplicitCue)
            let boost = TopicConfig.default.cueBoost * boundary.threshold
            #expect(abs(boundary.score - (boundary.depth + boost)) < 1e-9)
        }

        var withoutCues = TopicConfig.default
        withoutCues.cuePhrases = []
        let plain = try SegmenterRun.run(.explicitCues, config: withoutCues)
        #expect(plain.confirmed.allSatisfy { !$0.hasExplicitCue && $0.score == $0.depth })
    }

    @Test(arguments: ScriptedTranscript.all)
    func confirmedTopicsRespectTheMinimumLength(transcript: ScriptedTranscript) throws {
        let config = TopicConfig.default
        let units = transcript.units()
        for boundary in try SegmenterRun.run(transcript).confirmed {
            #expect(boundary.closedTopic.count >= config.minimumTopicUnits)
            let length =
                units[boundary.unitIndex].timeRange.start - units[boundary.closedTopic.lowerBound].timeRange.start
            #expect(length >= config.minimumTopicDuration)
        }
    }

    @Test(arguments: ScriptedTranscript.all)
    func everyCandidateIsResolvedExactlyOnce(transcript: ScriptedTranscript) throws {
        let run = try SegmenterRun.run(transcript)
        #expect(run.candidates.count == run.confirmed.count + run.rejections.count)
        // Events alternate: a candidate, then its resolution.
        var pending = false
        for event in run.events {
            switch event {
            case .candidate:
                #expect(!pending)
                pending = true
            case .confirmed, .rejected:
                #expect(pending)
                pending = false
            }
        }
        #expect(!pending)
    }

    @Test(arguments: ScriptedTranscript.all)
    func isDeterministic(transcript: ScriptedTranscript) throws {
        let first = try SegmenterRun.run(transcript)
        let second = try SegmenterRun.run(transcript)
        #expect(first.events == second.events)
    }
}
