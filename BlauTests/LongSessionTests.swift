import BlauAudio
import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Testing

@testable import Blau

/// The app side of long sessions (#26): the background mode, the Live
/// Activity and its Stop button, and phase changes reaching the background
/// inference monitor. See docs/background.md.
@Suite("Long sessions")
@MainActor
struct LongSessionAppTests {
    @Test func theAppDeclaresBackgroundAudioAndLiveActivities() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let modes = try #require(info["UIBackgroundModes"] as? [String])
        #expect(modes.contains("audio"), "the audio background mode keeps a locked session running")
        #expect(info["NSSupportsLiveActivities"] as? Bool == true)
    }

    @Test func theLiveActivityExtensionIsEmbedded() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let widgets = try #require(Bundle(url: plugIns.appending(path: "BlauWidgets.appex")))
        let point = (widgets.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
        #expect(point as? String == "com.apple.widgetkit-extension")
        #expect(widgets.bundleIdentifier == "com.joeblau.blau.widgets")
    }

    @Test(arguments: RecordingIndicatorState.Status.allCases)
    func theLiveActivityShowsTheIndicatorsStatus(status: RecordingIndicatorState.Status) {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let content = LiveActivityRecordingIndicator.contentState(
            for: RecordingIndicatorState(status: status, startedAt: startedAt))
        #expect(content.status.rawValue == status.rawValue)
        #expect(content.startedAt == startedAt)
        #expect(content.status.isListening == (status == .listening))
    }

    @Test func theStopButtonEndsTheConversation() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        try await environment.audio.startCapture()
        await environment.start()
        #expect(ConversationControl.stopHandler != nil)

        await environment.stopConversation()
        #expect(await !environment.audio.isCapturing)
    }

    @Test func scenePhasesReachTheBackgroundInferenceMonitor() async {
        let environment = AppEnvironment.preview()
        environment.handleScenePhase(.active)
        environment.handleScenePhase(.inactive)
        await environment.lifecycle.waitUntilDelivered()
        #expect(await environment.backgroundInference.snapshot.phase == .foreground)

        environment.handleScenePhase(.background)
        await environment.lifecycle.waitUntilDelivered()
        #expect(await environment.backgroundInference.snapshot.phase == .background)

        environment.handleScenePhase(.active)
        await environment.lifecycle.waitUntilDelivered()
        #expect(await environment.backgroundInference.snapshot.phase == .foreground)
    }

    @Test func theMonitorShipsWithTheProvisionalMitigation() async {
        let environment = AppEnvironment.preview()
        #expect(await environment.backgroundInference.snapshot.mitigation == .shipping)
    }
}

/// The live conversation audio on the real voice-processing engine: it
/// comes up, audio flows, the watchdog sees it, and it stops. Needs
/// microphone permission (on a simulator: `xcrun simctl privacy <udid>
/// grant microphone com.joeblau.blau`), so it only runs with
/// `BLAU_DEVICE_TESTS=1`. Locking the screen can't be automated; the
/// 30-minute locked run is the manual procedure in docs/background.md.
@Suite(
    "ConversationAudio live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_DEVICE_TESTS"] == "1"),
    .timeLimit(.minutes(1))
)
struct ConversationAudioLiveTests {
    @Test func theKeeperBringsUpTheLiveEngineAndAudioFlows() async throws {
        let audio = ConversationAudio.live()
        try await audio.keeper.startCapture()
        #expect(await audio.keeper.status == .live)

        let deadline = ContinuousClock.now + .seconds(5)
        while audio.capture.hub.nextSampleOffset < 32_000 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(audio.capture.hub.nextSampleOffset >= 32_000, "two seconds of audio")
        // Three watchdog checks with audio flowing: no stall.
        try await Task.sleep(for: .seconds(3))
        let statistics = await audio.keeper.snapshot.statistics
        #expect(statistics.stallsDetected == 0)
        #expect(await audio.keeper.status == .live)

        await audio.keeper.stopCapture()
        #expect(await audio.controller.state == .idle)
    }
}
