import BlauCore
import BlauTelemetry
import Foundation
import Observation
import os

/// What the record button (bottom-right on the main screen) starts and stops.
///
/// Today it drives microphone capture through the `AudioService` in the
/// composition root: the `AudioSessionKeeper` in the live app and the fakes in
/// previews and UI tests. If the slot is an `UnavailableService` (a build
/// without audio) the button reports a clear error instead of failing
/// silently. Capture can also stop without the button (the Live Activity's
/// Stop, an audio interruption), so the main screen calls `synchronize()` on
/// every return to the foreground. The record button issue (#41) grows it into
/// the full session control (connecting, listening, agent speaking, paused)
/// once the turn orchestrator (#36) exists.
///
/// Taps that arrive while a start or stop is in flight are ignored, so a
/// double tap can't start capture twice.
@MainActor
@Observable
final class RecordingController {
    /// Where the control is.
    enum Phase: String, Sendable {
        /// Not recording. Tapping starts.
        case idle
        /// Waiting for capture to start.
        case starting
        /// Capturing. Tapping stops.
        case recording
        /// Waiting for capture to stop.
        case stopping

        /// Whether a start or stop is in flight.
        var isBusy: Bool { self == .starting || self == .stopping }
    }

    /// Why recording couldn't start, for the alert on the main screen.
    struct Failure: Identifiable, Equatable, Sendable {
        let id = UUID()
        let title: String
        let message: String

        init(_ error: any Error) {
            title = String(localized: "Couldn't Start Recording")
            if error is ServiceUnavailableError {
                message = String(localized: "Recording isn't available in this build of Blau yet.")
            } else {
                message = error.localizedDescription
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// The latest start failure, until the user dismisses it.
    var failure: Failure?

    private let audio: any AudioService

    init(audio: any AudioService) {
        self.audio = audio
    }

    /// Starts recording when idle and stops it when recording. Does nothing
    /// while a start or stop is in flight.
    func toggle() async {
        switch phase {
        case .idle: await start()
        case .recording: await stop()
        case .starting, .stopping: return
        }
    }

    /// Matches `phase` to whether the audio service is capturing: when the
    /// view is rebuilt (for example after an iCloud account change replaces
    /// the store) while capture keeps running, and when Blau returns to the
    /// foreground after capture stopped elsewhere (the Live Activity's Stop,
    /// an interruption). Does nothing mid-transition.
    func synchronize() async {
        guard !phase.isBusy else { return }
        let isCapturing = await audio.isCapturing
        // A tap may have started a transition while we were waiting.
        guard !phase.isBusy else { return }
        phase = isCapturing ? .recording : .idle
    }

    private func start() async {
        phase = .starting
        failure = nil
        do {
            try await audio.startCapture()
            phase = .recording
            Log.ui.notice("Recording started from the record button")
        } catch {
            phase = .idle
            failure = Failure(error)
            Log.ui.error("Couldn't start recording: \(String(describing: error), privacy: .public)")
        }
    }

    private func stop() async {
        phase = .stopping
        await audio.stopCapture()
        phase = .idle
        Log.ui.notice("Recording stopped from the record button")
    }
}
