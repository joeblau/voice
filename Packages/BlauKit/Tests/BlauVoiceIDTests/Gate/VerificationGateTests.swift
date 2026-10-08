import BlauAudio
import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// The verification gate (#47) on scripted scores: checkpoints, decisions,
/// inheritance, the uncertain policy, utterances spanning segments, the
/// transcript filter and the barge-in verdict.
@Suite("Verification gate")
struct VerificationGateTests {
    typealias Voice = SpeakerTimeline.Voice

    static func gate(
        _ timeline: SpeakerTimeline, configuration: VerificationGateConfiguration = .standard,
        delay: Duration = .zero, failing: Set<Double> = []
    ) -> (VerificationGate, ScriptedVerifier) {
        let verifier = ScriptedVerifier(timeline, delay: delay, failing: failing)
        return (VerificationGate(verifier: verifier, configuration: configuration), verifier)
    }

    // MARK: Scoring a segment

    @Test func theOwnerIsAcceptedAndSent() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 10, .owner)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))

        let gated = await gate.decide(finalUtterance("What's the weather tomorrow?", from: 0, to: 2.5))

        #expect(gated.decision == .accept)
        #expect(gated.disposition == .accepted)
        #expect(gated.segments.map(\.basis) == [.scored])
        // Scored at 1.5 s, then re-scored over the whole 2.5 s at the end.
        #expect(verifier.calls.map(\.count) == [24_000, 40_000])
        #expect(gated.segments.first?.scoredDuration == .seconds(2.5))
    }

    @Test func aTVIsRejectedAndNotSent() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .other)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 4))

        let gated = await gate.decide(finalUtterance("Breaking news tonight", from: 0, to: 4))

        #expect(gated.decision == .reject)
        #expect(gated.disposition == .rejected)
        let statistics = gate.statistics
        #expect(statistics.utterances == [.reject: 1])
        #expect(statistics.discarded == 1)
        #expect(statistics.committed == 0)
    }

    @Test func theRescoreAtThreeSecondsOverridesTheFirstScore() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 10, .ownerFar)]))
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.6))
        #expect(await gate.decision(ofSegment: 0) == .uncertain)

        await gate.feed(SpeechScript.audio(from: 1.6, to: 3.2))
        #expect(await gate.decision(ofSegment: 0) == .accept)
        #expect(verifier.calls.map(\.count) == [24_000, 48_000])

        // A segment just past 3 s isn't scored again at its end.
        await gate.feed(SpeechScript.audio(from: 3.2, to: 3.5) + [.ended(SpeechScript.ended(0, from: 0, to: 3.2))])
        #expect(verifier.calls.count == 2)
        let gated = await gate.decide(finalUtterance("Set a timer", from: 0, to: 3.2))
        #expect(gated.decision == .accept)
    }

    @Test func aSegmentFadingIntoAnotherVoiceIsRejectedAtThreeSeconds() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .fadingOut)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3.2))
        let gated = await gate.decide(finalUtterance("…", from: 0, to: 3.2))
        #expect(gated.decision == .reject)
    }

    @Test func aFailedEmbeddingLeavesTheSegmentUncertain() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), failing: [0])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2))
        let gated = await gate.decide(finalUtterance("Hello", from: 0, to: 2))
        #expect(gated.decision == .uncertain)
        #expect(gated.segments.map(\.basis) == [.unscored])
        #expect(gate.statistics.scoreFailures >= 1)
    }

    // MARK: Short segments

    @Test func aShortSegmentInheritsARecentDecision() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 3, .owner), (4, 5, .other)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        // 1.5 s later, 0.6 s of speech: too short to score.
        await gate.feed(SpeechScript.segment(1, from: 4, to: 4.6))

        let gated = await gate.decide(finalUtterance("Please", from: 4, to: 4.6))

        #expect(gated.decision == .accept)
        #expect(gated.segments.map(\.basis) == [.inherited(from: 0)])
        #expect(verifier.calls.allSatisfy { $0.lowerBound == 0 })
    }

    @Test func aShortSegmentLongAfterTheLastDecisionIsUncertain() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 3, .owner)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 8, to: 8.6))

        let gated = await gate.decide(finalUtterance("Yeah", from: 8, to: 8.6))

        #expect(gated.decision == .uncertain)
        #expect(gated.segments.map(\.basis) == [.noRecentDecision])
        // Short, outside an active turn: dropped.
        #expect(gated.disposition == .uncertainDiscarded)
    }

    @Test func aShortSegmentInheritsARejection() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 4, .other)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3.5))
        await gate.feed(SpeechScript.segment(1, from: 4.5, to: 5))
        let gated = await gate.decide(finalUtterance("Okay", from: 4.5, to: 5))
        #expect(gated.disposition == .rejected)
    }

    /// A run of short segments can't carry the owner's decision on past the
    /// window: it is measured from the last speech that was scored.
    @Test func inheritanceDoesNotChainPastTheWindow() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 3, .owner)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2))
        await gate.feed(SpeechScript.segment(1, from: 3, to: 3.5))
        await gate.feed(SpeechScript.segment(2, from: 5, to: 5.5))
        await gate.feed(SpeechScript.segment(3, from: 7.5, to: 8))

        #expect(await gate.decision(ofSegment: 1) == .accept)
        #expect(await gate.decision(ofSegment: 2) == .accept)
        // 5.5 s after the owner's scored speech ended at 2 s.
        #expect(await gate.decision(ofSegment: 3) == .uncertain)
    }

    // MARK: The uncertain policy

    @Test func uncertainSpeechIsSentOnlyInAnActiveTurnAndWhenLongEnough() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 30, .borderline)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 10, to: 12.5))
        await gate.feed(SpeechScript.segment(2, from: 20, to: 21.5))

        let idle = await gate.decide(finalUtterance("Maybe me", from: 0, to: 2.5))
        #expect(idle.decision == .uncertain)
        #expect(idle.disposition == .uncertainDiscarded)

        gate.turnActivity.agentActivityChanged(true)
        let active = await gate.decide(finalUtterance("Maybe me again", from: 10, to: 12.5))
        #expect(active.disposition == .uncertainCommitted)

        let short = await gate.decide(finalUtterance("Hm", from: 20, to: 21.5))
        #expect(short.disposition == .uncertainDiscarded)
    }

    @Test(arguments: [(UncertainSpeechPolicy.commit, true), (.discard, false)])
    func otherUncertainPolicies(policy: UncertainSpeechPolicy, sent: Bool) async throws {
        let (gate, _) = Self.gate(
            SpeakerTimeline([(0, 30, .borderline)]),
            configuration: VerificationGateConfiguration(uncertainPolicy: policy))
        gate.turnActivity.agentActivityChanged(true)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Maybe me", from: 0, to: 2.5))
        #expect(gated.disposition.isCommitted == sent)
    }

    // MARK: Utterances and segments

    @Test func anUtteranceSpanningAPauseCombinesItsSegments() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2))
        await gate.feed(SpeechScript.segment(1, from: 2.6, to: 3.0))
        let gated = await gate.decide(finalUtterance("Call mom, please", from: 0, to: 3.0))
        #expect(gated.segments.map(\.segmentID) == [0, 1])
        #expect(gated.decision == .accept)
    }

    @Test func mixedSpeakersInOneUtteranceAreUncertainUnlessOneDominates() async throws {
        let timeline = SpeakerTimeline([(0, 3, .owner), (3, 7, .other), (10, 16, .other), (16, 18, .owner)])
        let (gate, _) = Self.gate(timeline)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 3, to: 6))
        await gate.feed(SpeechScript.segment(2, from: 10, to: 16))
        await gate.feed(SpeechScript.segment(3, from: 16.2, to: 17.4))

        // 2.5 s accepted, 3 s rejected: too close to call.
        let mixed = await gate.decide(finalUtterance("…", from: 0, to: 6))
        #expect(mixed.decision == .uncertain)
        // 6 s rejected, 1.2 s accepted: the TV wins.
        let mostlyTV = await gate.decide(finalUtterance("…", from: 10, to: 17.4))
        #expect(mostlyTV.decision == .reject)
    }

    /// The model can end an utterance before VAD ends the segment: the gate
    /// scores what it has instead of waiting.
    @Test func aFinalBeforeTheSegmentEndsIsScoredAtOnce() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 10, .owner)]))
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 2.4))

        let gated = await gate.decide(finalUtterance("Turn it up", from: 0, to: 2.2))

        #expect(gated.decision == .accept)
        // 1.5 s at the checkpoint, then the utterance's 2.2 s.
        #expect(verifier.calls.map(\.count) == [24_000, 35_200])
    }

    @Test func aFinalArrivingBeforeItsSegmentWaitsForIt() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .other)]))
        let decided = Task { await gate.decide(finalUtterance("Breaking news", from: 0, to: 2)) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2))
        #expect(await decided.value.decision == .reject)
    }

    @Test func aFinalWithNoSpeechAtAllIsUncertain() async throws {
        let configuration = VerificationGateConfiguration(segmentArrivalTimeout: .milliseconds(10))
        let (gate, _) = Self.gate(SpeakerTimeline([]), configuration: configuration)
        let gated = await gate.decide(finalUtterance("Hello", from: 0, to: 1))
        #expect(gated.decision == .uncertain)
        #expect(gated.segments.isEmpty)
    }

    // MARK: Latency

    /// With the decision made while the user spoke, the final isn't held.
    @Test func aDecidedSegmentAddsNoLatency() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), delay: .milliseconds(30))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3.2))
        let gated = await gate.decide(finalUtterance("Set a timer", from: 0, to: 3.2))
        #expect(gated.delay < .milliseconds(25))
    }

    /// The end-of-segment re-score runs while the final waits: one embedding.
    @Test func theEndOfSegmentScoreIsTheOnlyHold() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), delay: .milliseconds(40))
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 2.8))
        let ending = Task { await gate.feed([.ended(SpeechScript.ended(0, from: 0, to: 2.5))]) }
        try await Task.sleep(for: .milliseconds(5))
        let gated = await gate.decide(finalUtterance("Hello there", from: 0, to: 2.5))
        await ending.value
        #expect(gated.decision == .accept)
        #expect(gated.delay < .milliseconds(100))
        #expect(gate.statistics.longestDelay == gated.delay)
    }

    // MARK: The transcript filter

    @Test func theFilterPassesTheOwnerAndDropsEveryoneElse() async throws {
        let timeline = SpeakerTimeline([(0, 3, .owner), (5, 9, .other), (10, 13, .owner)])
        let (gate, _) = Self.gate(timeline)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 5, to: 8.5))
        await gate.feed(SpeechScript.segment(2, from: 10, to: 12.5))

        let owner = finalUtterance("Hi", from: 0, to: 2.5)
        let tv = finalUtterance("And now the weather", from: 5, to: 8.5)
        let ownerAgain = finalUtterance("Thanks", from: 10, to: 12.5)
        let (input, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        for event: TranscriptEvent in [
            .partial(text: "Hi", range: TimeRange(start: .zero, end: .seconds(1))), .final(owner),
            .partial(text: "And now", range: TimeRange(start: .seconds(5), end: .seconds(7))), .final(tv),
            .refined(owner), .refined(tv), .final(ownerAgain),
        ] {
            continuation.yield(event)
        }
        continuation.finish()

        var passed: [TranscriptEvent] = []
        for await event in gate.filter(input) { passed.append(event) }

        #expect(
            passed == [
                .partial(text: "Hi", range: TimeRange(start: .zero, end: .seconds(1))),
                .final(owner.withSpeakerDecision(.accept)), .refined(owner),
                .final(ownerAgain.withSpeakerDecision(.accept)),
            ])
        #expect(gate.statistics.suppressedPartials == 1)

        var verdicts: [GatedUtterance] = []
        for await verdict in gate.verdicts {
            verdicts.append(verdict)
            if verdicts.count == 3 { break }
        }
        #expect(verdicts.map(\.disposition) == [.accepted, .rejected, .accepted])
        #expect(verdicts[1].utterance.text == "And now the weather")
    }

    // MARK: Barge-in

    @Test func bargeInWaitsForTheFirstScore() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .other)]))
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 0.5))
        let verdict = Task { await gate.bargeInDecision(for: SpeechScript.onset(0, at: 0)) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.feed(SpeechScript.audio(from: 0.5, to: 1.6))
        #expect(await verdict.value == .reject)
    }

    @Test(arguments: [(Voice.owner, SpeakerDecision.accept), (.borderline, .uncertain), (.other, .reject)])
    func bargeInGetsTheSegmentsDecision(voice: Voice, expected: SpeakerDecision) async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, voice)]))
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.6))
        #expect(await gate.bargeInDecision(for: SpeechScript.onset(0, at: 0)) == expected)
    }

    @Test func bargeInOnShortSpeechUsesItsInheritedDecision() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 4, .other)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3))
        await gate.feed(SpeechScript.segment(1, from: 3.5, to: 4))
        #expect(await gate.bargeInDecision(for: SpeechScript.onset(1, at: 3.5)) == .reject)
    }

    @Test func bargeInGivesUpAsUncertain() async throws {
        let configuration = VerificationGateConfiguration(bargeInDecisionTimeout: .milliseconds(20))
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .other)]), configuration: configuration)
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 0.5))
        #expect(await gate.bargeInDecision(for: SpeechScript.onset(0, at: 0)) == .uncertain)
        #expect(gate.statistics.bargeInTimeouts == 1)
    }

    // MARK: Housekeeping

    @Test func oldSegmentsAreForgotten() async throws {
        let configuration = VerificationGateConfiguration(retainedSegments: 2)
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 30, .owner)]), configuration: configuration)
        for index in 0..<4 {
            await gate.feed(SpeechScript.segment(index, from: Double(index) * 3, to: Double(index) * 3 + 2))
        }
        #expect(await gate.decision(ofSegment: 0) == nil)
        #expect(await gate.decision(ofSegment: 3) == .accept)
        await gate.reset()
        #expect(await gate.decision(ofSegment: 3) == nil)
    }

    @Test func audioBehindTheFinalIsReadFromTheCaptureHistory() async throws {
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 10, .owner)]))
        let history = FixedHistory(seconds: 10)
        let gate = VerificationGate(verifier: verifier, history: history)
        // VAD's audio stream is only at 1.2 s when the final for 2.4 s comes.
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.2))
        let gated = await gate.decide(finalUtterance("Hello there", from: 0, to: 2.4))
        #expect(gated.decision == .accept)
        #expect(verifier.calls.last == 0..<38_400)
    }
}

/// A capture history holding `seconds` of audio from the stream's start.
final class FixedHistory: CaptureFrameSource {
    let samples: [Float]

    init(seconds: Double) {
        samples = [Float](repeating: 0.01, count: Int(seconds * 16_000))
    }

    func frames(replaying lookback: Duration) -> AsyncStream<AudioFrame> {
        AsyncStream { $0.finish() }
    }

    func history(in range: Range<Int64>) -> AudioFrame? {
        let lower = max(0, Int(range.lowerBound))
        let upper = min(samples.count, Int(range.upperBound))
        guard lower < upper else { return nil }
        return AudioFrame(samples: Array(samples[lower..<upper]), sampleOffset: Int64(lower))
    }
}
