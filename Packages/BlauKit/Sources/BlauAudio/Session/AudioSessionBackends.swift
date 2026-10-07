import AVFAudio

// The seams `AudioSessionController` drives. Production uses
// `SystemAudioSession` (iOS), `VoiceProcessingAudioEngine` and
// `SystemMicrophonePermission`; tests use fakes, so the state machine is
// tested on the macOS host without audio hardware.

// MARK: - Session

/// Something the system tells the audio session, translated from
/// `AVAudioSession` notifications into plain values.
public enum AudioSessionEvent: Sendable, Hashable {
    /// The system deactivated the session (a call, Siri, an alarm, another
    /// app). The engine has already been stopped.
    case interruptionBegan(AudioInterruptionReason)
    /// The interruption is over. Resume only if `shouldResume`.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones, AirPods, a car or the speaker override came or went.
    /// `route` is the route after the change.
    case routeChanged(AudioRouteChangeReason, route: AudioRoute)
    /// The media server died. Every audio object is invalid until
    /// `mediaServicesReset`.
    case mediaServicesLost
    /// The media server restarted. Recreate the engine and reconfigure the
    /// session from scratch (Technical Q&A QA1749).
    case mediaServicesReset
}

/// Why an interruption began. Mirrors `AVAudioSession.InterruptionReason`.
public enum AudioInterruptionReason: String, Sendable, Hashable {
    /// Another audio session (usually a phone call) took over.
    case `default`
    /// The built-in microphone was muted in hardware (an iPad Smart Folio
    /// was closed).
    case builtInMicMuted
    /// The route the session used was disconnected and the session prefers
    /// to be interrupted rather than rerouted.
    case routeDisconnected
    case unknown
}

/// Why the route changed. Mirrors `AVAudioSession.RouteChangeReason`.
public enum AudioRouteChangeReason: String, Sendable, Hashable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
    case unknown
}

/// `AVAudioSession`, reduced to what the controller needs.
///
/// Methods are called from the controller's actor, one at a time.
/// Activation blocks, which is why the controller is not on the main actor.
public protocol AudioSessionBackend: Sendable {
    /// Sets `.playAndRecord` / `.voiceChat`, the category options, the
    /// preferred sample rate and the preferred I/O buffer duration.
    func configure(_ configuration: AudioSessionConfiguration) throws

    /// Whether the session still has the category, mode and options
    /// `configure` set. Another framework in the process can change them.
    func isConfigured(for configuration: AudioSessionConfiguration) -> Bool

    /// `setActive(true)`.
    func activate() throws

    /// `setActive(false, options: .notifyOthersOnDeactivation)`, so music an
    /// interrupted app was playing can resume.
    func deactivate() throws

    /// The current input and output ports.
    var currentRoute: AudioRoute { get }

    /// Interruptions, route changes and media-server resets. The controller
    /// is the only consumer.
    var events: AsyncStream<AudioSessionEvent> { get }
}

// MARK: - Engine

/// A node or tap that lives in the audio engine's graph, such as the mic
/// capture tap (#24) or the playback player node (#25).
///
/// The engine calls `install(on:)` every time it builds the graph: on
/// start, after an interruption, after `AVAudioEngineConfigurationChange`
/// (the hardware sample rate or channel count changed, for example when
/// AirPods connect) and after a media-services reset. Voice processing is
/// already enabled and the engine is stopped, so read formats from the
/// nodes (`engine.inputNode.outputFormat(forBus: 0)`) at that point; they
/// follow the current route.
///
/// `uninstall(from:)` is called before every rebuild and on stop. After a
/// media-services reset, `install(on:)` is called on a brand-new engine
/// without an `uninstall` on the dead one, so drop any references to the
/// previous engine's nodes in `install`.
public protocol AudioGraphComponent: AnyObject, Sendable {
    /// Attach and connect nodes or install taps.
    func install(on engine: AVAudioEngine) throws

    /// Remove taps and detach nodes installed by `install(on:)`.
    func uninstall(from engine: AVAudioEngine)
}

/// An `AVAudioEngine` with voice processing, reduced to what the
/// controller needs. Owned and called by the controller's actor only.
public protocol AudioEngineBackend: AnyObject {
    /// Fires when `AVAudioEngineConfigurationChange` stops the engine. The
    /// controller rebuilds the graph and restarts it.
    var configurationChanges: AsyncStream<Void> { get }

    var isRunning: Bool { get }

    /// Enables voice processing as configured (the engine is stopped), then
    /// installs `components` and prepares the engine.
    func prepare(voiceProcessing: VoiceProcessingConfiguration, components: [any AudioGraphComponent]) throws

    func start() throws

    func stop()

    /// Uninstalls the components installed by `prepare`. The engine must be
    /// stopped.
    func teardown()
}

// MARK: - Permission

/// Microphone permission, as `AVAudioApplication.recordPermission` reports
/// it.
public enum MicrophonePermission: String, Sendable, Hashable {
    case undetermined
    case denied
    case granted
}

/// Reads and requests microphone permission.
public protocol MicrophonePermissionProvider: Sendable {
    var status: MicrophonePermission { get }

    /// Shows the system prompt if the user hasn't answered yet.
    ///
    /// - Returns: Whether access is granted.
    func request() async -> Bool
}
