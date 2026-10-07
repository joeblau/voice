import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauAudio

// MARK: - Fakes

/// Capture progress the test moves by hand: 16 000 samples is one second of
/// audio arriving.
final class FakeCaptureProgress: CaptureProgressSource {
    private let count = Mutex<Int64>(0)

    var capturedSampleCount: Int64 { count.withLock { $0 } }

    func advance(by samples: Int64 = 16_000) {
        count.withLock { $0 += samples }
    }
}

/// Records what the lock-screen indicator was asked to show.
actor FakeRecordingIndicator: RecordingIndicator {
    private(set) var shown: [RecordingIndicatorState] = []
    private(set) var hides = 0
    private(set) var current: RecordingIndicatorState?

    var statuses: [RecordingIndicatorState.Status] { shown.map(\.status) }

    func show(_ state: RecordingIndicatorState) {
        shown.append(state)
        current = state
    }

    func hide() {
        hides += 1
        current = nil
    }
}

/// A keeper on the controller fakes, with a watchdog the test drives.
struct KeeperHarness {
    let audio: Harness
    let progress = FakeCaptureProgress()
    let indicator = FakeRecordingIndicator()
    let component = RecordingComponent()
    let keeper: AudioSessionKeeper

    var controller: AudioSessionController { audio.controller }
    var clock: ManualClock { audio.clock }
    var session: FakeAudioSession { audio.session }
    var engine: FakeAudioEngine { audio.engine }

    /// - Parameter watchdogInterval: Long by default, so the timer never
    ///   fires and the test calls `checkCapture()` itself.
    init(
        permission: FakeMicrophonePermission = FakeMicrophonePermission(),
        watchdogInterval: Duration = .seconds(1_000_000),
        maximumStallRecoveries: Int = 2
    ) {
        audio = Harness(permission: permission)
        keeper = AudioSessionKeeper(
            controller: audio.controller,
            progress: progress,
            components: [component],
            indicator: indicator,
            configuration: .init(
                watchdogInterval: watchdogInterval, stallTimeout: .seconds(3),
                maximumStallRecoveries: maximumStallRecoveries),
            clock: audio.clock,
            signposter: Signposter(category: .audio, backend: audio.signposts)
        )
    }

    /// Starts the conversation and checks it is live.
    func start() async throws {
        try await keeper.startCapture()
        let status = await keeper.status
        precondition(status == .live, "Expected live, got \(status)")
    }

    /// Moves the app through `phases` as the scene would.
    func move(_ phases: AppPhase...) async {
        var from = await keeper.phase == .foreground ? AppPhase.active : .background
        for phase in phases {
            await keeper.appPhaseDidChange(AppPhaseTransition(from: from, to: phase))
            from = phase
        }
    }

    /// Lets `seconds` pass in one-second watchdog ticks, with audio flowing
    /// or not.
    func tick(_ seconds: Int, audioFlowing: Bool) async {
        for _ in 0..<seconds {
            if audioFlowing { progress.advance() }
            clock.advance(by: .seconds(1))
            await keeper.checkCapture()
            // A stall rebuild runs at once (its first attempt has no delay).
            await controller.waitForPendingRebuild()
        }
    }

    /// Makes the engine stop as on a route change and fail every rebuild
    /// attempt, stepping the clock through the retry delays until the
    /// controller gives up.
    func failNextRebuild() async {
        engine.failStarts(3)
        engine.simulateConfigurationChange()
        while true {
            if case .failed = await controller.state { return }
            // The watchdog always sleeps; a second sleeper is a retry delay.
            if clock.sleeperCount >= 2 { clock.advance(by: .milliseconds(250)) }
            await Task.yield()
        }
    }

    func waitForStatus(_ status: AudioSessionKeeper.Status) async {
        for await snapshot in await keeper.updates() where snapshot.status == status {
            return
        }
    }

    /// The indicator after every queued update ran.
    func indicatorState() async -> RecordingIndicatorState? {
        await keeper.waitForIndicator()
        return await indicator.current
    }
}

// MARK: - Tests

@Suite("AudioSessionKeeper", .timeLimit(.minutes(1)))
struct AudioSessionKeeperTests {
    @Test func startingRegistersTheGraphAndShowsTheIndicator() async throws {
        let harness = KeeperHarness()
        #expect(await harness.keeper.status == .inactive)
        try await harness.start()

        #expect(await harness.keeper.isCapturing)
        #expect(harness.engine.installedComponents == [ObjectIdentifier(harness.component)])
        let indicator = await harness.indicatorState()
        #expect(indicator?.status == .listening)
        #expect(indicator?.startedAt == harness.clock.now)
        #expect(await harness.indicator.hides == 0)
    }

    /// The acceptance criterion's 30-minute locked session, on fakes: the
    /// audio keeps running from start to end without a single restart.
    @Test func aThirtyMinuteLockedSessionRunsThrough() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        let activations = harness.session.activations
        let starts = harness.engine.starts

        await harness.move(.inactive, .background)
        await harness.keeper.setDeviceLocked(true)
        for _ in 0..<30 {
            await harness.tick(60, audioFlowing: true)
            #expect(await harness.keeper.status == .live)
        }
        await harness.keeper.setDeviceLocked(false)
        await harness.move(.inactive, .active)

        #expect(await harness.keeper.status == .live)
        #expect(harness.session.activations == activations, "the session was never re-activated")
        #expect(harness.session.deactivations == 0)
        #expect(harness.engine.starts == starts, "the engine was never restarted")
        let statistics = await harness.keeper.snapshot.statistics
        #expect(statistics.backgroundEntries == 1)
        #expect(statistics.lockedSeconds == 1_800)
        #expect(statistics.stallsDetected == 0)
        #expect(statistics.longestSilentCaptureSeconds == 0)
        #expect(statistics.notLiveSeconds == 0)
        #expect(statistics.foregroundResumes == 0)
        #expect(await harness.indicatorState()?.status == .listening)
    }

    @Test func aSilentStallRebuildsTheGraphWithoutDeactivating() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)

        await harness.tick(2, audioFlowing: false)
        #expect(await harness.keeper.status == .live, "two seconds of silence from the engine is not a stall yet")
        await harness.tick(1, audioFlowing: false)
        await harness.controller.waitForPendingRebuild()

        #expect(await harness.keeper.status == .recovering)
        #expect(await harness.indicatorState()?.status == .reconnecting)
        #expect(harness.audio.signposts.events.contains("audio.captureStall"))
        #expect(harness.engine.starts == 2)
        #expect(harness.session.deactivations == 0, "a rebuild keeps the session, which works off screen")

        await harness.tick(1, audioFlowing: true)
        #expect(await harness.keeper.status == .live)
        #expect(await harness.indicatorState()?.status == .listening)
        let statistics = await harness.keeper.snapshot.statistics
        #expect(statistics.stallsDetected == 1)
        #expect(statistics.stallsRecovered == 1)
        #expect(statistics.longestSilentCaptureSeconds == 3)
    }

    @Test func aStallThatWontClearOffScreenWaitsForTheForeground() async throws {
        let harness = KeeperHarness(maximumStallRecoveries: 2)
        try await harness.start()
        await harness.move(.inactive, .background)

        await harness.tick(3, audioFlowing: false)  // stall, rebuild 1
        await harness.tick(3, audioFlowing: false)  // rebuild 2
        await harness.tick(3, audioFlowing: false)  // give up
        await harness.controller.waitForPendingRebuild()
        #expect(harness.engine.starts == 3)
        #expect(await harness.keeper.status == .paused)
        #expect(await harness.indicatorState()?.status == .needsAttention)
        #expect(harness.session.deactivations == 0, "the session stays active, so Blau isn't suspended")

        // Still paused however long it waits off screen.
        await harness.tick(30, audioFlowing: false)
        #expect(await harness.keeper.status == .paused)

        await harness.move(.inactive, .active)
        #expect(await harness.keeper.status == .live)
        #expect(harness.session.deactivations == 1, "restarted from scratch on screen")
        #expect(await harness.keeper.snapshot.statistics.foregroundResumes == 1)
        #expect(await harness.indicatorState()?.status == .listening)
    }

    @Test func aStallThatWontClearOnScreenRestarts() async throws {
        let harness = KeeperHarness(maximumStallRecoveries: 1)
        try await harness.start()
        await harness.tick(3, audioFlowing: false)  // stall, rebuild 1
        await harness.tick(3, audioFlowing: false)  // restart
        #expect(await harness.keeper.status == .live)
        #expect(harness.session.deactivations == 1)
        #expect(harness.session.activations == 3)
    }

    @Test func anInterruptionOffScreenResumesByItself() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)

        harness.session.send(.interruptionBegan(.default))
        await harness.waitForStatus(.interrupted)
        #expect(await harness.indicatorState()?.status == .interrupted)
        // No audio while the call holds the mic is not a stall.
        await harness.tick(10, audioFlowing: false)
        #expect(await harness.keeper.snapshot.statistics.stallsDetected == 0)

        harness.session.send(.interruptionEnded(shouldResume: true))
        await harness.waitForStatus(.live)
        #expect(await harness.indicatorState()?.status == .listening)
        let statistics = await harness.keeper.snapshot.statistics
        #expect(statistics.interruptions == 1)
        #expect(statistics.foregroundResumes == 0)
    }

    @Test func anInterruptionEndingWithoutResumeOffScreenWaitsForTheUser() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.waitForStatus(.interrupted)
        // Ending without `.shouldResume` publishes no new state; the
        // watchdog notices.
        await harness.controller.handle(.interruptionEnded(shouldResume: false))
        #expect(await harness.controller.isAwaitingManualResume)

        await harness.tick(1, audioFlowing: false)
        #expect(await harness.keeper.status == .paused)
        #expect(await harness.indicatorState()?.status == .needsAttention)

        await harness.move(.inactive, .active)
        #expect(await harness.keeper.status == .live)
        #expect(await harness.keeper.snapshot.statistics.foregroundResumes == 1)
    }

    @Test func aCallStillInProgressIsNotFoughtOnReturn() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.waitForStatus(.interrupted)
        let activations = harness.session.activations

        await harness.move(.inactive, .active)
        #expect(await harness.keeper.status == .interrupted)
        #expect(harness.session.activations == activations, "no attempt to take the mic back from the call")
    }

    /// Another app's non-mixable audio took the session and no
    /// interruption-ended ever arrives (B7). Returning to the foreground
    /// leaves it alone; tapping record takes the session back.
    @Test func startCaptureWhileInterruptedRestarts() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.waitForStatus(.interrupted)
        await harness.move(.inactive, .active)
        #expect(await harness.keeper.status == .interrupted)
        let activations = harness.session.activations

        try await harness.keeper.startCapture()
        #expect(await harness.keeper.status == .live)
        #expect(await harness.controller.state == .running)
        #expect(harness.session.activations == activations + 1)
        #expect(await harness.indicatorState()?.status == .listening)
        // A user restart is not an automatic foreground resume.
        #expect(await harness.keeper.snapshot.statistics.foregroundResumes == 0)

        // Audio flows again and the watchdog is still running.
        await harness.tick(5, audioFlowing: true)
        #expect(await harness.keeper.status == .live)
    }

    /// Tapping record while a call really still holds the microphone fails
    /// visibly instead of silently doing nothing, and can be retried.
    @Test func startCaptureWhileACallHoldsTheMicFails() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.controller.handle(.interruptionBegan(.default))
        await harness.waitForStatus(.interrupted)

        harness.session.failActivations(1)
        await #expect(throws: AudioSessionError.self) {
            try await harness.keeper.startCapture()
        }
        guard case .failed(.activationFailed) = await harness.keeper.status else {
            Issue.record("Expected failed(activationFailed), got \(await harness.keeper.status)")
            return
        }
        #expect(await harness.indicatorState()?.status == .needsAttention)

        // The call ended; tapping record again works.
        try await harness.keeper.startCapture()
        #expect(await harness.keeper.status == .live)
    }

    @Test func aFailedRebuildOffScreenWaitsForTheForeground() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.move(.inactive, .background)

        // AirPods connect off screen and the engine won't start again.
        await harness.failNextRebuild()
        await harness.waitForStatus(.paused)
        #expect(await harness.indicatorState()?.status == .needsAttention)

        await harness.move(.inactive, .active)
        #expect(await harness.keeper.status == .live)
    }

    @Test func aFailedRebuildOnScreenIsReported() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.failNextRebuild()
        for await snapshot in await harness.keeper.updates() {
            if case .failed(.engineStartFailed(let error)) = snapshot.status {
                #expect(error.code == -10_875)
                break
            }
        }
        #expect(await harness.indicatorState()?.status == .needsAttention)

        // Tapping record again restarts it.
        try await harness.keeper.startCapture()
        #expect(await harness.keeper.status == .live)
    }

    @Test func aStartThatFailsThrowsAndEndsTheConversation() async {
        let harness = KeeperHarness(permission: FakeMicrophonePermission(.denied))
        await #expect(throws: AudioSessionError.microphonePermissionDenied) {
            try await harness.keeper.startCapture()
        }
        #expect(await harness.keeper.status == .inactive)
        #expect(await harness.indicatorState() == nil)
        #expect(await !harness.keeper.isCapturing)
    }

    @Test func stoppingReleasesTheSessionAndHidesTheIndicator() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        #expect(await harness.indicatorState()?.status == .listening)
        await harness.tick(5, audioFlowing: true)
        await harness.keeper.stopCapture()

        #expect(await harness.keeper.status == .inactive)
        #expect(await harness.controller.state == .idle)
        #expect(harness.session.deactivations == 1)
        #expect(await harness.indicatorState() == nil)
        #expect(await harness.indicator.hides == 1)
        #expect(await harness.keeper.snapshot.statistics.foregroundSeconds == 5)

        // A second conversation starts from fresh counters.
        try await harness.start()
        #expect(await harness.keeper.snapshot.statistics.foregroundSeconds == 0)
        #expect(await harness.indicatorState()?.status == .listening)
    }

    @Test func startingAgainWhileLiveDoesNothing() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        try await harness.keeper.startCapture()
        #expect(harness.session.activations == 1)
    }

    @Test func phasesWithoutAConversationAreOnlyTracked() async {
        let harness = KeeperHarness()
        await harness.move(.inactive, .background)
        #expect(await harness.keeper.phase == .background)
        await harness.keeper.setDeviceLocked(true)
        #expect(await harness.keeper.phase == .locked)
        #expect(await harness.keeper.status == .inactive)
        #expect(harness.session.activations == 0)
    }

    @Test func theWatchdogRunsOnTheClock() async throws {
        let harness = KeeperHarness(watchdogInterval: .seconds(1))
        try await harness.start()
        for _ in 0..<3 {
            await harness.clock.waitForSleepers()
            harness.clock.advance(by: .seconds(1))
        }
        await harness.waitForStatus(.recovering)
        #expect(await harness.keeper.snapshot.statistics.stallsDetected == 1)
    }

    @Test func timeIsSplitByPhase() async throws {
        let harness = KeeperHarness()
        try await harness.start()
        await harness.tick(10, audioFlowing: true)
        await harness.move(.inactive, .background)
        await harness.tick(20, audioFlowing: true)
        await harness.keeper.setDeviceLocked(true)
        await harness.tick(30, audioFlowing: true)
        let statistics = await harness.keeper.snapshot.statistics
        #expect(statistics.foregroundSeconds == 10)
        #expect(statistics.backgroundSeconds == 20)
        #expect(statistics.lockedSeconds == 30)
        #expect(statistics.totalSeconds == 60)
    }

    @Test(
        "The indicator follows the status",
        arguments: [
            (AudioSessionKeeper.Status.inactive, RecordingIndicatorState.Status?.none),
            (.starting, .reconnecting),
            (.live, .listening),
            (.recovering, .reconnecting),
            (.interrupted, .interrupted),
            (.paused, .needsAttention),
            (.failed(.noSuitableRoute), .needsAttention),
        ])
    func indicatorMapping(status: AudioSessionKeeper.Status, expected: RecordingIndicatorState.Status?) {
        #expect(status.indicatorStatus == expected)
    }
}

@Suite("AudioSessionController: keeper support", .timeLimit(.minutes(1)))
struct AudioSessionControllerKeeperSupportTests {
    @Test func recoveringFromAStallRebuildsOnlyWhileRunning() async {
        let harness = Harness()
        #expect(await !harness.controller.recoverFromStall())
        await harness.startRunning()
        #expect(await harness.controller.recoverFromStall())
        await harness.controller.waitForPendingRebuild()
        #expect(await harness.controller.state == .running)
        #expect(harness.engine.starts == 2)
        #expect(harness.session.deactivations == 0)
        #expect(harness.signposts.events.contains("audio.captureStall"))
    }

    @Test func awaitingManualResumeOnlyAfterAnInterruptionEndsWithoutResume() async {
        let harness = Harness()
        await harness.startRunning()
        await harness.controller.handle(.interruptionBegan(.default))
        #expect(await !harness.controller.isAwaitingManualResume)
        await harness.controller.handle(.interruptionEnded(shouldResume: false))
        #expect(await harness.controller.isAwaitingManualResume)
        // Another interruption (a second call) starts over.
        await harness.controller.handle(.interruptionBegan(.default))
        #expect(await !harness.controller.isAwaitingManualResume)
        await harness.controller.handle(.interruptionEnded(shouldResume: false))
        #expect(await harness.controller.start() == .running)
        #expect(await !harness.controller.isAwaitingManualResume)
    }
}

@Suite("ConversationAudio", .timeLimit(.minutes(1)))
struct ConversationAudioTests {
    @Test func theKeeperBringsUpCaptureAndPlaybackTogether() async throws {
        let engines = FakeEngineFactory()
        let controller = AudioSessionController(
            session: FakeAudioSession(), permission: FakeMicrophonePermission(), clock: ManualClock(),
            signposter: .disabled(.audio), makeEngine: { engines.make() })
        let audio = ConversationAudio(controller: controller, clock: ManualClock())
        #expect(engines.current.calls.isEmpty, "nothing touches the engine before the first start")

        try await audio.keeper.startCapture()
        #expect(
            engines.current.installedComponents == [ObjectIdentifier(audio.capture), ObjectIdentifier(audio.player)])
        #expect(await audio.keeper.isCapturing)
        await audio.keeper.stopCapture()
    }
}
