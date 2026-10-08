import AVFoundation
import BlauCore
import BlauRealtime
import BlauTelemetry
import Foundation
import Observation
import os

/// Plays the voice samples Settings → Voice offers (`RealtimeVoicePreviewer`
/// fetches them from xAI's text to speech).
///
/// A preview never plays over a conversation: while the microphone is
/// capturing, the conversation owns the audio session, so the player says
/// so instead. Otherwise it plays through the `.playback` category (so the
/// silent switch doesn't mute it) and hands the session back when done.
@MainActor
@Observable
final class VoicePreviewPlayer {
    enum State: Equatable {
        case idle
        /// Fetching `voice`'s sample.
        case loading(RealtimeVoice)
        /// Playing `voice`'s sample.
        case playing(RealtimeVoice)
        /// The last preview failed; `message` says why.
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let previewer: RealtimeVoicePreviewer
    @ObservationIgnored private let audio: any AudioService
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playback: Task<Void, Never>?

    init(previewer: RealtimeVoicePreviewer, audio: any AudioService) {
        self.previewer = previewer
        self.audio = audio
    }

    /// Whether `voice`'s sample is loading or playing.
    func isActive(_ voice: RealtimeVoice) -> Bool {
        state == .loading(voice) || state == .playing(voice)
    }

    /// Plays `voice` at `speed`; stops whatever was playing first.
    func play(_ voice: RealtimeVoice, speed: Double) {
        stop()
        state = .loading(voice)
        playback = Task { [weak self] in
            await self?.run(voice, speed: speed)
        }
    }

    /// Stops the sample, releases the audio session and clears an earlier
    /// failure (it was about the voice the user has moved on from).
    func stop() {
        playback?.cancel()
        playback = nil
        finishPlayback()
        state = .idle
    }

    private func run(_ voice: RealtimeVoice, speed: Double) async {
        let isCapturing = await audio.isCapturing
        // A newer preview (or `stop()`) took over while this one waited.
        guard !Task.isCancelled else { return }
        if isCapturing {
            state = .failed(String(localized: "Stop the conversation to hear a voice preview."))
            return
        }
        let data: Data
        do {
            data = try await previewer.sample(voice: voice, speed: speed)
        } catch {
            guard !Task.isCancelled else { return }
            Log.ui.notice("Voice preview failed: \(String(describing: error), privacy: .public)")
            let problem = XAIAccountProblem(error)
            state = .failed(
                error == .missingAPIKey
                    ? String(localized: "Connect your xAI account to hear voices.") : problem.message)
            return
        }
        guard !Task.isCancelled else { return }
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            #endif
            let player = try AVAudioPlayer(data: data)
            self.player = player
            guard player.play() else { throw CocoaError(.featureUnsupported) }
            state = .playing(voice)
            try? await Task.sleep(for: .seconds(player.duration + 0.2))
        } catch {
            Log.ui.error("Couldn't play the voice preview: \(String(describing: error), privacy: .public)")
            state = .failed(String(localized: "Couldn't play the preview."))
            finishPlayback()
            return
        }
        guard !Task.isCancelled else { return }
        finishPlayback()
        state = .idle
    }

    private func finishPlayback() {
        guard let player else { return }
        player.stop()
        self.player = nil
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
