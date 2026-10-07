import BlauCore
import BlauTelemetry

/// The audio of a conversation, assembled: one voice-processing engine
/// (`AudioSessionController`) carrying microphone capture (#24), reply
/// playback (#25) and the record button's "pause listening" mute (#41),
/// kept alive on and off screen by an `AudioSessionKeeper` (#26).
///
/// The composition root builds one at launch and uses `keeper` as the
/// app's `AudioService`. Nothing touches the microphone until
/// `keeper.startCapture()`.
///
/// ```swift
/// let audio = ConversationAudio.live(indicator: liveActivity)   // iOS
/// try await audio.keeper.startCapture()
/// for await frame in audio.capture.hub.frames() { ... }         // VAD, ASR, voice ID
/// try audio.player.enqueue(base64: delta, item: item)           // Grok's reply
/// audio.microphoneMute.setMuted(true)                           // pause listening
/// ```
public struct ConversationAudio: Sendable {
    public let controller: AudioSessionController
    public let capture: MicrophoneCapture
    public let player: StreamingAudioPlayer
    public let keeper: AudioSessionKeeper
    /// Mutes the microphone inside voice processing without stopping the
    /// conversation, and reports speech while muted.
    public let microphoneMute: MicrophoneMute

    /// Wires `capture`, `player` and `microphoneMute` into `controller` (on
    /// the first start) and puts a keeper in charge of it.
    public init(
        controller: AudioSessionController,
        capture: MicrophoneCapture = MicrophoneCapture(),
        player: StreamingAudioPlayer = StreamingAudioPlayer(),
        microphoneMute: MicrophoneMute = MicrophoneMute(),
        indicator: (any RecordingIndicator)? = nil,
        keeperConfiguration: AudioSessionKeeper.Configuration = .standard,
        clock: any BlauClock = SystemClock()
    ) {
        self.controller = controller
        self.capture = capture
        self.player = player
        self.microphoneMute = microphoneMute
        self.keeper = AudioSessionKeeper(
            controller: controller,
            progress: capture.hub,
            components: [capture, player, microphoneMute],
            indicator: indicator,
            configuration: keeperConfiguration,
            clock: clock
        )
    }
}

#if os(iOS)
    extension ConversationAudio {
        /// The production audio: the shared `AVAudioSession`, a
        /// voice-processing engine, capture and playback.
        public static func live(indicator: (any RecordingIndicator)? = nil) -> ConversationAudio {
            ConversationAudio(controller: .live(), indicator: indicator)
        }
    }
#endif
