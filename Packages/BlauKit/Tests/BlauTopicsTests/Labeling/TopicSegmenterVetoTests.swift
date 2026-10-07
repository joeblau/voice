import BlauCore
import BlauTelemetry
import Testing

@testable import BlauTopics

@Suite("TopicSegmenter veto")
struct TopicSegmenterVetoTests {
    @Test func vetoRejectsThePendingCandidate() throws {
        let embedder = LexicalTextEmbedder()
        var segmenter = TopicSegmenter()
        var candidate: TopicBoundary?
        for unit in ScriptedTranscript.threeTopics.units() {
            for event in try segmenter.append(unit, embedding: embedder.vector(for: unit.text)) {
                if case .candidate(let boundary) = event, candidate == nil { candidate = boundary }
            }
            if candidate != nil { break }
        }
        let pending = try #require(candidate)
        #expect(segmenter.pendingCandidate == pending)
        #expect(segmenter.vetoPendingCandidate() == [.rejected(pending, reason: .vetoed)])
        #expect(segmenter.pendingCandidate == nil)
        #expect(segmenter.vetoPendingCandidate().isEmpty)
        #expect(segmenter.boundaries.isEmpty)
    }

    @Test func aVetoedDipIsNotRaisedAgainButLaterChangesAre() throws {
        let embedder = LexicalTextEmbedder()
        var segmenter = TopicSegmenter()
        var vetoed: [Int] = []
        var confirmed: [Int] = []
        for unit in ScriptedTranscript.threeTopics.units() {
            for event in try segmenter.append(unit, embedding: embedder.vector(for: unit.text)) {
                switch event {
                case .candidate(let boundary) where vetoed.isEmpty:
                    vetoed.append(boundary.unitIndex)
                    _ = segmenter.vetoPendingCandidate()
                case .confirmed(let boundary):
                    confirmed.append(boundary.unitIndex)
                default:
                    break
                }
            }
        }
        #expect(vetoed.count == 1)
        #expect(!confirmed.contains(vetoed[0]))
        // The second real change (refinancing) is still found.
        #expect(confirmed.contains(12))
    }

    @Test func streamingSegmenterForwardsTheVeto() async throws {
        let segmenter = StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics))
        #expect(await segmenter.vetoPendingCandidate().isEmpty)
        for unit in ScriptedTranscript.threeTopics.units() {
            let events = try await segmenter.append(unit)
            if case .candidate(let boundary)? = events.first {
                #expect(await segmenter.vetoPendingCandidate() == [.rejected(boundary, reason: .vetoed)])
                return
            }
        }
        Issue.record("No candidate was raised")
    }
}
