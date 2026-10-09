import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// The barge-in trigger and its echo guard (#37), against a fake target,
/// playback and microphone on a manual clock.
@Suite("Barge-in monitor")
struct BargeInMonitorTests {
    struct Setup {
        let target = FakeBargeInTarget()
        let clock = ManualClock()
        let signposts = RecordingSignpostBackend()
        let playback: FakePlayback?
        let monitor: BargeInMonitor

        /// - Parameter playback: The player, when the test moves it on
        ///   (otherwise one that has been audible for `audible`).
        init(
            audible: Duration? = .seconds(2),
            playback: FakePlayback? = nil,
            microphone: [Float]? = nil,
            gate: (any BargeInSpeakerGate)? = nil,
            configuration: BargeInConfiguration = .standard
        ) {
            let playback = playback ?? audible.map { FakePlayback(audible: $0) }
            self.playback = playback
            monitor = BargeInMonitor(
                target: target, playback: playback,
                microphone: microphone.map { FakeMicrophone($0) }, speakerGate: gate, configuration: configuration,
                clock: clock, signposter: Signposter(category: .realtime, backend: signposts))
        }
    }

    /// 1.5 s of a quiet room with the agent's faint echo, then the user,
    /// close to the phone.
    static let userOverQuietEcho = MicSignal.tone(-62, seconds: 1.5) + MicSignal.tone(-24, seconds: 1.5)

    // MARK: Barging in

    @Test func speechOverTheAgentBargesIn() async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho)
        setup.clock.advance(by: .seconds(10))
        let onset = SpeechOnset.at(1.5, detected: 1.8)

        let outcome = await setup.monitor.handle(.speechStarted(onset))

        guard case .bargedIn(let record) = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
        #expect(record.trigger.onset == onset)
        #expect(record.detectionLatency == .milliseconds(300))
        #expect(setup.target.triggers.count == 1)
        // The span starts when the onset reached the monitor.
        #expect(setup.target.triggers.first?.receivedAt == .seconds(10))
        #expect(setup.target.triggers.first?.speakerDecision == nil)
        let statistics = await setup.monitor.statistics
        #expect(statistics.onsetsWhileSpeaking == 1)
        #expect(statistics.bargeIns == 1)
        #expect(statistics.suppressedTotal == 0)
    }

    @Test func nothingHappensWhileGrokIsNotSpeaking() async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho)
        setup.target.setSpeaking(false)
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(outcome == .agentNotSpeaking)
        #expect(setup.target.triggers.isEmpty)
        #expect(await setup.monitor.statistics.onsetsWhileSpeaking == 0)
    }

    @Test func withoutPlaybackOrMicrophoneAnySpeechBargesIn() async throws {
        let setup = Setup(audible: nil)
        let outcome = await setup.monitor.handle(.speechStarted(.at(0.1, detected: 0.4)))
        #expect(setup.target.triggers.count == 1)
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in")
            return
        }
    }

    @Test func runHandlesTheVADStreamInOrder() async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho)
        let (events, continuation) = AsyncStream.makeStream(of: VoiceActivityEvent.self)
        let running = Task { await setup.monitor.run(events) }
        continuation.yield(.speechStarted(.at(1.5, detected: 1.8)))
        continuation.finish()
        await running.value
        #expect(setup.target.triggers.count == 1)
    }

    // MARK: Echo guard: levels

    /// Grok's voice leaking through the echo canceller trips VAD on a loud
    /// syllable: the "speech" is no louder than the leak before it.
    @Test func theAgentsOwnVoiceLeakingThroughDoesNotBargeIn() async throws {
        let setup = Setup(microphone: MicSignal.echo(loud: -36, soft: -46, seconds: 3))
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.7, detected: 2.0)))
        #expect(outcome == .suppressed(.echo))
        #expect(setup.target.triggers.isEmpty)
        #expect(await setup.monitor.statistics.suppressed == [.echo: 1])
        #expect(setup.signposts.events == ["realtime.bargeInSuppressed"])
    }

    /// The user talking over that same leak is far louder than it.
    @Test func theUserTalkingOverTheLeakStillBargesIn() async throws {
        let mic = MicSignal.echo(loud: -36, soft: -46, seconds: 1.7) + MicSignal.tone(-20, seconds: 1.3)
        let setup = Setup(microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.7, detected: 2.0)))
        #expect(setup.target.triggers.count == 1)
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// Regression (PR #123 review): the agent's voice leaking through with
    /// normal speech pauses. Nobody is talking; VAD trips on a -34 dBFS
    /// syllable. Its pauses sit at the -65 dBFS noise floor, so a median
    /// reference was -65 and the leak "speech" cleared the 9 dB margin by
    /// some 20 dB: the agent interrupted itself.
    @Test func theAgentsOwnVoiceLeakingWithSpeechPausesDoesNotBargeIn() async throws {
        let setup = Setup(microphone: MicSignal.leak(syllable: -34, pause: -65, seconds: 3))
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.8, detected: 2.1)))
        // Loud enough for the absolute floor: the relative check stops it.
        #expect(outcome == .suppressed(.echo))
        #expect(setup.target.triggers.isEmpty)
        #expect(await setup.monitor.statistics.suppressed == [.echo: 1])
    }

    /// The user, close to the phone, talking over that pause-heavy leak
    /// still barges in.
    @Test func theUserTalkingOverAPauseHeavyLeakStillBargesIn() async throws {
        let mic = MicSignal.leak(syllable: -34, pause: -65, seconds: 1.8) + MicSignal.tone(-24, seconds: 1.2)
        let setup = Setup(microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.8, detected: 2.1)))
        #expect(setup.target.triggers.count == 1)
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// Regression (PR #123 review round 2): the agent's leak holds a VAD
    /// segment open through a long reply, and VAD splits it every 8 s. The
    /// split's continuation onset sat 100 samples before `detectedAt`, under
    /// the 160 the level checks measure, so the guard let it through and the
    /// agent interrupted itself with nobody talking.
    @Test func continuationOnsetOfALeakDoesNotBargeIn() async throws {
        let mic = MicSignal.leak(syllable: -34, pause: -40, seconds: 10)
        let setup = Setup(audible: .seconds(5), microphone: mic)
        let detected = MicSignal.offset(9.0)
        let onset = SpeechOnset(
            segmentID: 4, startOffset: detected - 100, sampleRate: MicSignal.rate, isContinuation: true,
            detectedAt: detected)

        let outcome = await setup.monitor.handle(.speechStarted(onset))

        #expect(outcome == .continuation)
        #expect(setup.target.triggers.isEmpty)
        // A bookkeeping split, not an onset: nothing is counted or logged.
        let statistics = await setup.monitor.statistics
        #expect(statistics.onsetsWhileSpeaking == 0)
        #expect(statistics.suppressedTotal == 0)
        #expect(setup.signposts.events.isEmpty)
    }

    /// Even the user's own speech: a continuation carries on a segment
    /// whose real onset was already judged, so it is never judged again.
    @Test(arguments: [-100, 0, 4000])
    func continuationOnsetsAreNeverJudged(samplesBeforeDetection: Int64) async throws {
        let setup = Setup(microphone: MicSignal.tone(-70, seconds: 1.5) + MicSignal.tone(-20, seconds: 8.5))
        let detected = MicSignal.offset(9.0)
        let onset = SpeechOnset(
            segmentID: 7, startOffset: detected - samplesBeforeDetection, sampleRate: MicSignal.rate,
            isContinuation: true, detectedAt: detected)
        #expect(await setup.monitor.handle(.speechStarted(onset)) == .continuation)
        #expect(setup.target.triggers.isEmpty)
    }

    /// A continuation doesn't drop the open segment: its end is still
    /// handled, and the next real onset is judged as usual.
    @Test func aRealOnsetAfterAContinuationIsJudged() async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho)
        let continuation = SpeechOnset(
            segmentID: 1, startOffset: MicSignal.offset(1.0), sampleRate: MicSignal.rate, isContinuation: true,
            detectedAt: MicSignal.offset(1.0))
        #expect(await setup.monitor.handle(.speechStarted(continuation)) == .continuation)
        await setup.monitor.handle(
            .speechEnded(
                SpeechSegment(
                    id: 1, sampleRange: MicSignal.offset(1.0)..<MicSignal.offset(1.2), sampleRate: MicSignal.rate,
                    isContinuation: true, endReason: .silence, detectedAt: MicSignal.offset(1.4),
                    peakProbability: 0.9, meanProbability: 0.8)))
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8, segment: 2)))
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// Defence in depth: speech the history holds but that is too short to
    /// measure is suppressed rather than let through (fail closed).
    @Test func speechTooShortToMeasureDoesNotBargeIn() async throws {
        let setup = Setup(microphone: MicSignal.leak(syllable: -34, pause: -40, seconds: 3))
        let detected = MicSignal.offset(2.0)
        let onset = SpeechOnset(
            segmentID: 2, startOffset: detected - 100, sampleRate: MicSignal.rate, isContinuation: false,
            detectedAt: detected)
        #expect(await setup.monitor.handle(.speechStarted(onset)) == .suppressed(.echo))
        #expect(setup.target.triggers.isEmpty)
    }

    /// The same with an empty span (VAD reporting the onset at the moment
    /// it began).
    @Test func anEmptySpanTheHistoryHoldsDoesNotBargeIn() async throws {
        let setup = Setup(microphone: MicSignal.leak(syllable: -34, pause: -40, seconds: 3))
        #expect(await setup.monitor.handle(.speechStarted(.at(2.0, detected: 2.0))) == .suppressed(.echo))
        #expect(setup.target.triggers.isEmpty)
    }

    @Test func speechBelowTheMinimumLevelDoesNotBargeIn() async throws {
        let mic = MicSignal.tone(-80, seconds: 1.5) + MicSignal.tone(-52, seconds: 1.5)
        let setup = Setup(microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(outcome == .suppressed(.tooQuiet))
        #expect(setup.target.triggers.isEmpty)
    }

    @Test func turningTheLevelChecksOffLetsQuietSpeechThrough() async throws {
        let mic = MicSignal.tone(-80, seconds: 1.5) + MicSignal.tone(-52, seconds: 1.5)
        let setup = Setup(
            microphone: mic, configuration: BargeInConfiguration(minimumSpeechLevel: nil, echoMargin: nil))
        _ = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(setup.target.triggers.count == 1)
    }

    @Test func speechOutOfTheHistoryIsNotJudged() async throws {
        // The microphone's history doesn't reach the onset (it scrolled
        // out): nothing to measure, so the onset is let through.
        let setup = Setup(microphone: [])
        _ = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(setup.target.triggers.count == 1)
    }

    // MARK: Echo guard: the reference window

    /// Regression (PR #123 review round 2): the user says "uh" (150 ms, too
    /// short for VAD to confirm), pauses 350 ms, then "wait". The agent's
    /// voice is fully cancelled. With a 500 ms window the "uh" was 30 % of
    /// the reference, its 90th percentile was the user's own level, and the
    /// barge-in was suppressed as echo.
    @Test func theUserSayingUhBeforeBargingInStillBargesIn() async throws {
        let mic =
            MicSignal.floor(seconds: 2.5) + MicSignal.tone(-24, seconds: 0.15) + MicSignal.floor(seconds: 0.35)
            + MicSignal.tone(-24, seconds: 1)
        let setup = Setup(audible: .seconds(5), microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(3.0, detected: 3.3)))
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// The same for a 60 ms cough or lip smack 300 ms before the user
    /// speaks.
    @Test func aCoughJustBeforeTheUserSpeaksStillBargesIn() async throws {
        let mic =
            MicSignal.floor(seconds: 2.64) + MicSignal.tone(-20, seconds: 0.06) + MicSignal.floor(seconds: 0.3)
            + MicSignal.tone(-24, seconds: 1)
        let setup = Setup(audible: .seconds(5), microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(3.0, detected: 3.3)))
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// The window stops where the agent's audio started: before it there is
    /// no leak, only the user's own last utterance, which mustn't become the
    /// reference. Here the user spoke until 1.0 s, Grok became audible at
    /// 1.8 s, and the user cuts in at 2.6 s.
    @Test func theUsersEarlierUtteranceIsNotTheReference() async throws {
        let mic = MicSignal.tone(-24, seconds: 1.0) + MicSignal.floor(seconds: 1.6) + MicSignal.tone(-24, seconds: 1)
        let setup = Setup(audible: .milliseconds(1100), microphone: mic)
        let outcome = await setup.monitor.handle(.speechStarted(.at(2.6, detected: 2.9)))
        guard case .bargedIn = outcome else {
            Issue.record("Expected a barge-in, got \(String(describing: outcome))")
            return
        }
    }

    /// The longer window also keeps the leak's syllables in view across a
    /// pause between the agent's sentences: 700 ms of silence, then a leaked
    /// syllable trips VAD. A 500 ms window saw only the silence and let the
    /// agent interrupt itself.
    @Test func aLeakAfterAPauseBetweenSentencesDoesNotBargeIn() async throws {
        let mic =
            MicSignal.leak(syllable: -34, pause: -65, seconds: 2.0) + MicSignal.floor(seconds: 0.7)
            + MicSignal.leak(syllable: -34, pause: -65, seconds: 0.6)
        let setup = Setup(audible: .seconds(3), microphone: mic)
        #expect(await setup.monitor.handle(.speechStarted(.at(2.7, detected: 3.0))) == .suppressed(.echo))
        #expect(setup.target.triggers.isEmpty)
    }

    // MARK: Echo guard: grace period

    /// Playback started at 1.0 s; the onset at 1.1 s is in the 300 ms grace
    /// period, so it needs 200 ms of speech after 1.3 s. VAD confirms it at
    /// 1.4 s: 100 ms more are needed.
    @Test func speechInTheGracePeriodBargesInOnceItCarriesOn() async throws {
        let mic = MicSignal.tone(-70, seconds: 1.1) + MicSignal.tone(-24, seconds: 1.9)
        let setup = Setup(audible: .milliseconds(400), microphone: mic)
        setup.clock.advance(by: .seconds(5))
        let onset = SpeechOnset.at(1.1, detected: 1.4)

        let outcome = await setup.monitor.handle(.speechStarted(onset))
        #expect(outcome == .deferred)
        #expect(setup.target.triggers.isEmpty)

        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .milliseconds(99))
        await Task.yield()
        #expect(setup.target.triggers.isEmpty)
        setup.clock.advance(by: .milliseconds(1))
        try await waitUntil("barge-in after the grace period") { setup.target.triggers.count == 1 }
        // The span starts when the hold ended, not when VAD reported it.
        #expect(setup.target.triggers.first?.receivedAt == .seconds(5) + .milliseconds(100))
        #expect(setup.target.triggers.first?.onset == onset)
    }

    @Test func speechInTheGracePeriodThatEndsIsIgnored() async throws {
        let mic = MicSignal.tone(-70, seconds: 1.1) + MicSignal.tone(-24, seconds: 1.9)
        let setup = Setup(audible: .milliseconds(400), microphone: mic)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.4, segment: 3))) == .deferred)
        await setup.clock.waitForSleepers()
        #expect(await setup.monitor.hasPendingHold)
        await setup.monitor.handle(.speechEnded(.ended(3, from: 1.1, to: 1.4)))
        // The hold is gone and its task cancelled (it no longer sleeps on
        // the clock), so nothing can wake it to judge the ended speech.
        #expect(await !setup.monitor.hasPendingHold)
        #expect(setup.clock.sleeperCount == 0)
        setup.clock.advance(by: .seconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.target.triggers.isEmpty)
        #expect(await setup.monitor.statistics.suppressed == [.playbackGrace: 1])
    }

    @Test func graceSpeechThatTurnsOutToBeEchoIsSuppressedAfterTheHold() async throws {
        // The "speech" after the grace period is no louder than before.
        let setup = Setup(audible: .milliseconds(400), microphone: MicSignal.echo(loud: -36, soft: -46, seconds: 3))
        #expect(await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.4))) == .deferred)
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .milliseconds(100))
        try await waitUntil("judged") { await setup.monitor.statistics.suppressedTotal == 1 }
        #expect(await setup.monitor.statistics.suppressed == [.echo: 1])
        #expect(setup.target.triggers.isEmpty)
    }

    @Test func speechDecidedAfterTheGracePeriodGoesAtOnce() async throws {
        // Playback started at 0.5 s; onset at 0.7 s (in the grace period),
        // but VAD confirmed it at 1.2 s, 500 ms after the grace period
        // ended: enough speech after it has already been heard.
        let mic = MicSignal.tone(-70, seconds: 0.7) + MicSignal.tone(-24, seconds: 2.3)
        let setup = Setup(audible: .milliseconds(700), microphone: mic)
        _ = await setup.monitor.handle(.speechStarted(.at(0.7, detected: 1.2)))
        #expect(setup.target.triggers.count == 1)
    }

    @Test func speechThatStartedBeforePlaybackIsNotSuspect() async throws {
        // The user was already talking when Grok's audio started 100 ms
        // ago: it can't be its echo.
        let mic = MicSignal.tone(-70, seconds: 1.1) + MicSignal.tone(-24, seconds: 1.9)
        let setup = Setup(audible: .milliseconds(100), microphone: mic)
        _ = await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.4)))
        #expect(setup.target.triggers.count == 1)
    }

    @Test func aNewOnsetReplacesAHeldOne() async throws {
        let mic = MicSignal.tone(-70, seconds: 1.1) + MicSignal.tone(-24, seconds: 1.9)
        let setup = Setup(audible: .milliseconds(400), microphone: mic)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.4, segment: 1))) == .deferred)
        await setup.clock.waitForSleepers()
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8, segment: 2))) == .agentNotSpeaking)
        // The held onset's task is cancelled, not just forgotten.
        #expect(await !setup.monitor.hasPendingHold)
        #expect(setup.clock.sleeperCount == 0)
        setup.target.setSpeaking(true)
        setup.clock.advance(by: .seconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.target.triggers.isEmpty)
        #expect(await setup.monitor.statistics.suppressedTotal == 0)
    }

    /// A second onset in the grace period replaces the first one's hold:
    /// only one sleeps, and only the second is judged.
    @Test func aNewHeldOnsetCancelsTheEarlierHold() async throws {
        let mic = MicSignal.tone(-70, seconds: 1.1) + MicSignal.tone(-24, seconds: 1.9)
        let setup = Setup(playback: FakePlayback(audible: .milliseconds(400)), microphone: mic)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.4, segment: 1))) == .deferred)
        await setup.clock.waitForSleepers()
        // 50 ms later, VAD confirms another onset that began in the grace
        // period too.
        setup.clock.advance(by: .milliseconds(50))
        setup.playback?.set(audible: .milliseconds(450))
        #expect(await setup.monitor.handle(.speechStarted(.at(1.1, detected: 1.45, segment: 2))) == .deferred)
        await setup.clock.waitForSleepers()
        #expect(setup.clock.sleeperCount == 1)
        setup.clock.advance(by: .milliseconds(100))
        try await waitUntil("barge-in") { setup.target.triggers.count == 1 }
        #expect(setup.target.triggers.map(\.onset.segmentID) == [2])
    }

    // MARK: Speech under way when Grok starts

    /// The user starts talking at 1.0 s while Grok is thinking (VAD
    /// confirms at 1.3 s) and is still talking when Grok starts speaking
    /// 0.5 s later. No new onset comes, so before this was handled Grok
    /// talked over them until their end of utterance (PR #123 review, item
    /// 2). Now the speech is judged like speech from the grace period: held
    /// until 200 ms of it after the 300 ms grace period, then it barges in.
    @Test func speechUnderWayWhenGrokStartsSpeakingBargesIn() async throws {
        let mic = MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 3)
        let setup = Setup(audible: nil, microphone: mic)
        setup.target.setSpeaking(false)
        setup.clock.advance(by: .seconds(10))
        let onset = SpeechOnset.at(1.0, detected: 1.3, segment: 5)
        #expect(await setup.monitor.handle(.speechStarted(onset)) == .agentNotSpeaking)
        #expect(await setup.monitor.unjudgedSegment == 5)

        setup.clock.advance(by: .milliseconds(500))
        setup.target.setSpeaking(true)
        #expect(await setup.monitor.agentSpeakingChanged(true) == .deferred)
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .milliseconds(499))
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.target.triggers.isEmpty)
        setup.clock.advance(by: .milliseconds(1))
        try await waitUntil("barge-in") { setup.target.triggers.count == 1 }
        #expect(setup.target.triggers.first?.onset == onset)
        // The span starts when the hold ended.
        #expect(setup.target.triggers.first?.receivedAt == .seconds(11))
        #expect(await setup.monitor.statistics.onsetsWhileSpeaking == 1)
        #expect(await setup.monitor.unjudgedSegment == nil)
    }

    /// The grace period runs from when Grok actually became audible, after
    /// its jitter buffer filled, not from the state change.
    @Test func speechUnderWayIsHeldUntilAfterTheGracePeriodOfTheAudio() async throws {
        let mic = MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 3)
        let playback = FakePlayback(audible: nil)
        let setup = Setup(playback: playback, microphone: mic)
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.0, detected: 1.3, segment: 5))) == .agentNotSpeaking)
        setup.clock.advance(by: .milliseconds(500))
        setup.target.setSpeaking(true)
        #expect(await setup.monitor.agentSpeakingChanged(true) == .deferred)
        await setup.clock.waitForSleepers()
        // Audio came out 100 ms after the state change: 400 ms of it by the
        // end of the first hold, so 100 ms more speech is needed.
        playback.set(audible: .milliseconds(400))
        setup.clock.advance(by: .milliseconds(500))
        try await waitUntil("held again") { setup.clock.sleeperCount == 1 }
        #expect(setup.target.triggers.isEmpty)
        playback.set(audible: .milliseconds(500))
        setup.clock.advance(by: .milliseconds(100))
        try await waitUntil("barge-in") { setup.target.triggers.count == 1 }
    }

    /// The leak holding the segment open after the user stopped: the user
    /// talked until Grok started, then only Grok's voice leaking through
    /// (well under the user's level) keeps VAD's segment open. That doesn't
    /// barge in.
    @Test func aLeakHoldingTheUsersSegmentOpenDoesNotBargeIn() async throws {
        let mic =
            MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 0.8)
            + MicSignal.leak(syllable: -40, pause: -65, seconds: 2.2)
        let setup = Setup(audible: nil, microphone: mic)
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.0, detected: 1.3, segment: 5))) == .agentNotSpeaking)
        setup.clock.advance(by: .milliseconds(500))
        setup.target.setSpeaking(true)
        #expect(await setup.monitor.agentSpeakingChanged(true) == .deferred)
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .milliseconds(500))
        try await waitUntil("judged") { await setup.monitor.statistics.suppressedTotal == 1 }
        #expect(await setup.monitor.statistics.suppressed == [.echo: 1])
        #expect(setup.target.triggers.isEmpty)
    }

    /// Speech that ended before Grok started is left to the final utterance.
    @Test func speechThatEndedBeforeGrokStartsIsNotJudged() async throws {
        let setup = Setup(audible: nil, microphone: MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 3))
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.0, detected: 1.3, segment: 5))) == .agentNotSpeaking)
        await setup.monitor.handle(.speechEnded(.ended(5, from: 1.0, to: 1.6)))
        #expect(await setup.monitor.unjudgedSegment == nil)
        setup.target.setSpeaking(true)
        #expect(await setup.monitor.agentSpeakingChanged(true) == nil)
        #expect(setup.clock.sleeperCount == 0)
        #expect(setup.target.triggers.isEmpty)
    }

    /// Only the start of Grok speaking judges it, once; the end and a
    /// repeated "speaking" don't.
    @Test func onlyTheStartOfGrokSpeakingJudgesSpeechUnderWay() async throws {
        let setup = Setup(audible: nil, microphone: MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 3))
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.agentSpeakingChanged(false) == nil)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.0, detected: 1.3, segment: 5))) == .agentNotSpeaking)
        setup.target.setSpeaking(true)
        #expect(await setup.monitor.agentSpeakingChanged(true) == .deferred)
        #expect(await setup.monitor.agentSpeakingChanged(true) == nil)
    }

    /// `run` follows the target's `agentSpeakingChanges()`.
    @Test func runJudgesSpeechUnderWayWhenTheTargetStartsSpeaking() async throws {
        let setup = Setup(audible: nil, microphone: MicSignal.floor(seconds: 1.0) + MicSignal.tone(-24, seconds: 3))
        setup.target.setSpeaking(false)
        let (events, continuation) = AsyncStream.makeStream(of: VoiceActivityEvent.self)
        let running = Task { await setup.monitor.run(events) }
        continuation.yield(.speechStarted(.at(1.0, detected: 1.3, segment: 5)))
        try await waitUntil("noted") { await setup.monitor.unjudgedSegment == 5 }
        setup.target.announceSpeaking(true)
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .milliseconds(500))
        try await waitUntil("barge-in") { setup.target.triggers.count == 1 }
        continuation.finish()
        await running.value
    }

    // MARK: The player's audible duration

    /// The grace period runs from when the agent's audio started after
    /// silence, not from each item (PR #123 review, item 3): a second item
    /// that plays straight on doesn't restart it. Silence (idle) does.
    @Test func thePlayersAudibleDurationRunsAcrossItemsUntilItGoesIdle() async throws {
        let player = StreamingAudioPlayer(clock: ManualClock(), signposter: .disabled(.audio))
        let first = PlaybackItemID(itemID: "item_1")
        let second = PlaybackItemID(itemID: "item_2")
        let third = PlaybackItemID(itemID: "item_3")
        #expect(player.audibleDuration == nil)
        _ = player.enqueue(samples: [Float](repeating: 0.25, count: 2_400), item: first)  // 100 ms
        _ = player.enqueue(samples: [Float](repeating: 0.25, count: 14_400), item: second)  // 600 ms
        player.finish(first)
        player.finish(second)
        var buffer = [Float](repeating: 0, count: 480)  // 20 ms
        func render(_ cycles: Int) {
            for _ in 0..<cycles {
                buffer.withUnsafeMutableBufferPointer { _ = player.render(into: $0) }
            }
        }
        render(15)
        // 100 ms of the first item and 200 ms of the second: 300 ms, not the
        // second item's 200.
        #expect(player.playedItem(for: second)?.playedDuration == .milliseconds(200))
        #expect(player.audibleDuration == .milliseconds(300))
        render(25)
        #expect(player.snapshot.state == .idle)
        #expect(player.audibleDuration == nil)
        // After silence the canceller converges again: it starts over.
        _ = player.enqueue(samples: [Float](repeating: 0.25, count: 4_800), item: third)
        player.finish(third)
        render(2)
        #expect(player.audibleDuration == .milliseconds(40))
    }

    // MARK: Voice ID

    @Test func aRejectedSpeakerDoesNotBargeIn() async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho, gate: FakeSpeakerGate(decision: .reject))
        let outcome = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(outcome == .suppressed(.otherSpeaker))
        #expect(setup.target.triggers.isEmpty)
    }

    @Test(arguments: [SpeakerDecision.accept, .uncertain])
    func anAcceptedOrUncertainSpeakerBargesIn(decision: SpeakerDecision) async throws {
        let setup = Setup(microphone: Self.userOverQuietEcho, gate: FakeSpeakerGate(decision: decision))
        _ = await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8)))
        #expect(setup.target.triggers.map(\.speakerDecision) == [decision])
    }

    // MARK: Levels

    @Test func levelsAreMeasuredInDecibels() {
        #expect(
            abs(
                BargeInMonitor.decibels(AudioFrame(samples: MicSignal.tone(-30, seconds: 0.2), sampleOffset: 0).rms)
                    + 30) < 0.1)
        #expect(BargeInMonitor.decibels(0) == -160)
        let echo = AudioFrame(
            samples: MicSignal.tone(-30, seconds: 0.2) + MicSignal.tone(-50, seconds: 0.4), sampleOffset: 0)
        // Twice as many 20 ms pieces at -50 as at -30: the reference is the
        // loud level, the leak's syllables, not its typical (median) level.
        #expect(abs(BargeInMonitor.referenceLevel(of: echo) + 30) < 0.5)
    }

    @Test func theReferenceIsTheLeaksSyllablesNotItsPauses() {
        // 500 ms of a leak that is mostly pause: its median is the -65 dBFS
        // noise floor, but VAD trips on the -34 dBFS syllables.
        let leak = AudioFrame(samples: MicSignal.leak(syllable: -34, pause: -65, seconds: 0.5), sampleOffset: 0)
        #expect(abs(BargeInMonitor.referenceLevel(of: leak) + 34) < 1)
    }

    @Test func oneClickDoesNotSetTheReference() {
        // A single 20 ms click among 24 quiet pieces: a maximum would jump
        // to it, the 90th percentile stays at the room's level.
        let frame = AudioFrame(
            samples: MicSignal.tone(-50, seconds: 0.24) + MicSignal.tone(-10, seconds: 0.02)
                + MicSignal.tone(-50, seconds: 0.24),
            sampleOffset: 0)
        #expect(abs(BargeInMonitor.referenceLevel(of: frame) + 50) < 0.5)
    }
}
