import BlauAudio
import BlauCore
import BlauTelemetry
import os

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
    /// A new stream of live frames, from the next captured frame on. It
    /// finishes when the microphone stops underneath the enrollment (an
    /// interruption, the Live Activity's Stop button), so a clip never
    /// waits for audio that won't come.
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

    /// The capture hub's frames, finishing as soon as the keeper stops
    /// delivering audio. The hub only finishes its streams when it goes
    /// away, so without this a clip would wait forever after an
    /// interruption or a `stopCapture()` from elsewhere.
    public func frames() -> AsyncStream<AudioFrame> {
        let keeper = audio.keeper
        let (statuses, statusSink) = AsyncStream.makeStream(
            of: AudioSessionKeeper.Status.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = Task {
            for await snapshot in await keeper.updates() {
                statusSink.yield(snapshot.status)
            }
            statusSink.finish()
        }
        statusSink.onTermination = { _ in watcher.cancel() }
        return Self.frames(audio.capture.hub.frames(), endingWhen: statuses)
    }

    /// `frames`, finishing when `statuses` reports that the keeper is no
    /// longer delivering audio (inactive, interrupted, paused or failed).
    static func frames(
        _ frames: AsyncStream<AudioFrame>, endingWhen statuses: AsyncStream<AudioSessionKeeper.Status>
    ) -> AsyncStream<AudioFrame> {
        // 10 s of 20 ms frames: the slack the hub gives a subscriber.
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioFrame.self, bufferingPolicy: .bufferingNewest(500))
        let forward = Task {
            for await frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        let watch = Task {
            for await status in statuses where !isDeliveringAudio(status) {
                Log.voiceID.notice("Enrollment audio stopped (\(status, privacy: .public))")
                continuation.finish()
                return
            }
        }
        continuation.onTermination = { _ in
            forward.cancel()
            watch.cancel()
        }
        return stream
    }

    /// Whether audio flows, or is about to, in `status`.
    static func isDeliveringAudio(_ status: AudioSessionKeeper.Status) -> Bool {
        switch status {
        case .starting, .live, .recovering: true
        case .inactive, .interrupted, .paused, .failed: false
        }
    }
}
