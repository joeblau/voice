import AVFAudio
import BlauCore
import BlauTelemetry
import Synchronization
import os

/// What the voice-processing unit reports about the user's voice while the
/// microphone is muted.
public enum MutedSpeechActivity: String, Sendable, Hashable {
    /// The user started talking while muted.
    case started
    /// They stopped.
    case ended
}

/// The input node's mute, reduced to what `MicrophoneMute` needs, so the
/// component's logic is testable without a microphone. `AVAudioInputNode`
/// (`Sendable` in the SDK) conforms.
public protocol VoiceProcessingInputMuting: AnyObject, Sendable {
    /// `AVAudioInputNode.isVoiceProcessingInputMuted`.
    var isVoiceProcessingInputMuted: Bool { get set }

    /// Installs (or, with `nil`, removes) the listener for speech while
    /// muted. Returns whether the node accepted it.
    @discardableResult
    func setMutedSpeechActivityListener(_ listener: (@Sendable (MutedSpeechActivity) -> Void)?) -> Bool
}

extension AVAudioInputNode: VoiceProcessingInputMuting {
    @discardableResult
    public func setMutedSpeechActivityListener(_ listener: (@Sendable (MutedSpeechActivity) -> Void)?) -> Bool {
        guard let listener else { return setMutedSpeechActivityEventListener(nil) }
        return setMutedSpeechActivityEventListener { event in
            listener(event == .started ? .started : .ended)
        }
    }
}

/// "Pause listening" for the record button (#41): mutes the microphone
/// without ending the conversation, and reports when the user talks while
/// muted so the UI can say "You're muted".
///
/// It mutes inside the voice-processing unit
/// (`AVAudioInputNode.isVoiceProcessingInputMuted`) rather than stopping
/// capture or dropping frames:
///
/// - the session, the engine and the capture stream keep running, so
///   resuming is instant, the Live Activity stays up, and the keeper's
///   watchdog still sees audio arriving (silence);
/// - VAD, ASR and voice ID get digital silence, so nothing the user says
///   while muted can reach the transcript or Grok;
/// - `setMutedSpeechActivityEventListener` only works with this kind of
///   mute (see its documentation in `AVAudioIONode.h`).
///
/// It is an `AudioGraphComponent` registered with the conversation's
/// controller (`ConversationAudio`), so the mute survives every graph
/// rebuild (route change, interruption, media-services reset): each
/// `install(on:)` applies the current state to the new input node.
///
/// ```swift
/// audio.microphoneMute.setMuted(true)
/// for await activity in audio.microphoneMute.speechActivity() { ... }   // .started / .ended
/// ```
public final class MicrophoneMute: AudioGraphComponent {
    private struct State {
        var isMuted = false
        var input: (any VoiceProcessingInputMuting)?
        var nextSubscriberID: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<MutedSpeechActivity>.Continuation] = [:]
        /// The last activity reported while muted, so a `.started` is
        /// always followed by an `.ended` (on unmute if not before).
        var isSpeaking = false
    }

    private let state = Mutex(State())
    private let logger = Log.audio

    public init() {}

    deinit {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    /// Whether the microphone is muted. Kept across graph rebuilds.
    public var isMuted: Bool {
        state.withLock { $0.isMuted }
    }

    /// Mutes or unmutes the microphone. Applies at once when the graph is
    /// running, and on the next `install(on:)` otherwise.
    public func setMuted(_ muted: Bool) {
        let endedSpeech = state.withLock { state -> Bool in
            guard state.isMuted != muted else { return false }
            state.isMuted = muted
            state.input?.isVoiceProcessingInputMuted = muted
            // Unmuting ends whatever speech was reported while muted.
            guard !muted, state.isSpeaking else { return false }
            state.isSpeaking = false
            return true
        }
        if endedSpeech {
            broadcast(.ended)
        }
        logger.notice("Microphone \(muted ? "muted" : "unmuted", privacy: .public)")
    }

    /// A new stream of speech activity while muted. Nothing arrives while
    /// unmuted. Any number of subscribers; cancel the iterating task to
    /// stop.
    public func speechActivity() -> AsyncStream<MutedSpeechActivity> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MutedSpeechActivity.self, bufferingPolicy: .bufferingNewest(4))
        let id = state.withLock { state in
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.subscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: AudioGraphComponent

    public func install(on engine: AVAudioEngine) throws {
        attach(to: engine.inputNode)
    }

    public func uninstall(from engine: AVAudioEngine) {
        detach()
    }

    // MARK: Attaching (internal for tests)

    /// Takes over `input`: applies the current mute and listens for speech
    /// while muted. Replaces any earlier input (after a media-services
    /// reset `install` comes without an `uninstall`).
    func attach(to input: any VoiceProcessingInputMuting) {
        let muted = state.withLock { state in
            state.input = input
            input.isVoiceProcessingInputMuted = state.isMuted
            return state.isMuted
        }
        let accepted = input.setMutedSpeechActivityListener { [weak self] activity in
            self?.report(activity)
        }
        if !accepted {
            logger.error("The input node refused the muted speech activity listener")
        }
        logger.info("Microphone mute attached (muted: \(muted, privacy: .public))")
    }

    /// Lets go of the input node, leaving it unmuted. The mute state is
    /// kept for the next `attach`.
    func detach() {
        let input = state.withLock { state -> (any VoiceProcessingInputMuting)? in
            defer { state.input = nil }
            state.input?.isVoiceProcessingInputMuted = false
            return state.input
        }
        input?.setMutedSpeechActivityListener(nil)
    }

    /// Called by the input node's listener, on an internal queue.
    func report(_ activity: MutedSpeechActivity) {
        let shouldReport = state.withLock { state -> Bool in
            guard state.isMuted else { return false }
            let speaking = activity == .started
            guard state.isSpeaking != speaking else { return false }
            state.isSpeaking = speaking
            return true
        }
        guard shouldReport else { return }
        logger.info("Speech while muted: \(activity.rawValue, privacy: .public)")
        broadcast(activity)
    }

    private func broadcast(_ activity: MutedSpeechActivity) {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers {
            subscriber.yield(activity)
        }
    }
}
