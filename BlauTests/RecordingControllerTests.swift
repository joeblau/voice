import BlauCore
import Foundation
import Synchronization
import Testing

@testable import Blau

@Suite("RecordingController")
@MainActor
struct RecordingControllerTests {
    private struct MicDenied: LocalizedError {
        var errorDescription: String? { "Microphone access is off." }
    }

    @Test func startsIdle() {
        let controller = RecordingController(audio: FakeAudioService())
        #expect(controller.phase == .idle)
        #expect(controller.failure == nil)
    }

    @Test func togglingStartsThenStopsCapture() async {
        let audio = FakeAudioService()
        let controller = RecordingController(audio: audio)

        await controller.toggle()
        #expect(controller.phase == .recording)
        #expect(await audio.isCapturing)
        #expect(audio.startCount == 1)

        await controller.toggle()
        #expect(controller.phase == .idle)
        #expect(await !audio.isCapturing)
    }

    @Test func aFailedStartStaysIdleAndExplainsWhy() async throws {
        let controller = RecordingController(audio: FakeAudioService(startError: MicDenied()))

        await controller.toggle()

        #expect(controller.phase == .idle)
        let failure = try #require(controller.failure)
        #expect(failure.title == "Couldn't Start Recording")
        #expect(failure.message == "Microphone access is off.")
    }

    /// The live app's audio slot is an `UnavailableService` until the capture
    /// engine is wired in, so the button must say so rather than fail
    /// silently.
    @Test func aMissingAudioServiceIsExplained() async {
        let controller = RecordingController(audio: UnavailableService(subsystem: "audio"))

        await controller.toggle()

        #expect(controller.phase == .idle)
        #expect(controller.failure?.message == "Recording isn't available in this build of Blau yet.")
    }

    @Test func aSuccessfulStartClearsAnEarlierFailure() async {
        let failing = RecordingController(audio: UnavailableService(subsystem: "audio"))
        await failing.toggle()
        #expect(failing.failure != nil)

        let audio = SlowAudioService()
        let controller = RecordingController(audio: audio)
        controller.failure = failing.failure
        let start = Task { await controller.toggle() }
        await audio.waitUntilStartBegins()
        #expect(controller.failure == nil)
        audio.finishStart()
        await start.value
        #expect(controller.phase == .recording)
    }

    @Test func tapsDuringAStartAreIgnored() async {
        let audio = SlowAudioService()
        let controller = RecordingController(audio: audio)

        let first = Task { await controller.toggle() }
        await audio.waitUntilStartBegins()
        #expect(controller.phase == .starting)
        #expect(controller.phase.isBusy)

        // A second tap while starting neither starts again nor stops.
        await controller.toggle()
        #expect(controller.phase == .starting)

        audio.finishStart()
        await first.value
        #expect(controller.phase == .recording)
        #expect(audio.startCalls == 1)
        #expect(audio.stopCalls == 0)
    }

    @Test func synchronizePicksUpCaptureThatIsAlreadyRunning() async {
        let audio = FakeAudioService(isCapturing: true)
        let controller = RecordingController(audio: audio)

        await controller.synchronize()
        #expect(controller.phase == .recording)

        await audio.stopCapture()
        await controller.synchronize()
        #expect(controller.phase == .idle)
    }

    /// The Live Activity's Stop (`AppEnvironment.stopConversation()`) and an
    /// audio interruption stop capture without going through the controller.
    /// The next `synchronize()` (on returning to the foreground) must put the
    /// button back to idle, so one tap records again.
    @Test func synchronizeAfterCaptureStoppedElsewhereReturnsToIdle() async {
        let audio = FakeAudioService()
        let controller = RecordingController(audio: audio)

        await controller.toggle()
        #expect(controller.phase == .recording)

        await audio.stopCapture()
        #expect(controller.phase == .recording)

        await controller.synchronize()
        #expect(controller.phase == .idle)

        await controller.toggle()
        #expect(controller.phase == .recording)
        #expect(await audio.isCapturing)
        #expect(audio.startCount == 2)
    }

    @Test func synchronizeLeavesATransitionAlone() async {
        let audio = SlowAudioService()
        let controller = RecordingController(audio: audio)
        let start = Task { await controller.toggle() }
        await audio.waitUntilStartBegins()

        await controller.synchronize()
        #expect(controller.phase == .starting)

        audio.finishStart()
        await start.value
    }

    @Test func phasesReportWhetherTheyAreBusy() {
        #expect(!RecordingController.Phase.idle.isBusy)
        #expect(RecordingController.Phase.starting.isBusy)
        #expect(!RecordingController.Phase.recording.isBusy)
        #expect(RecordingController.Phase.stopping.isBusy)
    }
}

/// An `AudioService` whose `startCapture()` waits until the test calls
/// `finishStart()`, to observe the controller mid-transition.
private final class SlowAudioService: AudioService {
    private struct State {
        var isCapturing = false
        var startCalls = 0
        var stopCalls = 0
        var pendingStart: CheckedContinuation<Void, Never>?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var startCalls: Int { state.withLock { $0.startCalls } }
    var stopCalls: Int { state.withLock { $0.stopCalls } }
    var isCapturing: Bool { state.withLock { $0.isCapturing } }

    func startCapture() async throws {
        await withCheckedContinuation { continuation in
            let waiters = state.withLock { state in
                state.startCalls += 1
                state.pendingStart = continuation
                defer { state.startWaiters = [] }
                return state.startWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
        state.withLock { $0.isCapturing = true }
    }

    func stopCapture() async {
        state.withLock { state in
            state.stopCalls += 1
            state.isCapturing = false
        }
    }

    /// Returns once a `startCapture()` call is waiting.
    func waitUntilStartBegins() async {
        await withCheckedContinuation { continuation in
            let isWaiting = state.withLock { state in
                if state.pendingStart != nil { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if isWaiting { continuation.resume() }
        }
    }

    /// Lets the waiting `startCapture()` succeed.
    func finishStart() {
        let pending = state.withLock { state in
            defer { state.pendingStart = nil }
            return state.pendingStart
        }
        pending?.resume()
    }
}
