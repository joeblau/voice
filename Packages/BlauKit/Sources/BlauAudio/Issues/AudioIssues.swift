import BlauCore
import Foundation

extension AudioSessionError {
    /// The catalog entry for this error (#80, docs/errors.md).
    public var issue: UserFacingIssue {
        switch self {
        case .microphonePermissionDenied:
            UserFacingIssue(.microphoneDenied)
        case .noSuitableRoute:
            // The route the conversation used went away (a headset unplugged,
            // a Bluetooth device out of range) and nothing else can record.
            UserFacingIssue(.microphoneUnavailable)
        case .activationFailed(let error):
            // Typically `insufficientPriority`: a call holds the microphone.
            UserFacingIssue(.microphoneBusy, detail: error.description)
        case .configurationFailed(let error), .graphSetupFailed(let error), .engineStartFailed(let error):
            UserFacingIssue(.audioFailed, detail: error.description)
        }
    }
}

extension AudioSessionKeeper.Status {
    /// What to tell the user about the conversation's audio, or `nil` while
    /// it is off, starting or live.
    public var issue: UserFacingIssue? {
        switch self {
        case .inactive, .starting, .live:
            nil
        case .recovering:
            UserFacingIssue(.audioRecovering)
        case .interrupted:
            UserFacingIssue(.audioInterrupted)
        case .paused:
            UserFacingIssue(.audioPaused)
        case .failed(let error):
            error.issue
        }
    }
}
