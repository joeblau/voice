import BlauAudio
import BlauCore
import BlauTelemetry
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

    /// The owner's few words and then a voice voice ID can't place, in one
    /// utterance (the transcriber keeps it open across the pause): the
    /// uncertain speech counts, so the utterance is uncertain and follows
    /// the uncertain policy instead of riding on the accepted words. It
    /// isn't accepted, so it doesn't make the turn active either.
    @Test func aFewAcceptedWordsDontCarryLongUncertainSpeech() async throws {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 1.8, .owner), (1.8, 20, .borderline)]))
        let gate = VerificationGate(verifier: verifier, turnActivity: activity, clock: clock)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 1.4))
        await gate.feed(SpeechScript.segment(1, from: 2, to: 8))
        #expect(!activity.isActive)

        let gated = await gate.decide(finalUtterance("Hey so… and in other news tonight", from: 0, to: 8))

        #expect(gated.segments.map(\.decision) == [.accept, .uncertain])
        #expect(gated.decision == .uncertain)
        #expect(gated.disposition == .uncertainDiscarded)
        #expect(!gated.disposition.isCommitted)
        #expect(!activity.isActive)

        // So the same voice's next uncertain stretch of 2 s or more isn't
        // let through either.
        await gate.feed(SpeechScript.segment(2, from: 8.5, to: 11))
        let next = await gate.decide(finalUtterance("…the weather", from: 8.5, to: 11))
        #expect(next.decision == .uncertain)
        #expect(next.disposition == .uncertainDiscarded)
        #expect(!activity.isActive)
    }

    /// The owner opens with a short phrase and a pause ("Okay, so…
    /// [pause] what about tomorrow?"): one utterance, two segments. The
    /// opener is under 1 s with nothing recent to inherit, so it is
    /// uncertain for lack of evidence, not because voice ID doubted it. It
    /// doesn't count against the scored speech, and the owner is heard.
    @Test func theOwnersShortOpenerDoesNotDropTheUtteranceWhenIdle() async throws {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 10, .owner)]))
        let gate = VerificationGate(verifier: verifier, turnActivity: activity, clock: clock)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 0.7))
        await gate.feed(SpeechScript.segment(1, from: 1.1, to: 2.4))
        #expect(!activity.isActive)

        let gated = await gate.decide(finalUtterance("Okay, so… what about tomorrow?", from: 0, to: 2.4))

        #expect(gated.segments.map(\.decision) == [.uncertain, .accept])
        #expect(gated.segments.map(\.basis) == [.noRecentDecision, .scored])
        #expect(gated.decision == .accept)
        #expect(gated.disposition == .accepted)
        #expect(activity.isActive)
    }

    /// The owner answering Grok ("Yes. [pause] Do it.") after Grok spoke
    /// for longer than the inheritance window: the opener has nothing to
    /// inherit, and the whole utterance is under 2 s, so counting the
    /// opener as uncertain would drop it even inside the active turn.
    @Test func theOwnersShortOpenerDoesNotDropTheUtteranceInAnActiveTurn() async throws {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 30, .owner)]))
        let gate = VerificationGate(verifier: verifier, turnActivity: activity, clock: clock)
        // The owner's question, then Grok answers for 7 s.
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let question = await gate.decide(finalUtterance("Should I book it?", from: 0, to: 2.5))
        #expect(question.disposition == .accepted)
        activity.agentActivityChanged(true)
        activity.agentActivityChanged(false)
        #expect(activity.isActive)

        await gate.feed(SpeechScript.segment(1, from: 10, to: 10.65))
        await gate.feed(SpeechScript.segment(2, from: 10.85, to: 11.95))
        let gated = await gate.decide(finalUtterance("Yes. Do it.", from: 10, to: 11.95))

        #expect(gated.segments.map(\.decision) == [.uncertain, .accept])
        #expect(gated.segments.map(\.basis) == [.noRecentDecision, .scored])
        #expect(gated.decision == .accept)
        #expect(gated.disposition == .accepted)
    }

    /// A TV's run of short lines ("Yeah." "Right." "Sure.") with nothing
    /// recent to inherit, then the owner's 1.1 s, all in one utterance:
    /// only one short segment's worth of unattributed speech is left out of
    /// the shares, so the TV's 2.7 s doesn't ride along on the owner's
    /// words and the utterance isn't sent (or counted as the owner's)
    /// outside an active turn.
    @Test func manyShortUnattributedSegmentsDontRideOnAShortAcceptance() async throws {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 3.7, .other), (3.7, 10, .owner)]))
        let gate = VerificationGate(verifier: verifier, turnActivity: activity, clock: clock)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 0.9))
        await gate.feed(SpeechScript.segment(1, from: 1.3, to: 2.2))
        await gate.feed(SpeechScript.segment(2, from: 2.6, to: 3.5))
        await gate.feed(SpeechScript.segment(3, from: 3.9, to: 5.0))
        #expect(!activity.isActive)

        let gated = await gate.decide(finalUtterance("Yeah. Right. Sure. What's next?", from: 0, to: 5.0))

        #expect(gated.segments.map(\.basis) == [.noRecentDecision, .noRecentDecision, .noRecentDecision, .scored])
        #expect(gated.segments.map(\.decision) == [.uncertain, .uncertain, .uncertain, .accept])
        #expect(gated.decision == .uncertain)
        #expect(gated.disposition == .uncertainDiscarded)
        #expect(!activity.isActive)
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

    /// Every hold is a `voiceid.gate` interval, the latency budget's gate
    /// hop in Instruments and MetricKit (#74), ended with the disposition.
    @Test func everyHoldIsAGateIntervalEndedWithItsDisposition() async throws {
        let backend = RecordingSignpostBackend()
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 3, .owner), (5, 9, .other)]))
        let gate = VerificationGate(verifier: verifier, signposter: Signposter(category: .voiceID, backend: backend))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 5, to: 8))

        _ = await gate.decide(finalUtterance("What's on today?", from: 0, to: 2.5))
        _ = await gate.decide(finalUtterance("And now the news", from: 5, to: 8))

        #expect(backend.completedIntervals == ["voiceid.gate", "voiceid.gate"])
        #expect(backend.endMessages(of: "voiceid.gate") == ["accepted", "rejected"])
        #expect(backend.openIntervals.isEmpty)
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

        // The TV's final still goes on, marked `reject`, so the orchestrator
        // ends the utterance in progress (and ignores it); its partial and
        // its refined text don't.
        #expect(
            passed == [
                .partial(text: "Hi", range: TimeRange(start: .zero, end: .seconds(1))),
                .final(owner.withSpeakerDecision(.accept)), .final(tv.withSpeakerDecision(.reject)),
                .refined(owner), .final(ownerAgain.withSpeakerDecision(.accept)),
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

    @Test func anUncertainFinalThePolicyDropsGoesOnAsRejected() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .borderline)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let maybe = finalUtterance("Maybe me", from: 0, to: 2.5)
        // Outside an active turn: dropped, and passed on marked `reject`.
        #expect(await gate.gate(.final(maybe)) == .final(maybe.withSpeakerDecision(.reject)))
        #expect(await gate.gate(.refined(maybe)) == nil)
    }

    /// Only accepted speech keeps a turn active: uncertain speech the policy
    /// sends doesn't, so a podcast can't keep itself flowing to Grok.
    @Test func onlyAcceptedSpeechExtendsTheActiveTurn() async throws {
        let clock = ManualClock()
        let activity = ConversationTurnActivity(window: .seconds(10), clock: clock)
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 10, .borderline), (20, 30, .owner)]))
        let gate = VerificationGate(verifier: verifier, turnActivity: activity, clock: clock)
        activity.agentActivityChanged(true)
        activity.agentActivityChanged(false)

        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let podcast = await gate.decide(finalUtterance("…and that's the show", from: 0, to: 2.5))
        #expect(podcast.disposition == .uncertainCommitted)
        clock.advance(by: .seconds(11))
        #expect(!activity.isActive)

        await gate.feed(SpeechScript.segment(1, from: 20, to: 22.5))
        let owner = await gate.decide(finalUtterance("Next question", from: 20, to: 22.5))
        #expect(owner.disposition == .accepted)
        #expect(activity.isActive)
    }

    // MARK: Long speech and gaps

    /// VAD splits speech at 8 s, a little before where its audio stream has
    /// got to, and carries the audio on for the continuation from there. The
    /// continuation must be scored on its own speech, not on silence.
    @Test func aContinuationIsScoredOnItsOwnSpeech() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 20, .owner)]))
        // Segment 0 heard to 8.2 s, split at 7.4 s (VAD's quietest point).
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 8.2))
        await gate.feed([.ended(SpeechScript.ended(0, from: 0, to: 7.4, reason: .maximumDuration))])
        // The continuation starts at the split; VAD's audio resumes at 8.2 s.
        await gate.feed(
            [.started(SpeechScript.onset(1, at: 7.4, continuation: true))] + SpeechScript.audio(from: 8.2, to: 11.3)
                + [.ended(SpeechScript.ended(1, from: 7.4, to: 11))])

        let continuation = zip(verifier.calls, verifier.silentSamples).filter {
            $0.0.lowerBound == SpeechScript.offset(7.4)
        }
        // 1.5 s, 3 s, then the whole 3.6 s at its end.
        #expect(continuation.map(\.0.count) == [24_000, 48_000, 57_600])
        #expect(continuation.allSatisfy { $0.1 == 0 })
        #expect(gate.statistics.seededContinuations == 1)
        #expect(gate.statistics.gapSamplesSilenced == 0)

        let gated = await gate.decide(finalUtterance("A long story", from: 0, to: 11))
        #expect(gated.segments.map(\.segmentID) == [0, 1])
        #expect(gated.segments.map(\.decision) == [.accept, .accept])
        #expect(gated.decision == .accept)
    }

    @Test func aGapInVADsAudioIsFilledFromTheCaptureHistory() async throws {
        let verifier = ScriptedVerifier(SpeakerTimeline([(0, 10, .owner)]))
        let gate = VerificationGate(verifier: verifier, history: FixedHistory(seconds: 10))
        await gate.feed(
            [.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 0.5)
                + SpeechScript.audio(from: 0.9, to: 2.0))
        #expect(verifier.calls.map(\.count) == [24_000])
        #expect(verifier.silentSamples == [0])
        #expect(gate.statistics.gapSamplesFromHistory == 6_400)
        #expect(gate.statistics.gapSamplesSilenced == 0)
    }

    @Test func aGapTheHistoryNoLongerHoldsIsSilence() async throws {
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 10, .owner)]))
        await gate.feed(
            [.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 0.5)
                + SpeechScript.audio(from: 0.9, to: 2.0))
        // Positions stay aligned: 1.5 s of audio, 0.4 s of it silence.
        #expect(verifier.calls == [0..<24_000])
        #expect(verifier.silentSamples == [6_400])
        #expect(gate.statistics.gapSamplesSilenced == 6_400)
    }

    // MARK: The hangover

    /// VAD sends ~300 ms of hangover before it ends a segment, so a
    /// checkpoint can be reached on audio past the speech. At the end the
    /// gate scores exactly the speech instead of keeping that score.
    @Test(arguments: [
        (1.3, [24_000, 20_800], SpeakerDecision.uncertain),
        (2.8, [24_000, 48_000, 44_800], .uncertain),
    ])
    func aCheckpointPastTheSpeechIsScoredAgainOnTheSpeech(
        speech: Double, calls: [Int], expected: SpeakerDecision
    ) async throws {
        // Uncertain on short windows, rejected on 3 s ones: a 3 s score
        // taken over the hangover would wrongly reject 2.8 s of speech.
        let (gate, verifier) = Self.gate(SpeakerTimeline([(0, 10, .fadingOut)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: speech))
        #expect(verifier.calls.map(\.count) == calls)
        #expect(await gate.decision(ofSegment: 0) == expected)
        let gated = await gate.decide(finalUtterance("…", from: 0, to: speech))
        #expect(
            gated.segments.first?.scoredDuration.sampleCount(sampleRate: SpeechScript.rate)
                == SpeechScript.offset(speech))
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
