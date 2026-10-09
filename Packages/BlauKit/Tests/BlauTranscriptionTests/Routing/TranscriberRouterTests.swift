import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

@Suite("TranscriberRouter: engine choice and switching at utterance boundaries")
struct TranscriberRouterTests {
    private func makeRouter(
        _ engines: FakeEngines,
        preference: TranscriptionEnginePreference = .automatic,
        configuration: TranscriberRouter.Configuration = .standard,
        clock: ManualClock = ManualClock()
    ) -> TranscriberRouter {
        TranscriberRouter(
            parakeet: engines.provider(.parakeet), apple: engines.provider(.apple), preference: preference,
            configuration: configuration, clock: clock, signposter: .disabled(.asr))
    }

    /// Waits until the router runs `engine` (and no switch is pending).
    private func waitForEngine(_ engine: TranscriptionEngine, on router: TranscriberRouter) async throws {
        try await waitUntil { router.status.engine == engine && router.status.pendingEngine == nil }
        await router.waitForSwitch()
    }

    // MARK: Choosing at start

    @Test func startsParakeetWhenItCanRun() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        #expect(router.status == .init(engine: .parakeet, reason: .primary, pendingEngine: nil, isRunning: true))
        let parakeet = try #require(engines.latest(.parakeet))
        #expect(await parakeet.startPositions == [nil])
        #expect(engines.built(.apple).isEmpty)
    }

    @Test func startsAppleWhenTheUserChoseIt() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines, preference: .apple)
        try await router.start()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .userPreference)
        #expect(engines.built(.parakeet).isEmpty)
    }

    @Test func startsAppleWhenParakeetIsNotInstalled() async throws {
        let engines = FakeEngines()
        engines.setAvailable(.parakeet, false)
        let router = makeRouter(engines)
        try await router.start()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .primaryUnavailable)
    }

    @Test func fallsBackWhenTheChosenEngineFailsToLoad() async throws {
        let engines = FakeEngines()
        engines.setMakeError(.parakeet, FakeEngineError.cannotLoad)
        let router = makeRouter(engines)
        try await router.start()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .primaryUnavailable)
        #expect(router.statistics.failedActivations == 1)
    }

    @Test func throwsWhenNoEngineCanRun() async throws {
        let engines = FakeEngines()
        engines.setAvailable(.parakeet, false)
        engines.setAvailable(.apple, false)
        let router = makeRouter(engines)
        await #expect(throws: TranscriberRouterError.noEngineAvailable) {
            try await router.start()
        }
        #expect(router.status.isRunning == false)
    }

    // MARK: Switching

    @Test func aPreferenceChangeWaitsForTheEndOfTheUtterance() async throws {
        let engines = FakeEngines()
        let clock = ManualClock()
        let router = makeRouter(engines, clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))

        await parakeet.say("can you", from: 0.5, to: 1.0)
        try await log.waitForEvents(1)
        await router.setPreference(.apple)
        // The Apple engine is built at once and waits (the deadline timer
        // is sleeping).
        await clock.waitForSleepers(count: 1)
        #expect(router.status.pendingEngine == .apple)
        #expect(engines.built(.apple).count == 1)
        clock.advance(by: .seconds(1))
        #expect(router.status.engine == .parakeet)

        // The utterance ends; after the settle delay the router switches.
        await parakeet.commit("can you hear me", from: 0.5, to: 1.6)
        try await log.waitForFinals(1)
        await clock.waitForSleepers(count: 2)
        #expect(router.status.engine == .parakeet)
        clock.advance(by: .milliseconds(500))
        try await waitForEngine(.apple, on: router)

        let apple = try #require(engines.latest(.apple))
        #expect(await apple.startPositions == [.seconds(1.6)])
        #expect(await parakeet.finishes == 1)
        #expect(router.status.reason == .userPreference)
        #expect(router.statistics.switches == [.userPreference: 1])
        #expect(router.statistics.forcedSwitches == 0)

        // The new engine's events come through the same stream.
        await apple.commit("yes", from: 2.0, to: 2.4)
        try await log.waitForFinals(2)
        #expect(log.finals.map(\.text) == ["can you hear me", "yes"])
    }

    @Test func anIdleEngineIsSwitchedAtOnce() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        await router.setPreference(.apple)
        try await waitForEngine(.apple, on: router)
        let apple = try #require(engines.latest(.apple))
        #expect(await apple.startPositions == [nil])
        #expect(await engines.latest(.parakeet)?.finishes == 1)
    }

    @Test func speechStraightAfterAFinalPostponesTheSwitch() async throws {
        let engines = FakeEngines()
        let clock = ManualClock()
        let router = makeRouter(engines, preference: .automatic, clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))
        await parakeet.say("first", from: 0.5, to: 1.0)
        try await log.waitForEvents(1)
        await router.setPreference(.apple)
        await clock.waitForSleepers(count: 1)

        await parakeet.commit("first part", from: 0.5, to: 1.5)
        try await log.waitForEvents(2)
        await clock.waitForSleepers(count: 2)
        // The speaker goes on within the settle delay.
        await parakeet.say("second", from: 1.7, to: 2.0)
        try await log.waitForEvents(3)
        clock.advance(by: .milliseconds(500))
        try await Task.sleep(for: .milliseconds(20))
        #expect(router.status.engine == .parakeet)

        await parakeet.commit("second part", from: 1.7, to: 2.5)
        try await log.waitForEvents(4)
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .milliseconds(500))
        try await waitForEngine(.apple, on: router)
        #expect(await engines.latest(.apple)?.startPositions == [.seconds(2.5)])
    }

    @Test func aSwitchThatNeverFindsABoundaryIsForcedAndLosesNothing() async throws {
        let engines = FakeEngines()
        let clock = ManualClock()
        let router = makeRouter(
            engines, configuration: .init(settleDelay: .milliseconds(500), maximumSwitchDelay: .seconds(2)),
            clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))
        await parakeet.say("I keep talking", from: 0.5, to: 3.0)
        try await log.waitForEvents(1)
        await router.setPreference(.apple)
        await clock.waitForSleepers(count: 1)

        clock.advance(by: .seconds(2))
        try await waitForEngine(.apple, on: router)
        // Stopping Parakeet committed what was said; Apple resumes after it.
        try await log.waitForFinals(1)
        #expect(log.finals.map(\.text) == ["I keep talking"])
        #expect(await engines.latest(.apple)?.startPositions == [.seconds(3)])
        #expect(router.statistics.forcedSwitches == 1)
    }

    // MARK: Background inference (#26)

    @Test func isTheSpeechToTextStageOfTheBackgroundMonitor() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        #expect(router.inferenceStage == "asr")
        #expect(router.supportedBackends == [.neuralEngine, .systemSpeech])
        #expect(await router.inferenceBackend == .neuralEngine)
        await #expect(throws: InferenceBackendError.unsupported(stage: "asr", backend: .cpu)) {
            try await router.switchInferenceBackend(to: .cpu)
        }
    }

    @Test func movingToSystemSpeechHandsOverToAppleAndBack() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        let first = try #require(engines.latest(.parakeet))

        try await router.switchInferenceBackend(to: .systemSpeech)
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .background)
        #expect(await router.inferenceBackend == .systemSpeech)
        #expect(await first.finishes == 1)

        try await router.switchInferenceBackend(to: .neuralEngine)
        #expect(router.status.engine == .parakeet)
        #expect(router.status.reason == .primary)
        #expect(engines.built(.parakeet).count == 2)
        #expect(router.statistics.switches == [.background: 1, .primary: 1])
    }

    @Test func theMonitorsSwitchWaitsForTheEndOfTheUtterance() async throws {
        let engines = FakeEngines()
        let clock = ManualClock()
        let router = makeRouter(engines, clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))
        await parakeet.say("while I lock the phone", from: 0.5, to: 2.0)
        try await log.waitForEvents(1)

        let switched = Task { try await router.switchInferenceBackend(to: .systemSpeech) }
        await clock.waitForSleepers(count: 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(router.status.engine == .parakeet)
        #expect(router.status.pendingEngine == .apple)

        await parakeet.commit("while I lock the phone", from: 0.5, to: 2.2)
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .milliseconds(500))
        try await switched.value
        #expect(router.status.engine == .apple)
        #expect(await engines.latest(.apple)?.startPositions == [.seconds(2.2)])
    }

    @Test func aSystemSpeechRequestFailsWhenAppleCantRun() async throws {
        let engines = FakeEngines()
        engines.setMakeError(.apple, FakeEngineError.cannotLoad)
        let router = makeRouter(engines)
        try await router.start()
        await #expect(throws: TranscriberRouterError.engineUnavailable(.apple)) {
            try await router.switchInferenceBackend(to: .systemSpeech)
        }
        #expect(router.status.engine == .parakeet)
        #expect(await router.routingInputs.systemSpeechRequested == false)
    }

    @Test func theUsersChoiceOutlivesTheMonitorsReturnToTheNeuralEngine() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines, preference: .apple)
        try await router.start()
        try await router.switchInferenceBackend(to: .systemSpeech)
        try await router.switchInferenceBackend(to: .neuralEngine)
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .userPreference)
    }

    @Test func theBackgroundMonitorDrivesTheRouterOffScreen() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        let monitor = BackgroundInferenceMonitor(
            configuration: .init(mitigation: .switchToSystemTranscriber), clock: ManualClock(),
            signposter: .disabled(.asr))
        await monitor.register(router, budget: .milliseconds(320))

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        await monitor.waitUntilIdle()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .background)
        #expect(await monitor.snapshot.stages.first?.current == .systemSpeech)

        await monitor.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        await monitor.waitUntilIdle()
        #expect(router.status.engine == .parakeet)
    }

    @Test func phaseChangesReachTheRunningEngineButSwitchNothing() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        await router.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        #expect(router.status.engine == .parakeet)
        #expect(router.status.pendingEngine == nil)
        #expect(await engines.latest(.parakeet)?.transitions.map(\.to) == [.background])
    }

    @Test func memoryPressureMovesToAppleAndBack() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        await router.setMemoryPressure(true)
        try await waitForEngine(.apple, on: router)
        #expect(router.status.reason == .memoryPressure)
        await router.setMemoryPressure(false)
        try await waitForEngine(.parakeet, on: router)
    }

    @Test func memoryPressureLevelsAreFollowed() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        let (levels, continuation) = AsyncStream.makeStream(of: MemoryPressureLevel.self)
        await router.followMemoryPressure(levels)
        continuation.yield(.warning)
        continuation.yield(.critical)
        try await waitForEngine(.apple, on: router)
        continuation.yield(.normal)
        try await waitForEngine(.parakeet, on: router)
        await router.finish()
    }

    @Test func parakeetTakesOverOnceItsModelIsInstalled() async throws {
        let engines = FakeEngines()
        engines.setAvailable(.parakeet, false)
        let clock = ManualClock()
        let router = makeRouter(engines, clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let apple = try #require(engines.latest(.apple))
        await apple.commit("hello", from: 0.5, to: 1.0)
        try await log.waitForFinals(1)

        engines.setAvailable(.parakeet, true)
        await router.availabilityDidChange()
        // Deadline and settle timers.
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .milliseconds(500))
        try await waitForEngine(.parakeet, on: router)
        #expect(await engines.latest(.parakeet)?.startPositions == [.seconds(1)])
    }

    @Test func anEngineThatFailsToLoadKeepsTheCurrentOneUntilAvailabilityChanges() async throws {
        let engines = FakeEngines()
        engines.setMakeError(.apple, FakeEngineError.cannotLoad)
        let router = makeRouter(engines)
        try await router.start()
        await router.setPreference(.apple)
        try await waitUntil { router.statistics.failedActivations == 1 }
        #expect(router.status.engine == .parakeet)
        #expect(router.status.pendingEngine == nil)
        #expect(await router.routingInputs.appleAvailable == false)

        engines.setMakeError(.apple, nil)
        await router.availabilityDidChange()
        try await waitForEngine(.apple, on: router)
    }

    @Test func anEngineThatFailsToStartFallsBackToTheOther() async throws {
        let engines = FakeEngines()
        engines.setStartError(.apple, FakeEngineError.cannotStart)
        let clock = ManualClock()
        let router = makeRouter(engines, clock: clock)
        let log = TranscriptLog(router.events)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))
        await parakeet.commit("before", from: 0.2, to: 0.8)
        try await log.waitForFinals(1)

        await router.setPreference(.apple)
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .milliseconds(500))
        try await waitUntil { router.statistics.failedActivations == 1 }
        try await waitForEngine(.parakeet, on: router)
        #expect(router.status.reason == .fallback)
        let replacement = try #require(engines.latest(.parakeet))
        #expect(replacement.serial != parakeet.serial)
        #expect(await replacement.startPositions == [.seconds(0.8)])
    }

    @Test func theConversationIDReachesEveryEngine() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        let id = ConversationID()
        await router.setConversationID(id)
        #expect(await engines.latest(.parakeet)?.conversationIDs == [id])
        await router.setPreference(.apple)
        try await waitForEngine(.apple, on: router)
        #expect(await engines.latest(.apple)?.conversationIDs == [id])
    }

    @Test func settingsChangesAreFollowed() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        let settings = await TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(), availability: { .installed(locale: "en_US") })
        await router.followPreferences(settings.preferenceChanges())
        try await router.start()
        await MainActor.run { settings.forcesAppleEngine = true }
        try await waitForEngine(.apple, on: router)
        await MainActor.run { settings.forcesAppleEngine = false }
        try await waitForEngine(.parakeet, on: router)
        await router.finish()
    }

    // MARK: The conversation's router, as the app composes it

    @Test func theConversationRouterFollowsTheToggleMemoryPressureAndTheMonitor() async throws {
        let engines = FakeEngines()
        let settings = await TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(), availability: { .installed(locale: "en_US") })
        let (pressure, pressureLevels) = AsyncStream.makeStream(of: MemoryPressureLevel.self)
        let monitor = BackgroundInferenceMonitor(
            configuration: .init(mitigation: .switchToSystemTranscriber), clock: ManualClock(),
            signposter: .disabled(.asr))
        let router = await TranscriberRouter.conversation(
            parakeet: engines.provider(.parakeet), apple: engines.provider(.apple), settings: settings,
            memoryPressure: pressure, backgroundInference: monitor, clock: ManualClock(),
            signposter: .disabled(.asr))
        // The "asr" stage of the background monitor.
        #expect(await monitor.snapshot.stages.map(\.stage) == [TranscriberRouter.inferenceStage])
        try await router.start()
        #expect(router.status.engine == .parakeet)

        // The Settings toggle.
        await MainActor.run { settings.forcesAppleEngine = true }
        try await waitForEngine(.apple, on: router)
        #expect(router.status.reason == .userPreference)
        await MainActor.run { settings.forcesAppleEngine = false }
        try await waitForEngine(.parakeet, on: router)

        // Memory pressure.
        pressureLevels.yield(.critical)
        try await waitForEngine(.apple, on: router)
        #expect(router.status.reason == .memoryPressure)
        pressureLevels.yield(.normal)
        try await waitForEngine(.parakeet, on: router)

        // Off screen.
        await monitor.appPhaseDidChange(AppPhaseTransition(from: .inactive, to: .background))
        await monitor.waitUntilIdle()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .background)
        await monitor.appPhaseDidChange(AppPhaseTransition(from: .background, to: .active))
        await monitor.waitUntilIdle()
        #expect(router.status.engine == .parakeet)

        await router.finish()
        await monitor.unregister(stage: TranscriberRouter.inferenceStage)
        #expect(await engines.running().isEmpty)
    }

    @Test func theConversationRouterStartsOnTheEngineTheSettingsAskFor() async throws {
        let engines = FakeEngines()
        let settings = await TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(.apple), availability: { .installed(locale: "en_US") })
        let router = await TranscriberRouter.conversation(
            parakeet: engines.provider(.parakeet), apple: engines.provider(.apple), settings: settings,
            memoryPressure: AsyncStream { _ in }, backgroundInference: nil, clock: ManualClock(),
            signposter: .disabled(.asr))
        try await router.start()
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .userPreference)
        #expect(engines.built(.parakeet).isEmpty)
        await router.finish()
    }

    // MARK: Inputs that change while an engine is being built

    @Test func aPreferenceChangeWhileTheFirstEngineLoadsStartsOnlyOneEngine() async throws {
        let engines = FakeEngines()
        let gate = Gate()
        // Apple's engine downloads its assets on first use.
        engines.setMakeGate(.apple, gate)
        let router = makeRouter(engines, preference: .apple)
        let log = TranscriptLog(router.events)
        let started = Task { try await router.start() }
        try await waitUntil { engines.blockedMakes(.apple) == 1 }

        await router.setPreference(.automatic)
        // Nothing is built in parallel while Apple's engine loads.
        #expect(engines.built(.parakeet).isEmpty)
        #expect(router.status.engine == nil)

        engines.setMakeGate(.apple, nil)
        gate.open()
        try await started.value
        // The start re-decides from the new preference and hands over.
        try await waitForEngine(.parakeet, on: router)
        #expect(router.status.reason == .primary)
        #expect(router.status.isRunning)
        let running = await engines.running()
        #expect(running.map(\.engine) == [.parakeet])
        #expect(engines.built(.parakeet).count == 1)
        #expect(await engines.latest(.apple)?.finishes == 1)

        // Each utterance comes through once.
        let parakeet = try #require(engines.latest(.parakeet))
        await parakeet.commit("hello", from: 0.2, to: 0.8)
        try await log.waitForFinals(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.finals.map(\.text) == ["hello"])
    }

    @Test func memoryPressureWhileTheFirstEngineLoadsStartsOnlyOneEngine() async throws {
        let engines = FakeEngines()
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        let router = makeRouter(engines)
        let started = Task { try await router.start() }
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }

        await router.setMemoryPressure(true)
        await router.availabilityDidChange()
        #expect(engines.built(.apple).isEmpty)

        engines.setMakeGate(.parakeet, nil)
        gate.open()
        try await started.value
        try await waitForEngine(.apple, on: router)
        #expect(router.status.reason == .memoryPressure)
        #expect(await engines.running().map(\.engine) == [.apple])
        #expect(engines.built(.parakeet).count == 1)
    }

    @Test func theMonitorsRequestWhileTheFirstEngineLoadsIsHonoured() async throws {
        let engines = FakeEngines()
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        let router = makeRouter(engines)
        let started = Task { try await router.start() }
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }

        // The monitor waits for the router to settle rather than reading
        // "not on Apple's engine yet" as a failure.
        let switched = Task { try await router.switchInferenceBackend(to: .systemSpeech) }
        try await waitUntil { await router.routingInputs.systemSpeechRequested }
        #expect(engines.built(.apple).isEmpty)

        engines.setMakeGate(.parakeet, nil)
        gate.open()
        try await started.value
        try await switched.value
        #expect(router.status.engine == .apple)
        #expect(router.status.reason == .background)
        #expect(await engines.running().map(\.engine) == [.apple])
    }

    @Test func anInputChangeDuringASwitchsFallbackStartsOnlyOneEngine() async throws {
        let engines = FakeEngines()
        engines.setStartError(.apple, FakeEngineError.cannotStart)
        let router = makeRouter(engines)
        try await router.start()

        // Apple's engine fails to start; the fallback rebuilds Parakeet,
        // which takes a while. Engines become available again meanwhile.
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        await router.setPreference(.apple)
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }
        await router.availabilityDidChange()
        #expect(engines.blockedMakes(.parakeet) == 1)

        engines.setMakeGate(.parakeet, nil)
        gate.open()
        // The switch re-decides when it ends: Apple's engine gets another
        // chance, fails again, and Parakeet stays.
        try await waitUntil { router.statistics.failedActivations == 2 }
        await router.waitForSwitch()
        try await waitForEngine(.parakeet, on: router)
        #expect(router.status.reason == .fallback)
        #expect(await engines.running().map(\.engine) == [.parakeet])
    }

    @Test func stopThenStartDuringASwitchsFallbackRunsOneEngineAndFinishReleasesIt() async throws {
        let engines = FakeEngines()
        engines.setStartError(.apple, FakeEngineError.cannotStart)
        let router = makeRouter(engines)
        try await router.start()

        // Apple's engine fails to start; the fallback rebuilds Parakeet,
        // which takes a while.
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        await router.setPreference(.apple)
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }

        // The conversation is stopped and started again meanwhile.
        let stopped = Task { await router.stop() }
        try await waitUntil { router.status.isRunning == false }
        let started = Task { try await router.start() }
        try await Task.sleep(for: .milliseconds(20))
        // Nothing else is built while the switch is still building one.
        #expect(engines.blockedMakes(.parakeet) == 1)

        engines.setMakeGate(.parakeet, nil)
        gate.open()
        await stopped.value
        try await started.value
        await router.waitForSwitch()
        try await waitUntil { router.status.engine == .parakeet && router.status.pendingEngine == nil }

        // Exactly one engine runs: the start reuses the fallback's Parakeet.
        #expect(router.status.isRunning)
        #expect(await engines.running().map(\.engine) == [.parakeet])
        #expect(engines.built(.parakeet).count == 2)

        await router.finish()
        #expect(await engines.running().isEmpty)
        for parakeet in engines.built(.parakeet) {
            #expect(await parakeet.finishes == 1)
        }
    }

    @Test func stoppingWhileTheFirstEngineLoadsLeavesNothingRunning() async throws {
        let engines = FakeEngines()
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        let router = makeRouter(engines)
        let started = Task { try await router.start() }
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }

        await router.stop()
        #expect(router.status.isRunning == false)
        engines.setMakeGate(.parakeet, nil)
        gate.open()
        try await started.value
        #expect(await engines.running().isEmpty)
        #expect(router.status.isRunning == false)

        // The next start reuses the engine that was built.
        try await router.start()
        #expect(engines.built(.parakeet).count == 1)
        #expect(await engines.latest(.parakeet)?.startPositions == [nil, nil])
        #expect(await engines.running().map(\.engine) == [.parakeet])
    }

    @Test func finishingWhileTheFirstEngineLoadsReleasesIt() async throws {
        let engines = FakeEngines()
        let gate = Gate()
        engines.setMakeGate(.parakeet, gate)
        let router = makeRouter(engines)
        let started = Task { try await router.start() }
        try await waitUntil { engines.blockedMakes(.parakeet) == 1 }

        await router.finish()
        gate.open()
        try await started.value
        #expect(await engines.running().isEmpty)
        #expect(await engines.latest(.parakeet)?.finishes == 1)
        #expect(router.status.isRunning == false)
    }

    // MARK: Lifecycle

    @Test func stopAndStartReuseTheEngine() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        let parakeet = try #require(engines.latest(.parakeet))
        await router.stop()
        #expect(await parakeet.isRunning == false)
        #expect(router.status.isRunning == false)

        // Not running: a change takes effect at the next start.
        await router.setPreference(.apple)
        #expect(router.status.pendingEngine == nil)
        try await router.start()
        #expect(router.status.engine == .apple)
        #expect(await parakeet.finishes == 1)

        await router.stop()
        try await router.start()
        #expect(engines.built(.apple).count == 1)
        #expect(await engines.latest(.apple)?.startPositions == [nil, nil])
    }

    @Test func finishEndsTheEventsAndReleasesTheEngine() async throws {
        let engines = FakeEngines()
        let router = makeRouter(engines)
        try await router.start()
        await router.finish()
        #expect(await engines.latest(.parakeet)?.finishes == 1)
        var iterator = router.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        try await router.start()
        #expect(router.status.isRunning == false)
    }
}

@Suite("TranscriberRoutingPolicy")
struct TranscriberRoutingPolicyTests {
    typealias Inputs = TranscriberRoutingInputs

    @Test func parakeetIsTheDefault() {
        #expect(TranscriberRoutingPolicy.choose(Inputs())! == (.parakeet, .primary))
    }

    @Test func theUsersChoiceWins() {
        #expect(TranscriberRoutingPolicy.choose(Inputs(preference: .apple))! == (.apple, .userPreference))
        #expect(
            TranscriberRoutingPolicy.choose(Inputs(preference: .apple, appleAvailable: false))! == (
                .parakeet, .fallback
            ))
    }

    @Test func appleStandsInForAMissingParakeet() {
        #expect(TranscriberRoutingPolicy.choose(Inputs(parakeetAvailable: false))! == (.apple, .primaryUnavailable))
        #expect(TranscriberRoutingPolicy.choose(Inputs(parakeetAvailable: false, appleAvailable: false)) == nil)
    }

    @Test func theMonitorsRequestMovesToApple() {
        #expect(
            TranscriberRoutingPolicy.choose(Inputs(systemSpeechRequested: true))! == (.apple, .background))
        #expect(
            TranscriberRoutingPolicy.choose(Inputs(systemSpeechRequested: true, appleAvailable: false))!
                == (.parakeet, .fallback))
    }

    @Test func memoryPressureMovesToApple() {
        #expect(TranscriberRoutingPolicy.choose(Inputs(isUnderMemoryPressure: true))! == (.apple, .memoryPressure))
    }
}

@Suite("TranscriptionSettings")
@MainActor
struct TranscriptionSettingsTests {
    @Test func theToggleIsSavedAndPublished() async throws {
        let store = InMemoryTranscriptionPreferencesStore()
        let settings = TranscriptionSettings(store: store, availability: { .notInstalled(locale: "en_US") })
        #expect(settings.forcesAppleEngine == false)
        var changes = settings.preferenceChanges().makeAsyncIterator()
        #expect(await changes.next() == .automatic)

        settings.forcesAppleEngine = true
        #expect(settings.enginePreference == .apple)
        #expect(store.load() == .apple)
        #expect(await changes.next() == .apple)

        settings.forcesAppleEngine = true  // unchanged: nothing published
        settings.forcesAppleEngine = false
        #expect(await changes.next() == .automatic)

        // A new model reads what was saved.
        store.save(.apple)
        #expect(TranscriptionSettings(store: store).forcesAppleEngine)
    }

    @Test func availabilityIsCheckedOnDemand() async {
        let settings = TranscriptionSettings(
            store: InMemoryTranscriptionPreferencesStore(), availability: { .unsupportedLocale("xx_XX") })
        #expect(settings.appleAvailability == nil)
        await settings.refreshAvailability()
        #expect(settings.appleAvailability == .unsupportedLocale("xx_XX"))
        #expect(settings.appleAvailability?.isSupported == false)
    }

    @Test func userDefaultsKeepsTheChoice() throws {
        let suite = "blau.tests.transcription.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTranscriptionPreferencesStore(suiteName: suite)
        #expect(store.load() == .automatic)
        store.save(.apple)
        #expect(UserDefaultsTranscriptionPreferencesStore(suiteName: suite).load() == .apple)
        #expect(UserDefaults(suiteName: suite)?.string(forKey: "blau.transcription.engine") == "apple")
        store.save(.automatic)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "blau.transcription.engine") == nil)
    }
}
