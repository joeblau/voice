import BlauCore
import Foundation
import Testing

@testable import BlauAudio

/// Microphone and audio session problems → the error catalog (#80).
@Suite("Audio issues")
struct AudioIssueTests {
    static let system = SystemError(domain: "NSOSStatusErrorDomain", code: 561_017_449, message: "busy")

    @Test(arguments: [
        (AudioSessionError.microphonePermissionDenied, IssueCode.microphoneDenied),
        (.noSuitableRoute, .microphoneUnavailable),
        (.activationFailed(system), .microphoneBusy),
        (.configurationFailed(system), .audioFailed),
        (.graphSetupFailed(system), .audioFailed),
        (.engineStartFailed(system), .audioFailed),
    ])
    func errors(error: AudioSessionError, code: IssueCode) {
        #expect(error.issue.code == code)
    }

    @Test func theMicrophoneRouteLostOffersToResume() {
        let issue = AudioSessionError.noSuitableRoute.issue
        #expect(issue.actions == [.resumeAudio])
        #expect(issue.severity == .warning)
        #expect(AudioSessionError.microphonePermissionDenied.issue.actions == [.openSettings])
        #expect(AudioSessionError.activationFailed(Self.system).issue.detail == Self.system.description)
    }

    @Test func keeperStatus() {
        #expect(AudioSessionKeeper.Status.inactive.issue == nil)
        #expect(AudioSessionKeeper.Status.starting.issue == nil)
        #expect(AudioSessionKeeper.Status.live.issue == nil)
        #expect(AudioSessionKeeper.Status.recovering.issue?.code == .audioRecovering)
        #expect(AudioSessionKeeper.Status.interrupted.issue?.code == .audioInterrupted)
        #expect(AudioSessionKeeper.Status.paused.issue?.code == .audioPaused)
        #expect(AudioSessionKeeper.Status.failed(.noSuitableRoute).issue?.code == .microphoneUnavailable)
    }
}
