#if DEBUG || BLAU_BENCHMARKS
    import AVFAudio
    import BlauTelemetry
    import UIKit

    /// Reports whether Blau is on screen, off screen, or off screen with the
    /// device locked. "Locked" means protected data is unavailable, which
    /// needs a device passcode.
    struct ApplicationExecutionPhaseProvider: ExecutionPhaseProvider {
        func currentPhase() async -> ExecutionPhase {
            await MainActor.run {
                let application = UIApplication.shared
                if application.applicationState == .active {
                    return .foreground
                }
                return application.isProtectedDataAvailable ? .background : .locked
            }
        }
    }

    /// Keeps the app running off screen during the background probe the way
    /// a conversation does: an active audio session with the microphone
    /// running (the `audio` background mode). The captured audio is
    /// discarded. Production audio lives in BlauAudio (#23, #24); this is a
    /// debug tool only.
    @MainActor
    final class BackgroundAudioKeepAlive {
        enum KeepAliveError: Error, CustomStringConvertible {
            case microphoneDenied

            var description: String { "Microphone access is needed to keep the app running in the background" }
        }

        private let engine = AVAudioEngine()
        private var isRunning = false

        func start() async throws {
            guard await AVAudioApplication.requestRecordPermission() else { throw KeepAliveError.microphoneDenied }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            // The tap runs on the audio thread; it must not inherit main-actor
            // isolation.
            input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable _, _ in }
            try engine.start()
            isRunning = true
        }

        func stop() {
            guard isRunning else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isRunning = false
        }
    }
#endif
