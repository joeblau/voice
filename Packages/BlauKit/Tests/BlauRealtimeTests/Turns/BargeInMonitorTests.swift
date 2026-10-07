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
        let monitor: BargeInMonitor

        init(
            audible: Duration? = .seconds(2),
            microphone: [Float]? = nil,
            gate: (any BargeInSpeakerGate)? = nil,
            configuration: BargeInConfiguration = .standard
        ) {
            monitor = BargeInMonitor(
                target: target, playback: audible.map { FakePlayback(audible: $0) },
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
        await setup.monitor.handle(
            .speechEnded(
                SpeechSegment(
                    id: 3, sampleRange: MicSignal.offset(1.1)..<MicSignal.offset(1.4), sampleRate: MicSignal.rate,
                    endReason: .silence, detectedAt: MicSignal.offset(1.7), peakProbability: 0.9,
                    meanProbability: 0.8)))
        setup.clock.advance(by: .seconds(1))
        await Task.yield()
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
        setup.target.setSpeaking(false)
        #expect(await setup.monitor.handle(.speechStarted(.at(1.5, detected: 1.8, segment: 2))) == .agentNotSpeaking)
        setup.target.setSpeaking(true)
        setup.clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(setup.target.triggers.isEmpty)
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
