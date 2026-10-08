import Testing

@testable import BlauVoiceID

/// Which clip is the odd one out.
@Suite("Enrollment consistency")
struct EnrollmentConsistencyTests {
    let owner = TestEmbeddings.speaker(0, count: 4)
    let other = TestEmbeddings.speaker(1, count: 2)

    @Test func theFirstClipIsAcceptedWithNothingToCompare() {
        #expect(
            EnrollmentConsistency.verdict(for: owner[0], accepted: [], consecutiveMismatches: 0)
                == .accept(similarity: nil))
    }

    @Test func aMatchingClipIsAccepted() {
        guard
            case .accept(let similarity?) = EnrollmentConsistency.verdict(
                for: owner[1], accepted: [owner[0]], consecutiveMismatches: 0)
        else {
            Issue.record("Expected accept")
            return
        }
        #expect(similarity > 0.8)
    }

    @Test func theFirstMismatchRejectsTheNewClip() {
        let verdict = EnrollmentConsistency.verdict(
            for: other[0], accepted: [owner[0], owner[1]], consecutiveMismatches: 0)
        guard case .reject(.inconsistent(let similarity, let minimum)) = verdict else {
            Issue.record("Expected an inconsistent reject, got \(verdict)")
            return
        }
        #expect(similarity < minimum)
    }

    @Test func aRepeatedMismatchWithTheNewClipStillWorstRejectsIt() {
        let verdict = EnrollmentConsistency.verdict(
            for: other[0], accepted: [owner[0], owner[1], owner[2]], consecutiveMismatches: 1)
        guard case .reject(.inconsistent) = verdict else {
            Issue.record("Expected reject, got \(verdict)")
            return
        }
    }

    @Test func aRepeatedMismatchDropsTheEarlierOddClip() {
        // Clip 0 was someone else; clip 1 sounds half like them, half like
        // the owner (so it passed against clip 0). The owner's new clip
        // fails against their mean twice in a row.
        let accepted = [TestEmbeddings.blend([1]), TestEmbeddings.blend([0, 1])]
        let candidate = owner[1]
        let first = EnrollmentConsistency.verdict(for: candidate, accepted: accepted, consecutiveMismatches: 0)
        guard case .reject = first else {
            Issue.record("Expected the first mismatch to reject, got \(first)")
            return
        }
        let second = EnrollmentConsistency.verdict(for: candidate, accepted: accepted, consecutiveMismatches: 1)
        guard case .acceptReplacing(let indices, let similarity) = second else {
            Issue.record("Expected acceptReplacing, got \(second)")
            return
        }
        #expect(indices == [0])
        #expect(similarity >= EnrollmentQualityPolicy.standard.minimumConsistency)
    }

    @Test func twoClipsThatDisagreeTwiceRestart() {
        let verdict = EnrollmentConsistency.verdict(for: owner[0], accepted: [other[0]], consecutiveMismatches: 1)
        guard case .restart(.inconsistent) = verdict else {
            Issue.record("Expected restart, got \(verdict)")
            return
        }
    }

    @Test func aTopUpClipMustMatchTheVoiceprint() {
        let centroid = SpeakerEmbedding.mean(of: owner)!
        #expect(
            EnrollmentConsistency.verdict(
                for: owner[3], accepted: [], consecutiveMismatches: 0, voiceprint: centroid)
                == .accept(similarity: nil))
        let verdict = EnrollmentConsistency.verdict(
            for: other[0], accepted: [], consecutiveMismatches: 0, voiceprint: centroid)
        guard case .reject(.doesNotMatchVoiceprint(let similarity, _)) = verdict else {
            Issue.record("Expected doesNotMatchVoiceprint, got \(verdict)")
            return
        }
        #expect(similarity < EnrollmentQualityPolicy.standard.minimumVoiceprintMatch)
    }

    @Test func leaveOneOutFindsTheOutlier() {
        let set = [owner[0], owner[1], other[0], owner[2]]
        let scores = EnrollmentConsistency.leaveOneOut(set)
        #expect(scores.count == 4)
        #expect(scores.indices.min { scores[$0] < scores[$1] } == 2)
        let outlier = EnrollmentConsistency.worstOutlier(set)
        #expect(outlier?.index == 2)
        #expect(EnrollmentConsistency.worstOutlier(owner) == nil)
        #expect(EnrollmentConsistency.worstOutlier([owner[0]]) == nil)
        #expect(EnrollmentConsistency.leaveOneOut([owner[0]]) == [1])
    }
}
