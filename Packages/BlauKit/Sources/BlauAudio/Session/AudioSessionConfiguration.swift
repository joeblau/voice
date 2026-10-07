/// How `AudioSessionController` sets up `AVAudioSession` and voice
/// processing. The category is always `.playAndRecord` with mode
/// `.voiceChat`: Blau captures and plays at the same time for the whole
/// conversation.
public struct AudioSessionConfiguration: Sendable, Hashable {
    /// Hardware sample rate to ask for. The system may pick another one
    /// (Bluetooth HFP runs at 16 or 24 kHz); the capture and playback
    /// components read the real format from the engine's nodes.
    public var preferredSampleRate: Double

    /// I/O buffer duration to ask for. 10–20 ms keeps latency low without
    /// waking the CPU too often over an hour-long session.
    public var preferredIOBufferDuration: Duration

    /// `.defaultToSpeaker`: with no headset, play through the loudspeaker
    /// rather than the receiver at the top of the phone.
    public var routesToSpeakerByDefault: Bool

    /// `.allowBluetoothHFP` (named `.allowBluetooth` before the iOS 26 SDK):
    /// let AirPods and other headsets be both microphone and speaker.
    /// `.voiceChat` turns this on anyway; it is set explicitly so the intent
    /// is visible.
    public var allowsBluetoothHFP: Bool

    public var voiceProcessing: VoiceProcessingConfiguration

    public init(
        preferredSampleRate: Double = 48_000,
        preferredIOBufferDuration: Duration = .milliseconds(20),
        routesToSpeakerByDefault: Bool = true,
        allowsBluetoothHFP: Bool = true,
        voiceProcessing: VoiceProcessingConfiguration = VoiceProcessingConfiguration()
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.preferredIOBufferDuration = preferredIOBufferDuration
        self.routesToSpeakerByDefault = routesToSpeakerByDefault
        self.allowsBluetoothHFP = allowsBluetoothHFP
        self.voiceProcessing = voiceProcessing
    }

    /// Blau's full-duplex voice conversation setup: 48 kHz, 20 ms buffers,
    /// loudspeaker by default, Bluetooth headsets allowed, voice processing
    /// on.
    public static let voiceChat = AudioSessionConfiguration()
}

/// Voice-processing I/O (VPIO) settings: echo cancellation, noise
/// suppression and automatic gain control on the engine's input node.
public struct VoiceProcessingConfiguration: Sendable, Hashable {
    /// How much VPIO lowers other apps' audio (music, podcasts) while Blau
    /// runs. Mirrors `AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level`.
    public enum DuckingLevel: Sendable, Hashable, CaseIterable {
        case `default`
        case min
        case mid
        case max
    }

    /// Enable voice processing (`setVoiceProcessingEnabled(true)`) before
    /// the engine starts. Without it, playback through the speaker leaks
    /// into the microphone and the agent hears itself.
    public var isEnabled: Bool

    /// VPIO's automatic gain control on the input.
    public var automaticGainControl: Bool

    /// Advanced ducking lowers other audio only while someone is talking,
    /// instead of for the whole session.
    public var advancedDucking: Bool

    public var duckingLevel: DuckingLevel

    public init(
        isEnabled: Bool = true,
        automaticGainControl: Bool = true,
        advancedDucking: Bool = true,
        duckingLevel: DuckingLevel = .min
    ) {
        self.isEnabled = isEnabled
        self.automaticGainControl = automaticGainControl
        self.advancedDucking = advancedDucking
        self.duckingLevel = duckingLevel
    }
}
