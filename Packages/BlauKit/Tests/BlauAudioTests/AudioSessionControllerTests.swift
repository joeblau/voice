import AVFAudio
import BlauCore
import BlauTelemetry
import Testing

@testable import BlauAudio

@Suite("AudioSessionController: start and stop", .timeLimit(.minutes(1)))
struct AudioSessionStartStopTests {
    @Test func startsInIdleWithTheSessionsRoute() async {
        let harness = Harness()
        let snapshot = await harness.controller.snapshot
        #expect(snapshot == AudioSessionSnapshot(state: .idle, route: .speaker))
        #expect(harness.session.calls.isEmpty)
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func startConfiguresTheSessionThenEnablesVoiceProcessingBeforeStartingTheEngine() async {
        let harness = Harness()
        let state = await harness.controller.start()

        #expect(state == .running)
        #expect(harness.session.calls == [.configure(.voiceChat), .activate])
        // Voice processing is part of prepare, which must precede start.
        #expect(
            harness.engine.calls == [
                .stop, .teardown,
                .prepare(voiceProcessing: VoiceProcessingConfiguration(), components: 0),
                .start,
            ]
        )
        #expect(harness.engine.isRunning)
    }

    @Test func voiceChatConfigurationMatchesTheDesign() {
        let configuration = AudioSessionConfiguration.voiceChat
        #expect(configuration.preferredSampleRate == 48_000)
        #expect(configuration.preferredIOBufferDuration == .milliseconds(20))
        #expect(configuration.routesToSpeakerByDefault)
        #expect(configuration.allowsBluetoothHFP)
        #expect(configuration.voiceProcessing.isEnabled)
        #expect(configuration.voiceProcessing.automaticGainControl)
        #expect(configuration.voiceProcessing.advancedDucking)
        #expect(configuration.voiceProcessing.duckingLevel == .min)
    }

    @Test func startIsANoOpWhileRunning() async {
        let harness = Harness()
        await harness.startRunning()
        let state = await harness.controller.start()
        #expect(state == .running)
        #expect(harness.session.activations == 1)
        #expect(harness.engine.starts == 1)
    }

    @Test func stopTearsDownTheEngineAndDeactivatesTheSession() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.stop()

        #expect(await harness.controller.state == .idle)
        #expect(!harness.engine.isRunning)
        #expect(Array(harness.engine.calls.suffix(2)) == [.stop, .teardown])
        #expect(harness.session.calls.last == .deactivate)
    }

    @Test func stopWhileIdleDoesNotDeactivate() async {
        let harness = Harness()
        await harness.controller.stop()
        #expect(await harness.controller.state == .idle)
        #expect(harness.session.deactivations == 0)
    }

    @Test func canRestartAfterStop() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.stop()
        await harness.startRunning()
        #expect(harness.session.activations == 2)
        #expect(harness.engine.starts == 2)
    }

    @Test func startInstallsRegisteredComponents() async {
        let harness = Harness()
        let capture = RecordingComponent()
        let playback = RecordingComponent()
        await harness.controller.register(capture)
        await harness.controller.register(playback)
        await harness.controller.register(capture)  // duplicates are ignored
        await harness.startRunning()

        #expect(harness.engine.installedComponents == [ObjectIdentifier(capture), ObjectIdentifier(playback)])
    }

    @Test func registeringWhileRunningRebuildsTheGraph() async {
        let harness = Harness()
        await harness.startRunning()
        let capture = RecordingComponent()

        await harness.controller.register(capture)
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.installedComponents == [ObjectIdentifier(capture)])
        #expect(await harness.controller.state == .running)

        await harness.controller.unregister(capture)
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.installedComponents.isEmpty)
        #expect(harness.engine.starts == 3)
    }

    @Test func startIsSignposted() async {
        let harness = Harness()
        await harness.startRunning()
        #expect(harness.signposts.completedIntervals == ["audio.sessionStart"])
        #expect(harness.signposts.openIntervals.isEmpty)
    }
}

@Suite("AudioSessionController: microphone permission", .timeLimit(.minutes(1)))
struct AudioSessionPermissionTests {
    @Test func asksWhenUndeterminedAndRunsWhenGranted() async {
        let harness = Harness(permission: FakeMicrophonePermission(.undetermined, autoAnswer: true))
        let state = await harness.controller.start()
        #expect(state == .running)
        #expect(harness.permission.requests == 1)
    }

    @Test func failsWhenTheUserDeclines() async {
        let harness = Harness(permission: FakeMicrophonePermission(.undetermined, autoAnswer: false))
        let state = await harness.controller.start()
        #expect(state == .failed(.microphonePermissionDenied))
        #expect(harness.session.activations == 0)
        #expect(harness.engine.starts == 0)
    }

    @Test func failsWithoutPromptingWhenAlreadyDenied() async {
        let harness = Harness(permission: FakeMicrophonePermission(.denied))
        let state = await harness.controller.start()
        #expect(state == .failed(.microphonePermissionDenied))
        #expect(harness.permission.requests == 0)
        #expect(harness.session.calls.isEmpty)
    }

    @Test func publishesStartingWhileThePromptIsUp() async {
        let harness = Harness(permission: FakeMicrophonePermission(.undetermined, autoAnswer: nil))
        let start = Task { await harness.controller.start() }
        await harness.permission.waitForPrompt()
        #expect(await harness.controller.state == .starting)

        harness.permission.answer(true)
        #expect(await start.value == .running)
    }

    @Test func stopDuringThePromptWins() async {
        let harness = Harness(permission: FakeMicrophonePermission(.undetermined, autoAnswer: nil))
        let start = Task { await harness.controller.start() }
        await harness.permission.waitForPrompt()

        await harness.controller.stop()
        harness.permission.answer(true)

        #expect(await start.value == .idle)
        #expect(harness.session.activations == 0)
        #expect(harness.engine.starts == 0)
    }

    @Test func secondStartDuringThePromptDoesNotPromptAgain() async {
        let harness = Harness(permission: FakeMicrophonePermission(.undetermined, autoAnswer: nil))
        let first = Task { await harness.controller.start() }
        await harness.permission.waitForPrompt()

        #expect(await harness.controller.start() == .starting)
        harness.permission.answer(true)
        #expect(await first.value == .running)
        #expect(harness.permission.requests == 1)
    }
}

@Suite("AudioSessionController: failures", .timeLimit(.minutes(1)))
struct AudioSessionFailureTests {
    @Test func configurationFailureFails() async {
        let harness = Harness()
        harness.session.failConfigurations(1)
        let state = await harness.controller.start()
        guard case .failed(.configurationFailed(let error)) = state else {
            Issue.record("Expected configurationFailed, got \(state)")
            return
        }
        #expect(error.code == -50)
        #expect(harness.session.activations == 0)
    }

    @Test func activationFailureFailsWithoutStartingTheEngine() async {
        let harness = Harness()
        harness.session.failActivations(1)
        let state = await harness.controller.start()
        guard case .failed(.activationFailed(let error)) = state else {
            Issue.record("Expected activationFailed, got \(state)")
            return
        }
        #expect(error.code == 561_017_449)
        #expect(harness.engine.starts == 0)
        #expect(harness.session.deactivations == 0)
    }

    @Test func graphSetupFailureFailsAndDeactivates() async {
        let harness = Harness()
        harness.engine.failPrepares(1)
        let state = await harness.controller.start()
        guard case .failed(.graphSetupFailed) = state else {
            Issue.record("Expected graphSetupFailed, got \(state)")
            return
        }
        #expect(harness.engine.starts == 0)
        #expect(harness.session.calls.last == .deactivate)
    }

    @Test func engineStartFailureFailsAndDeactivates() async {
        let harness = Harness()
        harness.engine.failStarts(1)
        let state = await harness.controller.start()
        guard case .failed(.engineStartFailed(let error)) = state else {
            Issue.record("Expected engineStartFailed, got \(state)")
            return
        }
        #expect(error.code == -10_875)
        #expect(harness.session.calls.last == .deactivate)
        #expect(Array(harness.engine.calls.suffix(2)) == [.stop, .teardown])
    }

    @Test func startRetriesFromFailed() async {
        let harness = Harness()
        harness.engine.failStarts(1)
        #expect(await harness.controller.start() != .running)
        #expect(await harness.controller.start() == .running)
    }

    @Test func stopFromFailedReturnsToIdle() async {
        let harness = Harness(permission: FakeMicrophonePermission(.denied))
        await harness.controller.start()
        await harness.controller.stop()
        #expect(await harness.controller.state == .idle)
    }

    @Test func systemErrorKeepsDomainAndCode() {
        let error = SystemError(FakeAudioError(code: 42))
        #expect(error.code == 42)
        #expect(error.domain.contains("FakeAudioError"))
        #expect(SystemError(error) == error)
        #expect(error.description == "\(error.domain) 42")
    }
}

@Suite("AudioSessionController: interruptions", .timeLimit(.minutes(1)))
struct AudioSessionInterruptionTests {
    /// The phone-call acceptance criterion: a call interrupts the session,
    /// and when it ends with `.shouldResume` audio comes back by itself.
    @Test func survivesAPhoneCallAndResumes() async {
        let harness = Harness()
        let capture = RecordingComponent()
        await harness.controller.register(capture)
        await harness.startRunning()

        // Incoming call answered: the system stops the engine and
        // deactivates the session.
        harness.engine.simulateUnexpectedStop()
        await harness.controller.handle(.interruptionBegan(.default))
        #expect(await harness.controller.state == .interrupted)
        #expect(!harness.engine.isRunning)

        // Call ended.
        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .running)
        #expect(harness.engine.isRunning)
        #expect(harness.session.activations == 2)
        #expect(harness.engine.starts == 2)
        #expect(harness.engine.installedComponents == [ObjectIdentifier(capture)])
        #expect(harness.signposts.events == ["audio.interruptionBegan", "audio.interruptionEnded"])
    }

    @Test func staysInterruptedWithoutShouldResumeUntilStart() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.controller.handle(.interruptionEnded(shouldResume: false))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .interrupted)
        #expect(harness.session.activations == 1)

        #expect(await harness.controller.start() == .running)
        #expect(harness.session.activations == 2)
    }

    @Test func interruptionWhileIdleIsIgnored() async {
        let harness = Harness()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.state == .idle)
        #expect(harness.session.calls.isEmpty)
    }

    @Test func duplicateNotificationsAreIdempotent() async {
        // iOS 27 posts both the legacy interruption notification and the
        // new activation notifications for the same interruption.
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.controller.handle(.interruptionBegan(.default))
        #expect(await harness.controller.state == .interrupted)

        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.controller.waitForPendingRebuild()
        await harness.controller.handle(.interruptionEnded(shouldResume: true))

        #expect(await harness.controller.state == .running)
        #expect(harness.engine.starts == 2)
    }

    @Test func aNewInterruptionCancelsAPendingResume() async {
        let harness = Harness(retryDelays: [.milliseconds(50)])
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.clock.waitForSleepers(count: 1)

        await harness.controller.handle(.interruptionBegan(.default))
        harness.clock.advance(by: .milliseconds(50))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .interrupted)
        #expect(harness.engine.starts == 1)
    }

    @Test func stopCancelsAPendingResume() async {
        let harness = Harness(retryDelays: [.milliseconds(50)])
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.controller.handle(.interruptionEnded(shouldResume: true))
        await harness.clock.waitForSleepers(count: 1)

        await harness.controller.stop()
        harness.clock.advance(by: .milliseconds(50))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .idle)
        #expect(harness.engine.starts == 1)
    }

    @Test func resumeRetriesWhileTheCallStillHoldsTheMic() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        harness.session.failActivations(1)
        await harness.controller.handle(.interruptionEnded(shouldResume: true))

        await harness.clock.waitForSleepers(count: 1)
        harness.clock.advance(by: .milliseconds(100))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .running)
        #expect(harness.session.activations == 3)
    }
}

@Suite("AudioSessionController: routes", .timeLimit(.minutes(1)))
struct AudioSessionRouteTests {
    /// The route acceptance criterion: AirPods connect mid-session (the
    /// hardware format changes and the engine stops itself), then they are
    /// taken out and audio falls back to the speaker. Capture and playback
    /// components are reinstalled each time and the session keeps running.
    @Test func switchingBetweenAirPodsAndSpeakerKeepsAudioRunning() async {
        let harness = Harness()
        let capture = RecordingComponent()
        let playback = RecordingComponent()
        await harness.controller.register(capture)
        await harness.controller.register(playback)
        await harness.startRunning()
        let components = [ObjectIdentifier(capture), ObjectIdentifier(playback)]

        // AirPods connect: route change, then a configuration change.
        harness.session.route = .airPods
        await harness.controller.handle(.routeChanged(.newDeviceAvailable, route: .airPods))
        #expect(await harness.controller.snapshot == AudioSessionSnapshot(state: .running, route: .airPods))
        // Through the engine's notification stream, as on a device.
        harness.engine.simulateConfigurationChange()
        await harness.waitForEngineStarts(2)
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.snapshot == AudioSessionSnapshot(state: .running, route: .airPods))
        #expect(harness.engine.isRunning)
        #expect(harness.engine.installedComponents == components)

        // AirPods out: back to the speaker. This time the engine stops
        // without a configuration-change notification.
        harness.session.route = .speaker
        harness.engine.simulateUnexpectedStop()
        await harness.controller.handle(.routeChanged(.oldDeviceUnavailable, route: .speaker))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.snapshot == AudioSessionSnapshot(state: .running, route: .speaker))
        #expect(harness.engine.isRunning)
        #expect(harness.engine.installedComponents == components)
        #expect(harness.engine.starts == 3)
        // The session stays configured for voice chat throughout.
        #expect(harness.session.calls.allSatisfy { $0 == .configure(.voiceChat) || $0 == .activate })
    }

    @Test func routeChangeWithARunningEngineDoesNotRebuild() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.routeChanged(.override, route: .speaker))
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.starts == 1)
    }

    @Test func routeChangeWhileIdleOnlyUpdatesTheRoute() async {
        let harness = Harness()
        await harness.controller.handle(.routeChanged(.newDeviceAvailable, route: .airPods))
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.snapshot == AudioSessionSnapshot(state: .idle, route: .airPods))
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func categoryChangedByAnotherFrameworkIsReapplied() async {
        let harness = Harness()
        await harness.startRunning()

        // Our own setCategory: nothing to do.
        await harness.controller.handle(.routeChanged(.categoryChange, route: .speaker))
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.starts == 1)

        // Someone else changed it.
        harness.session.reportsConfigured = false
        await harness.controller.handle(.routeChanged(.categoryChange, route: .speaker))
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.starts == 2)
        #expect(harness.session.calls.count { $0 == .configure(.voiceChat) } == 2)
    }

    @Test func noSuitableRouteFails() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.routeChanged(.noSuitableRouteForCategory, route: .none))
        #expect(await harness.controller.state == .failed(.noSuitableRoute))
        #expect(!harness.engine.isRunning)
    }

    @Test func configurationChangeRetriesWithBackoff() async {
        let harness = Harness()
        await harness.startRunning()
        harness.engine.failStarts(2)
        harness.engine.simulateUnexpectedStop()
        await harness.controller.engineConfigurationChanged(engineID: 0)

        // Attempt 1 fails at once; attempt 2 waits 100 ms and fails;
        // attempt 3 waits 250 ms and succeeds.
        await harness.clock.waitForSleepers(count: 1)
        #expect(harness.engine.starts == 2)
        harness.clock.advance(by: .milliseconds(100))
        await harness.clock.waitForSleepers(count: 1)
        #expect(harness.engine.starts == 3)
        harness.clock.advance(by: .milliseconds(250))
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.controller.state == .running)
        #expect(harness.engine.starts == 4)
        #expect(harness.signposts.completedIntervals.filter { $0 == "audio.graphRebuild" }.count == 3)
    }

    @Test func configurationChangeFailsAfterTheLastAttempt() async {
        let harness = Harness(retryDelays: [.zero])
        await harness.startRunning()
        harness.engine.failStarts(1)
        harness.engine.simulateUnexpectedStop()
        await harness.controller.engineConfigurationChanged(engineID: 0)
        await harness.controller.waitForPendingRebuild()

        guard case .failed(.engineStartFailed) = await harness.controller.state else {
            Issue.record("Expected engineStartFailed")
            return
        }
        #expect(harness.session.calls.last == .deactivate)
    }

    @Test func configurationChangeWhileIdleIsIgnored() async {
        let harness = Harness()
        await harness.controller.engineConfigurationChanged(engineID: 0)
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func configurationChangeNotificationTriggersARebuild() async {
        // Through the engine's stream rather than calling the handler.
        let harness = Harness()
        await harness.startRunning()
        harness.engine.simulateConfigurationChange()

        // The state stays `running` throughout, so there is no snapshot to
        // wait for; wait for the engine to be started again instead.
        await harness.waitForEngineStarts(2)
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.state == .running)
    }
}

@Suite("AudioSessionController: media services", .timeLimit(.minutes(1)))
struct AudioSessionMediaServicesTests {
    @Test func resetRecreatesTheEngineAndResumes() async {
        let harness = Harness()
        let capture = RecordingComponent()
        await harness.controller.register(capture)
        await harness.startRunning()
        let oldEngine = harness.engine

        await harness.controller.handle(.mediaServicesLost)
        #expect(await harness.controller.state == .interrupted)

        await harness.controller.handle(.mediaServicesReset)
        await harness.controller.waitForPendingRebuild()

        #expect(harness.engines.all.count == 2)
        let newEngine = harness.engine
        #expect(newEngine !== oldEngine)
        #expect(await harness.controller.state == .running)
        #expect(newEngine.isRunning)
        #expect(newEngine.installedComponents == [ObjectIdentifier(capture)])
        #expect(harness.session.calls.count { $0 == .configure(.voiceChat) } == 2)
        // Nothing touched the dead engine after the loss.
        #expect(oldEngine.starts == 1)
    }

    @Test func resetWithoutALossNoticeStillResumes() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.mediaServicesReset)
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.state == .running)
        #expect(harness.engine.starts == 1)
        #expect(harness.engines.all.count == 2)
    }

    @Test func resetWhileIdleOnlyReplacesTheEngine() async {
        let harness = Harness()
        await harness.controller.handle(.mediaServicesReset)
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.state == .idle)
        #expect(harness.engines.all.count == 2)

        await harness.startRunning()
        #expect(harness.engines.all[0].starts == 0)
        #expect(harness.engine.starts == 1)
    }

    @Test func configurationChangesFromTheReplacedEngineAreIgnored() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.mediaServicesReset)
        await harness.controller.waitForPendingRebuild()

        await harness.controller.engineConfigurationChanged(engineID: 0)
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.starts == 1)
    }
}

@Suite("AudioSessionController: published updates", .timeLimit(.minutes(1)))
struct AudioSessionUpdatesTests {
    @Test func updatesStartWithTheCurrentSnapshotAndFollowTransitions() async {
        let harness = Harness()
        var iterator = await harness.controller.updates().makeAsyncIterator()
        #expect(await iterator.next() == AudioSessionSnapshot(state: .idle, route: .speaker))

        await harness.startRunning()
        #expect(await iterator.next()?.state == .starting)
        #expect(await iterator.next()?.state == .running)

        await harness.controller.stop()
        #expect(await iterator.next()?.state == .idle)
    }

    @Test func sessionEventsFlowFromTheBackendStream() async {
        // End to end: the event goes through the session's AsyncStream and
        // the controller's event loop, not a direct `handle` call.
        let harness = Harness()
        await harness.startRunning()

        harness.session.send(.interruptionBegan(.default))
        let interrupted = await harness.waitForSnapshot { $0.state == .interrupted }
        #expect(interrupted != nil)

        harness.session.send(.interruptionEnded(shouldResume: true))
        let resumed = await harness.waitForSnapshot { $0.state == .running }
        #expect(resumed != nil)

        harness.session.route = .airPods
        harness.session.send(.routeChanged(.newDeviceAvailable, route: .airPods))
        let rerouted = await harness.waitForSnapshot { $0.route == .airPods }
        #expect(rerouted?.state == .running)
    }

    @Test func everySubscriberGetsUpdates() async {
        let harness = Harness()
        var first = await harness.controller.updates().makeAsyncIterator()
        var second = await harness.controller.updates().makeAsyncIterator()
        _ = await first.next()
        _ = await second.next()

        await harness.controller.handle(.routeChanged(.newDeviceAvailable, route: .airPods))
        #expect(await first.next()?.route == .airPods)
        #expect(await second.next()?.route == .airPods)
    }
}

@Suite("AudioSessionState and AudioRoute")
struct AudioSessionValueTests {
    @Test func engagedStates() {
        #expect(AudioSessionState.starting.isEngaged)
        #expect(AudioSessionState.running.isEngaged)
        #expect(AudioSessionState.interrupted.isEngaged)
        #expect(!AudioSessionState.idle.isEngaged)
        #expect(!AudioSessionState.failed(.noSuitableRoute).isEngaged)
    }

    @Test func stateDescriptionsAreStable() {
        #expect(AudioSessionState.running.description == "running")
        #expect(
            AudioSessionState.failed(.microphonePermissionDenied).description == "failed(microphonePermissionDenied)")
    }

    @Test func routeHelpers() {
        #expect(AudioRoute.airPods.usesBluetooth)
        #expect(!AudioRoute.airPods.usesSpeaker)
        #expect(AudioRoute.speaker.usesSpeaker)
        #expect(!AudioRoute.speaker.usesBluetooth)
        #expect(AudioRoute.speaker.input?.kind == .builtInMic)
        #expect(AudioRoute.none.output == nil)
    }

    @Test func routeSummaryHasNoDeviceNames() {
        #expect(AudioRoute.airPods.summary == "bluetoothHFP -> bluetoothHFP")
        #expect(AudioRoute.none.summary == "none -> none")
        #expect(!AudioRoute.airPods.summary.contains("AirPods"))
    }

    @Test func portKindClassification() {
        let bluetooth = AudioPortKind.allCases.filter(\.isBluetooth)
        #expect(Set(bluetooth) == [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE])
        let builtIn = AudioPortKind.allCases.filter(\.isBuiltIn)
        #expect(Set(builtIn) == [.builtInMic, .builtInSpeaker, .builtInReceiver])
    }

    @Test func duckingLevelsMapToAVFoundation() {
        #expect(VoiceProcessingConfiguration.DuckingLevel.default.avLevel == .default)
        #expect(VoiceProcessingConfiguration.DuckingLevel.min.avLevel == .min)
        #expect(VoiceProcessingConfiguration.DuckingLevel.mid.avLevel == .mid)
        #expect(VoiceProcessingConfiguration.DuckingLevel.max.avLevel == .max)
    }
}
