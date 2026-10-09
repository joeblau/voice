import BlauAudio
import BlauCore
import Foundation

/// Everything the record button needs to know about a conversation at one
/// moment (#41).
public struct ConversationStatus: Sendable, Equatable {
    /// Whether a conversation is running (started and not stopped). Stays
    /// `true` while the audio recovers from an interruption or the
    /// connection to Grok drops.
    public var isRunning: Bool
    /// Where the turn stands (`TurnOrchestrator`).
    public var turn: TurnState
    /// The realtime connection to Grok.
    public var connection: RealtimeClient.ConnectionState
    /// The conversation's audio (`AudioSessionKeeper`).
    public var audio: AudioSessionKeeper.Status
    /// Whether the user paused listening: the microphone is muted, the
    /// conversation keeps going.
    public var isListeningPaused: Bool

    public init(
        isRunning: Bool = false,
        turn: TurnState = .paused,
        connection: RealtimeClient.ConnectionState = .disconnected(nil),
        audio: AudioSessionKeeper.Status = .inactive,
        isListeningPaused: Bool = false
    ) {
        self.isRunning = isRunning
        self.turn = turn
        self.connection = connection
        self.audio = audio
        self.isListeningPaused = isListeningPaused
    }

    /// No conversation.
    public static let idle = ConversationStatus()

    /// A conversation that is listening on a live microphone and a
    /// connected session.
    public static let listening = ConversationStatus(
        isRunning: true, turn: .listening, connection: .connected, audio: .live)
}

/// The conversation the record button starts and stops (#41).
///
/// The live app adapts `VoiceLoop` (the audio pipeline feeding the
/// `TurnOrchestrator`, #36) to it; previews, UI tests and unit tests use
/// `FakeConversationSession`. `RecordButtonModel` is its only client.
@MainActor
public protocol ConversationSession: AnyObject {
    /// The current status.
    var status: ConversationStatus { get }

    /// The current status at once, then every change, including changes
    /// the record button didn't ask for (the Live Activity's Stop, an
    /// interruption, a dropped connection). Any number of subscribers;
    /// cancel the iterating task to stop.
    func statusUpdates() -> AsyncStream<ConversationStatus>

    /// The microphone's level, `0...1` (see `AudioLevel.normalized`), about
    /// once per 20 ms frame while capturing. The newest value only.
    func inputLevels() -> AsyncStream<Float>

    /// The level of Grok's reply as it plays, `0...1`, sampled every few
    /// tens of milliseconds while it changes. The newest value only.
    func outputLevels() -> AsyncStream<Float>

    /// Speech detected while listening is paused (the microphone muted).
    func mutedSpeechActivity() -> AsyncStream<MutedSpeechActivity>

    /// Starts a conversation and returns once it is listening: the
    /// microphone is live and the speech pipeline is running. The
    /// connection to Grok may still be opening (what the user says meanwhile
    /// is queued).
    ///
    /// - Parameter topic: An earlier topic the conversation picks up (#58,
    ///   "Continue This Topic"), told to Grok before anything the user says;
    ///   `nil` for a fresh conversation.
    /// - Throws: `CancellationError` when `stop()` (the Live Activity's
    ///   Stop) ended the conversation before it was listening. Otherwise
    ///   why it couldn't start, with a `localizedDescription` fit for the
    ///   user. Nothing is left running either way.
    func start(continuing topic: RealtimeContinuedTopic?) async throws

    /// Picks up an earlier topic in the running conversation (#58): Grok is
    /// told about it before the user's next words.
    ///
    /// - Throws: Why it couldn't, for example because no conversation is
    ///   running any more.
    func continueTopic(_ topic: RealtimeContinuedTopic) async throws

    /// Ends the conversation: commits what is being said, closes the
    /// session and releases the microphone. Called while `start()` is in
    /// flight, it ends that start too, which then throws
    /// `CancellationError`. Does nothing when stopped.
    func stop() async

    /// Mutes (`true`) or unmutes the microphone without ending the
    /// conversation. Does nothing when stopped.
    func setListeningPaused(_ paused: Bool) async
}

extension ConversationSession {
    /// Starts a fresh conversation (see ``start(continuing:)``).
    public func start() async throws {
        try await start(continuing: nil)
    }
}
