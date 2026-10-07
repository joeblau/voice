import AVFAudio
import BlauAudio
import Foundation
import Testing

/// Checks the real `AVAudioSession` adapter on iOS: the session setup it
/// applies and how it translates system notifications. Simulated
/// notifications go to a private `NotificationCenter`, so nothing else in
/// the test host sees them.
///
/// The state machine on top of it is covered by `AudioSessionControllerTests`
/// in BlauKit; these tests cover the iOS-only translation layer.
@Suite("SystemAudioSession", .serialized, .timeLimit(.minutes(1)))
struct SystemAudioSessionTests {
    private let center = NotificationCenter()
    private var avSession: AVAudioSession { AVAudioSession.sharedInstance() }

    @Test func configureAppliesTheVoiceChatSetup() throws {
        let session = SystemAudioSession(center: center)
        try session.configure(.voiceChat)

        #expect(avSession.category == .playAndRecord)
        #expect(avSession.mode == .voiceChat)
        #expect(avSession.categoryOptions.contains(.defaultToSpeaker))
        #expect(avSession.categoryOptions.contains(.allowBluetoothHFP))
        #expect(session.isConfigured(for: .voiceChat))
    }

    @Test func detectsACategoryChangedBehindItsBack() throws {
        let session = SystemAudioSession(center: center)
        try session.configure(.voiceChat)
        try avSession.setCategory(.playback, mode: .default)
        #expect(!session.isConfigured(for: .voiceChat))
        try session.configure(.voiceChat)
        #expect(session.isConfigured(for: .voiceChat))
    }

    @Test func translatesInterruptionBegan() async {
        let event = await nextEvent {
            post(
                AVAudioSession.interruptionNotification,
                [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                    AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue,
                ]
            )
        }
        #expect(event == .interruptionBegan(.builtInMicMuted))
    }

    @Test func treatsAMissingReasonAsAnotherSessionTakingOver() async {
        let event = await nextEvent {
            post(
                AVAudioSession.interruptionNotification,
                [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
        }
        #expect(event == .interruptionBegan(.default))
    }

    @Test(arguments: [true, false])
    func translatesInterruptionEnded(shouldResume: Bool) async {
        let options: AVAudioSession.InterruptionOptions = shouldResume ? .shouldResume : []
        let event = await nextEvent {
            post(
                AVAudioSession.interruptionNotification,
                [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: options.rawValue,
                ]
            )
        }
        #expect(event == .interruptionEnded(shouldResume: shouldResume))
    }

    @Test func ignoresMalformedInterruptions() async {
        let event = await nextEvent {
            post(AVAudioSession.interruptionNotification, [:])
            // A well-formed event afterwards proves the first was dropped.
            post(AVAudioSession.mediaServicesWereLostNotification, [:])
        }
        #expect(event == .mediaServicesLost)
    }

    @Test(
        arguments: [
            (AVAudioSession.RouteChangeReason.newDeviceAvailable, AudioRouteChangeReason.newDeviceAvailable),
            (.oldDeviceUnavailable, .oldDeviceUnavailable),
            (.categoryChange, .categoryChange),
            (.override, .override),
            (.wakeFromSleep, .wakeFromSleep),
            (.noSuitableRouteForCategory, .noSuitableRouteForCategory),
            (.routeConfigurationChange, .routeConfigurationChange),
            (.unknown, .unknown),
        ]
    )
    func translatesRouteChanges(reason: AVAudioSession.RouteChangeReason, expected: AudioRouteChangeReason) async {
        let session = SystemAudioSession(center: center)
        let event = await nextEvent(from: session) {
            post(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
        }
        #expect(event == .routeChanged(expected, route: session.currentRoute))
    }

    @Test func translatesMediaServicesReset() async {
        let event = await nextEvent {
            post(AVAudioSession.mediaServicesWereResetNotification, [:])
        }
        #expect(event == .mediaServicesReset)
    }

    @Test func ignoresNotificationsFromOtherObjects() async {
        let event = await nextEvent {
            center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: NSObject())
            post(AVAudioSession.mediaServicesWereLostNotification, [:])
        }
        #expect(event == .mediaServicesLost)
    }

    @Test func resumptionWithoutAContextDoesNotResume() async throws {
        guard #available(iOS 27, *) else { return }
        let event = await nextEvent {
            post(AVAudioSession.resumptionRecommendationNotification, [:])
        }
        #expect(event == .interruptionEnded(shouldResume: false))
    }

    @Test func deactivationWithoutAContextIsIgnored() async throws {
        guard #available(iOS 27, *) else { return }
        let event = await nextEvent {
            post(AVAudioSession.didBecomeInactiveNotification, [:])
            post(AVAudioSession.mediaServicesWereLostNotification, [:])
        }
        #expect(event == .mediaServicesLost)
    }

    // MARK: Helpers

    private func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]) {
        center.post(name: name, object: avSession, userInfo: userInfo)
    }

    private func nextEvent(_ trigger: () -> Void) async -> AudioSessionEvent? {
        await nextEvent(from: SystemAudioSession(center: center), trigger)
    }

    /// Runs `trigger` and returns the first event the session yields.
    /// Observers are installed in `init`, so posting synchronously right
    /// after creating the session is safe.
    private func nextEvent(from session: SystemAudioSession, _ trigger: () -> Void) async -> AudioSessionEvent? {
        trigger()
        var iterator = session.events.makeAsyncIterator()
        return await iterator.next()
    }
}

/// Brings the real session and voice-processing engine up and down. Needs
/// microphone permission (granted ahead of time on a simulator with
/// `xcrun simctl privacy <udid> grant microphone com.joeblau.blau`, or on a
/// device), so it only runs with `BLAU_DEVICE_TESTS=1`.
@Suite(
    "AudioSessionController live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .timeLimit(.minutes(1))
)
struct AudioSessionControllerLiveTests {
    @Test func startsVoiceProcessingAndStops() async {
        let controller = AudioSessionController.live()
        let state = await controller.start()
        #expect(state == .running)
        #expect(AVAudioSession.sharedInstance().category == .playAndRecord)
        #expect(AVAudioSession.sharedInstance().mode == .voiceChat)
        #expect(await controller.route.outputs.isEmpty == false)

        await controller.stop()
        #expect(await controller.state == .idle)
    }

    @Test func enablesVoiceProcessingBeforeTheEngineStarts() throws {
        let engine = VoiceProcessingAudioEngine()
        try SystemAudioSession().configure(.voiceChat)
        try AVAudioSession.sharedInstance().setActive(true)
        defer { try? AVAudioSession.sharedInstance().setActive(false) }

        try engine.prepare(voiceProcessing: VoiceProcessingConfiguration(), components: [])
        #expect(engine.engine.inputNode.isVoiceProcessingEnabled)
        #expect(engine.engine.outputNode.isVoiceProcessingEnabled)
        #expect(!engine.isRunning)
        engine.teardown()
    }
}
