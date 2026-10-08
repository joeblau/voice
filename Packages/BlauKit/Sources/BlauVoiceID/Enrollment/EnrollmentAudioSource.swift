import BlauAudio
import BlauCore

/// The microphone an enrollment records from.
///
/// Enrollment must hear the user exactly as the gate will: through the same
/// voice-processing (VPIO) capture path, with its echo cancellation, noise
/// suppression and AGC, resampled to 16 kHz by the same capture engine
/// (issue #46). The live source is ``ConversationEnrollmentAudio``, over the
/// conversation's own audio; tests and previews use
/// ``ScriptedEnrollmentAudio``.
public protocol EnrollmentAudioSource: Sendable {
    /// Turns the microphone on.
    func start() async throws
    /// Turns it off. Calling it when off does nothing.
    func stop() async
    /// A new stream of live frames, from the next captured frame on.
    func frames() -> AsyncStream<AudioFrame>
}

/// Records enrollment through the conversation's audio: the
/// `AudioSessionKeeper` brings up the voice-processing engine and the
/// `MicrophoneCapture` hub delivers the frames, exactly as during a
/// conversation.
public struct ConversationEnrollmentAudio: EnrollmentAudioSource {
    public let audio: ConversationAudio

    public init(audio: ConversationAudio) {
        self.audio = audio
    }

    /// - Throws: ``VoiceEnrollmentError/microphoneBusy`` while a
    ///   conversation holds the microphone, and
    ///   ``VoiceEnrollmentError/microphoneUnavailable(_:)`` when the audio
    ///   can't start (permission denied, a call holding the microphone).
    public func start() async throws {
        guard await audio.keeper.status == .inactive else { throw VoiceEnrollmentError.microphoneBusy }
        // "Pause listening" mutes inside voice processing; enrollment must
        // hear the user.
        audio.microphoneMute.setMuted(false)
        do {
            try await audio.keeper.startCapture()
        } catch {
            throw VoiceEnrollmentError.microphoneUnavailable(String(describing: error))
        }
    }

    public func stop() async {
        await audio.keeper.stopCapture()
    }

    public func frames() -> AsyncStream<AudioFrame> {
        audio.capture.hub.frames()
    }
}
