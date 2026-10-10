import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

/// The language filter (#50) inside the verification gate: when it
/// identifies, what it drops, and what it costs a final.
@Suite("Verification gate: language filter")
struct VerificationGateLanguageTests {
    static let spanish = SpokenLanguage(code: "es")!

    /// A switchable allow-list, like Settings.
    final class Allowed: Sendable {
        private let value: Mutex<Set<SpokenLanguage>?>
        init(_ languages: Set<SpokenLanguage>?) { value = Mutex(languages) }
        var languages: Set<SpokenLanguage>? {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    static func gate(
        _ voices: SpeakerTimeline, languages: [ScriptedLanguageIdentifier.Stretch] = [],
        allowed: Allowed = Allowed([.english]), delay: Duration = .zero, clock: any BlauClock = SystemClock(),
        failure: (any Error)? = nil, configuration: LanguageFilterConfiguration = .standard
    ) -> (VerificationGate, ScriptedLanguageIdentifier) {
        let identifier = ScriptedLanguageIdentifier(timeline: languages, delay: delay, clock: clock, failure: failure)
        let filter = LanguageFilter(
            identifier: identifier, configuration: configuration, allowedLanguages: { allowed.languages })
        let gate = VerificationGate(verifier: ScriptedVerifier(voices), languageFilter: filter, clock: clock)
        return (gate, identifier)
    }

    static func spanish(from start: Double, to end: Double) -> ScriptedLanguageIdentifier.Stretch {
        .init(samples: SpeechScript.offset(start)..<SpeechScript.offset(end), language: spanish)
    }

    // MARK: What gets through

    @Test func theOwnerInEnglishIsSent() async throws {
        let (gate, identifier) = Self.gate(SpeakerTimeline([(0, 10, .owner)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))

        let gated = await gate.decide(finalUtterance("What's on my calendar?", from: 0, to: 2.5))

        #expect(gated.disposition == .accepted)
        #expect(gated.language?.decision == .allowed)
        #expect(gated.language?.language?.language == .english)
        // Identified once, on the first 2 s, while it was spoken.
        #expect(identifier.identifiedAudio.map(\.sampleCount) == [32_000])
        #expect(gate.statistics.languageChecks == 1)
    }

    /// The issue's case: a foreign-language TV show that passes the voice
    /// gate (here, accepted outright) is still not sent.
    @Test func speechInAnotherLanguageIsDropped() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3.5))
        #expect(await gate.languageVerdict(ofSegment: 0)?.language == Self.spanish)

        let tv = finalUtterance("¿Qué tal el partido de anoche?", from: 0, to: 3.5)
        let passed = await gate.gate(.final(tv))

        // Passed on marked `reject`, so the orchestrator ignores it.
        #expect(passed == .final(tv.withSpeakerDecision(.reject)))
        #expect(await gate.gate(.refined(tv)) == nil)
        let statistics = gate.statistics
        #expect(statistics.otherLanguageUtterances == 1)
        #expect(statistics.discarded == 1)
        #expect(statistics.committed == 0)
        // Accepted by voice ID, so the speaker decision says accept.
        #expect(statistics.utterances == [.accept: 1])
    }

    @Test func droppedOtherLanguageSpeechDoesNotKeepTheTurnActive() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Hola", from: 0, to: 2.5))
        #expect(gated.disposition == .otherLanguage)
        #expect(!gated.disposition.isCommitted)
        #expect(!gate.turnActivity.isActive)
    }

    @Test func uncertainSpeechSentInAnActiveTurnIsCheckedToo() async throws {
        let (gate, _) = Self.gate(
            SpeakerTimeline([(0, 10, .borderline)]), languages: [Self.spanish(from: 0, to: 10)])
        gate.turnActivity.agentActivityChanged(true)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Y ahora, las noticias", from: 0, to: 2.5))
        #expect(gated.decision == .uncertain)
        #expect(gated.disposition == .otherLanguage)
    }

    /// Speech the model hears as mostly Spanish but 5% English: enough
    /// doubt to keep the owner's accepted words, not enough to let an
    /// uncertain voice through.
    @Test func acceptedSpeechNeedsStrongerEvidenceThanUncertainSpeech() async throws {
        let doubtful = { (start: Double, end: Double) in
            ScriptedLanguageIdentifier.Stretch(
                samples: SpeechScript.offset(start)..<SpeechScript.offset(end), language: Self.spanish,
                confidence: 0.9, english: 0.05)
        }
        let (gate, _) = Self.gate(
            SpeakerTimeline([(0, 10, .owner), (10, 20, .borderline)]), languages: [doubtful(0, 20)])
        gate.turnActivity.agentActivityChanged(true)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 10, to: 12.5))

        let owner = await gate.decide(finalUtterance("Vamos", from: 0, to: 2.5))
        #expect(owner.disposition == .accepted)
        #expect(owner.language?.threshold == LanguageFilterConfiguration.standard.acceptedSpeechThreshold)

        let unplaced = await gate.decide(finalUtterance("Vamos", from: 10, to: 12.5))
        #expect(unplaced.decision == .uncertain)
        #expect(unplaced.disposition == .otherLanguage)
        #expect(unplaced.language?.threshold == LanguageFilterConfiguration.standard.uncertainSpeechThreshold)
    }

    @Test func allowingTheLanguageLetsItThrough() async throws {
        let allowed = Allowed([.english])
        let (gate, _) = Self.gate(
            SpeakerTimeline([(0, 30, .owner)]), languages: [Self.spanish(from: 0, to: 30)], allowed: allowed)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        #expect(await gate.decide(finalUtterance("Hola", from: 0, to: 2.5)).disposition == .otherLanguage)

        // Settings → Voice ID → Languages: Spanish too. Applies from the
        // next segment.
        allowed.languages = [.english, Self.spanish]
        await gate.feed(SpeechScript.segment(1, from: 10, to: 12.5))
        #expect(await gate.decide(finalUtterance("Hola otra vez", from: 10, to: 12.5)).disposition == .accepted)
    }

    @Test func turningTheFilterOffSkipsIt() async throws {
        let (gate, identifier) = Self.gate(
            SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)], allowed: Allowed(nil))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Hola", from: 0, to: 2.5))
        #expect(gated.disposition == .accepted)
        #expect(gated.language == nil)
        #expect(identifier.identifiedAudio.isEmpty)
    }

    // MARK: When it identifies

    @Test func rejectedSpeechIsNeverIdentified() async throws {
        let (gate, identifier) = Self.gate(SpeakerTimeline([(0, 10, .other)]))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 4))
        let gated = await gate.decide(finalUtterance("Breaking news", from: 0, to: 4))
        #expect(gated.disposition == .rejected)
        #expect(gated.language == nil)
        #expect(identifier.identifiedAudio.isEmpty)
    }

    @Test func aSegmentShorterThanTheWindowIsIdentifiedWhenItEnds() async throws {
        let (gate, identifier) = Self.gate(
            SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 1.5))
        // All of its 1.5 s of speech, without the hangover.
        #expect(identifier.identifiedAudio.map(\.sampleCount) == [24_000])
        let gated = await gate.decide(finalUtterance("Buenos días", from: 0, to: 1.5))
        #expect(gated.disposition == .otherLanguage)
    }

    @Test func speechUnderASecondIsNotIdentified() async throws {
        let (gate, identifier) = Self.gate(
            SpeakerTimeline([(0, 3, .owner), (3, 10, .owner)]), languages: [Self.spanish(from: 3, to: 10)])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 3.5, to: 4.2))
        let gated = await gate.decide(finalUtterance("Sí", from: 3.5, to: 4.2))
        // Inherits the owner's decision, and is too short to identify.
        #expect(gated.disposition == .accepted)
        #expect(gated.language?.parts.map(\.verdict) == [nil])
        #expect(identifier.identifiedAudio.count == 1)
    }

    /// The transcriber can finish an utterance before VAD ends its segment.
    /// If the window hasn't been reached, the gate identifies what it has.
    @Test func aFinalBeforeTheSegmentEndsIsIdentifiedOnWhatWasHeard() async throws {
        let (gate, identifier) = Self.gate(
            SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)])
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.8))
        let gated = await gate.decide(finalUtterance("Vamos a ver", from: 0, to: 1.7))
        #expect(gated.disposition == .otherLanguage)
        #expect(identifier.identifiedAudio.map(\.sampleCount) == [27_200])
        // The segment's end doesn't identify it again.
        await gate.feed(SpeechScript.audio(from: 1.8, to: 2.0) + [.ended(SpeechScript.ended(0, from: 0, to: 1.7))])
        #expect(identifier.identifiedAudio.count == 1)
    }

    @Test func anUtteranceMostlyInEnglishIsSent() async throws {
        let (gate, _) = Self.gate(
            SpeakerTimeline([(0, 20, .owner)]), languages: [Self.spanish(from: 4, to: 6)])
        await gate.feed(SpeechScript.segment(0, from: 0, to: 3))
        await gate.feed(SpeechScript.segment(1, from: 4, to: 5.2))
        let gated = await gate.decide(finalUtterance("Say gracias in Spanish", from: 0, to: 5.2))
        #expect(gated.language?.parts.map(\.decision) == [.allowed, .otherLanguage])
        #expect(gated.disposition == .accepted)
    }

    // MARK: Failures and latency

    @Test func aFailedCheckLetsTheSpeechThrough() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), failure: LanguageIDError.invalidOutput)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Hello", from: 0, to: 2.5))
        #expect(gated.disposition == .accepted)
        #expect(gate.statistics.languageFailures == 1)
    }

    @Test func partialsOfOtherLanguageSpeechAreHeldBack() async throws {
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)])
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 2.2))
        let partial = TranscriptEvent.partial(text: "Y ahora", range: TimeRange(start: .zero, end: .seconds(2.2)))
        #expect(await gate.gate(partial) == nil)
        #expect(gate.statistics.suppressedPartials == 1)
    }

    /// The check runs while the speech is spoken, so a final normally
    /// finds it done: the filter adds nothing to the hold.
    @Test func aCheckDoneWhileSpeakingAddsNoHold() async throws {
        let clock = ManualClock()
        let (gate, _) = Self.gate(SpeakerTimeline([(0, 10, .owner)]), clock: clock)
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        let gated = await gate.decide(finalUtterance("Hello there", from: 0, to: 2.5))
        #expect(gated.language?.delay == .zero)
        #expect(gate.statistics.longestLanguageDelay == .zero)
    }

    /// A final that arrives while the check is still running waits for it,
    /// at most the decision timeout, and then goes on unidentified.
    @Test func aSlowCheckHoldsTheFinalOnlyUntilTheTimeout() async throws {
        let clock = ManualClock()
        let (gate, identifier) = Self.gate(
            SpeakerTimeline([(0, 10, .owner)]), languages: [Self.spanish(from: 0, to: 10)], delay: .seconds(5),
            clock: clock, configuration: LanguageFilterConfiguration(decisionTimeout: .milliseconds(300)))
        // 1.5 s of speech: under the window, so its end starts the check.
        await gate.feed([.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.8))
        let ending = Task { await gate.feed([.ended(SpeechScript.ended(0, from: 0, to: 1.5))]) }
        // The identifier records the audio, then sleeps out its delay.
        await clock.waitForSleepers()
        #expect(identifier.identifiedAudio.count == 1)

        let deciding = Task { await gate.decide(finalUtterance("Hola", from: 0, to: 1.5)) }
        // The final's wait for the check is the second sleeper.
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .milliseconds(300))
        let gated = await deciding.value

        #expect(gated.language?.parts.map(\.verdict) == [nil])
        #expect(gated.disposition == .accepted)
        #expect(gated.language?.delay == .milliseconds(300))
        #expect(gate.statistics.longestLanguageDelay == .milliseconds(300))

        clock.advance(by: .seconds(5))
        await ending.value
        #expect(await gate.languageVerdict(ofSegment: 0)?.language == Self.spanish)
    }

    /// The latency budget's `voiceid.gate` hold (#74) covers the filter's
    /// share and ends with the disposition the filter gave the final.
    @Test func theGateIntervalIncludesTheFilterAndEndsWithItsDisposition() async throws {
        let backend = RecordingSignpostBackend()
        let filter = LanguageFilter(
            identifier: ScriptedLanguageIdentifier(timeline: [Self.spanish(from: 0, to: 10)]),
            allowedLanguages: { [.english] })
        let gate = VerificationGate(
            verifier: ScriptedVerifier(SpeakerTimeline([(0, 20, .owner)])), languageFilter: filter,
            signposter: Signposter(category: .voiceID, backend: backend))
        await gate.feed(SpeechScript.segment(0, from: 0, to: 2.5))
        await gate.feed(SpeechScript.segment(1, from: 12, to: 14.5))

        _ = await gate.decide(finalUtterance("Hola", from: 0, to: 2.5))
        _ = await gate.decide(finalUtterance("Hello", from: 12, to: 14.5))

        #expect(backend.completedIntervals == ["voiceid.gate", "voiceid.gate"])
        #expect(backend.endMessages(of: "voiceid.gate") == ["otherLanguage", "accepted"])
        #expect(backend.openIntervals.isEmpty)
    }
}

/// The language filter and adaptive voiceprint updates (#49): the gate
/// hands accepted speech to adaptation only once its language is known,
/// and never speech in another language.
@Suite("Verification gate: language filter and adaptation")
struct VerificationGateLanguageAdaptationTests {
    static let owner = VerificationGateScenarioTests.owner

    /// The segments adaptation was handed.
    final class Observed: Sendable {
        private let segments = Mutex<[ScoredSpeechSegment]>([])
        func append(_ segment: ScoredSpeechSegment) { segments.withLock { $0.append(segment) } }
        var segmentIDs: [Int] { segments.withLock { $0.map(\.segmentID) } }
    }

    static func gate(
        languages: [ScriptedLanguageIdentifier.Stretch], delay: Duration = .zero,
        clock: any BlauClock = SystemClock(), seen: Observed
    ) async throws -> (VerificationGate, ScriptedLanguageIdentifier) {
        let embedder = ScriptedSpeakerEmbedder()
        let verifier = try SpeakerVerifier(
            embedder: embedder, voiceprint: try await SpeakerVerifierTests.ownerVoiceprint(embedder),
            gauges: PerformanceGauges())
        let identifier = ScriptedLanguageIdentifier(timeline: languages, delay: delay, clock: clock)
        let filter = LanguageFilter(identifier: identifier, allowedLanguages: { [.english] })
        let gate = VerificationGate(
            verifier: verifier, languageFilter: filter, clock: clock,
            onScoredSpeech: { segment in seen.append(segment) })
        return (gate, identifier)
    }

    /// The review's case: a voice voice ID accepts (the owner's here, or a
    /// TV's) speaking Spanish is dropped by the filter and not learned.
    @Test func acceptedSpeechInAnotherLanguageIsNotLearned() async throws {
        let seen = Observed()
        let (gate, _) = try await Self.gate(
            languages: [VerificationGateLanguageTests.spanish(from: 6, to: 10.5)], seen: seen)
        let scene = GateScenario(lines: [
            VerificationGateScenarioTests.line("One", Self.owner, from: 0, to: 4.5, isOwner: true),
            VerificationGateScenarioTests.line("Dos", Self.owner, from: 6, to: 10.5, isOwner: false),
            VerificationGateScenarioTests.line("Three", Self.owner, from: 12, to: 16.5, isOwner: true),
        ])
        let (sent, verdicts) = await scene.run(through: gate)

        #expect(sent == ["One", "Three"])
        // Voice ID accepted all three; the filter dropped the Spanish one.
        #expect(verdicts.map(\.decision) == [.accept, .accept, .accept])
        #expect(verdicts.map(\.disposition) == [.accepted, .otherLanguage, .accepted])
        #expect(seen.segmentIDs == [0, 2])
        #expect(gate.statistics.otherLanguageAdaptationsSkipped == 1)
    }

    /// A final that arrives before its segment reaches the window starts
    /// the segment's check; when the segment ends with that check still
    /// running, its accepted speech waits for the verdict.
    @Test(arguments: [true, false])
    func speechDecidedWhileItsCheckRunsWaitsForTheVerdict(isSpanish: Bool) async throws {
        let clock = ManualClock()
        let seen = Observed()
        let (gate, identifier) = try await Self.gate(
            languages: isSpanish ? [VerificationGateLanguageTests.spanish(from: 0, to: 10)] : [],
            delay: .seconds(1), clock: clock, seen: seen)
        let line = VerificationGateScenarioTests.line("Hola", Self.owner, from: 0, to: 4.5, isOwner: true)
        let track = GateScenario(lines: [line]).track
        let samples: @Sendable (Int64) -> Float = { index in index < track.count ? track[Int(index)] : 0 }

        await gate.feed(
            [.started(SpeechScript.onset(0, at: 0))] + SpeechScript.audio(from: 0, to: 1.5, samples: samples))
        // The transcriber is ahead of VAD: its final starts the check.
        let deciding = Task { await gate.decide(finalUtterance("Hola", from: 0, to: 1.5)) }
        // The identifier records the audio, then sleeps out its delay.
        await clock.waitForSleepers()
        #expect(identifier.identifiedAudio.count == 1)
        // The rest of the segment arrives and it ends, accepted.
        await gate.feed(SpeechScript.audio(from: 1.5, to: 4.8, samples: samples))
        await gate.feed([.ended(SpeechScript.ended(0, from: 0, to: 4.5))])
        #expect(await gate.decision(ofSegment: 0) == .accept)
        #expect(seen.segmentIDs.isEmpty)

        clock.advance(by: .seconds(1))
        _ = await deciding.value

        #expect(identifier.identifiedAudio.count == 1)
        #expect(gate.statistics.languageChecks == 1)
        if isSpanish {
            #expect(seen.segmentIDs.isEmpty)
            #expect(gate.statistics.otherLanguageAdaptationsSkipped == 1)
        } else {
            #expect(seen.segmentIDs == [0])
            #expect(gate.statistics.otherLanguageAdaptationsSkipped == 0)
        }
    }
}
