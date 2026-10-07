import Foundation

/// Where the audio session is in its lifecycle. Published by
/// `AudioSessionController` together with the current route.
///
/// ```
///   idle ──start()──▶ starting ──▶ running ◀──────────────┐
///    ▲                   │           │  interruption began │ interruption ended (.shouldResume),
///    │                   ▼           ▼                     │ media services reset, start()
///    └───stop()──── failed(…)    interrupted ──────────────┘
/// ```
///
/// `stop()` returns to `idle` from every state.
public enum AudioSessionState: Sendable, Hashable, CustomStringConvertible {
    /// Nothing is running and the session is inactive.
    case idle
    /// `start()` is checking microphone permission and bringing the session
    /// and engine up.
    case starting
    /// The session is active and the engine is capturing and playing.
    case running
    /// The system took the session away (a phone call, Siri, another app's
    /// audio, the media server restarting). The controller resumes by itself
    /// when the system says it should; otherwise `start()` resumes.
    case interrupted
    /// Starting or recovering failed. Nothing is running. `start()` tries
    /// again.
    case failed(AudioSessionError)

    /// Whether the controller is trying to keep audio running: it is
    /// running, starting, or waiting to resume after an interruption.
    public var isEngaged: Bool {
        switch self {
        case .starting, .running, .interrupted: true
        case .idle, .failed: false
        }
    }

    public var description: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .interrupted: "interrupted"
        case .failed(let error): "failed(\(error))"
        }
    }
}

/// The controller's state and the audio route at one moment, for the UI.
public struct AudioSessionSnapshot: Sendable, Hashable {
    public var state: AudioSessionState
    public var route: AudioRoute

    public init(state: AudioSessionState, route: AudioRoute) {
        self.state = state
        self.route = route
    }
}

/// Why the audio session could not start or keep running.
public enum AudioSessionError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The user has not granted microphone access.
    case microphonePermissionDenied
    /// Setting the category, mode, sample rate or buffer duration failed.
    case configurationFailed(SystemError)
    /// Activating the session failed, for example because a phone call is
    /// using the microphone (`AVAudioSession.ErrorCode.insufficientPriority`).
    case activationFailed(SystemError)
    /// Enabling voice processing or installing the capture and playback
    /// nodes failed.
    case graphSetupFailed(SystemError)
    /// `AVAudioEngine.start()` failed.
    case engineStartFailed(SystemError)
    /// The system reports no route that can play and record
    /// (`AVAudioSession.RouteChangeReason.noSuitableRouteForCategory`).
    case noSuitableRoute

    public var description: String {
        switch self {
        case .microphonePermissionDenied: "microphonePermissionDenied"
        case .configurationFailed(let error): "configurationFailed(\(error))"
        case .activationFailed(let error): "activationFailed(\(error))"
        case .graphSetupFailed(let error): "graphSetupFailed(\(error))"
        case .engineStartFailed(let error): "engineStartFailed(\(error))"
        case .noSuitableRoute: "noSuitableRoute"
        }
    }
}

/// A `Sendable`, comparable summary of an error thrown by AVFoundation (an
/// `NSError`), so `AudioSessionState` can stay a plain value.
public struct SystemError: Error, Sendable, Hashable, CustomStringConvertible {
    public var domain: String
    public var code: Int
    public var message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(_ error: any Error) {
        if let error = error as? SystemError {
            self = error
            return
        }
        let nsError = error as NSError
        self.init(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
    }

    /// Domain and code only: OSStatus-style codes are what you search for,
    /// and the message can be localized.
    public var description: String { "\(domain) \(code)" }
}
