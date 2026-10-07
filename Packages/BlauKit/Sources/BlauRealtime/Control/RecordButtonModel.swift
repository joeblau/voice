import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Observation
import os

/// The logic behind the record button (#41), the main screen's primary
/// control: starts and ends the conversation, pauses and resumes listening,
/// and tells the view what to draw (`state`, the two level rings, the
/// "You're muted" hint) and when to play a haptic (`feedback`).
///
/// ```swift
/// @State var record = RecordButtonModel(session: environment.conversation)
/// RecordButton(model: record)
///     .task { await record.run() }          // follows the session while on screen
/// ```
///
/// **Taps.** `tap()` starts a conversation when idle (or after a failed
/// start) and ends it when one is running, whatever it is doing (listening,
/// Grok speaking, paused, an audio or connection error). Taps that arrive
/// while a start or stop is in flight are ignored, so a double tap can't
/// start two conversations. A long press offers `pauseListening()` /
/// `resumeListening()`, which mute the microphone without ending anything.
///
/// A conversation ended while it starts (the Live Activity's Stop, which
/// makes `ConversationSession.start()` throw `CancellationError`) goes back
/// to idle quietly: that is what the user asked for, not a failed start.
///
/// **Following the session.** `run()` consumes the session's status, so
/// changes nobody asked the button for (the Live Activity's Stop, a phone
/// call, the debug Voice Loop screen, a dropped connection) show up at once.
/// While a conversation runs and the screen is visible it also follows the
/// input and output levels, smoothed by a `LevelMeter`.
///
/// **Telemetry.** A `session.start` interval spans the tap to the first
/// moment the button shows listening (docs/performance.md); the same span
/// is kept in `lastStartLatency` and logged. The issue's target is under
/// 500 ms with the models warm.
@MainActor
@Observable
public final class RecordButtonModel {
    /// What the button itself is doing.
    public enum Phase: String, Sendable {
        /// No conversation. Tapping starts one.
        case idle
        /// `ConversationSession.start()` is in flight.
        case starting
        /// A conversation is running. Tapping ends it.
        case running
        /// `ConversationSession.stop()` is in flight.
        case stopping
    }

    /// A haptic the view should play.
    public enum Feedback: String, Sendable {
        /// The conversation is listening.
        case started
        /// The user ended the conversation.
        case stopped
        /// Listening paused (microphone muted).
        case paused
        /// Listening resumed.
        case resumed
        /// The conversation couldn't start.
        case failed
    }

    /// One haptic request. `sequence` grows with every request, so the same
    /// kind twice in a row is still a change the view sees.
    public struct FeedbackEvent: Sendable, Equatable {
        public let kind: Feedback
        public let sequence: Int
    }

    public struct Configuration: Sendable, Hashable {
        /// How long "You're muted" stays up after the user stops talking.
        public var mutedHintLinger: Duration
        /// The smallest level change worth redrawing the ring for.
        public var levelResolution: Float
        /// The longest gap between two levels the meter treats as elapsed
        /// time (after a pause in the stream, start from where it was).
        public var maximumLevelGap: Duration

        public init(
            mutedHintLinger: Duration = .seconds(3),
            levelResolution: Float = 0.02,
            maximumLevelGap: Duration = .milliseconds(200)
        ) {
            self.mutedHintLinger = mutedHintLinger
            self.levelResolution = levelResolution
            self.maximumLevelGap = maximumLevelGap
        }

        public static let standard = Configuration()
    }

    public private(set) var phase: Phase = .idle
    /// The session's latest status.
    public private(set) var status: ConversationStatus
    /// Why the last start failed, until the next start. Shows as `error`
    /// while idle.
    public private(set) var failure: RecordButtonFailure?
    /// The message for the "couldn't start" alert, until it is dismissed
    /// (set it to `nil`).
    public var startFailureMessage: String?
    /// The smoothed microphone level, `0...1`. Zero unless listening on a
    /// visible screen.
    public private(set) var inputLevel: Float = 0
    /// The smoothed level of Grok's reply, `0...1`. Zero unless Grok is
    /// speaking on a visible screen.
    public private(set) var outputLevel: Float = 0
    /// Whether to show "You're muted": the user is talking while listening
    /// is paused.
    public private(set) var isMutedSpeechHintVisible = false
    /// The latest haptic request.
    public private(set) var feedback: FeedbackEvent?
    /// Tap to listening for the latest start.
    public private(set) var lastStartLatency: Duration?

    /// What the button shows.
    public var state: RecordButtonState {
        RecordButtonState(phase: phase, status: status, failure: failure)
    }

    /// Whether the conversation is running but Grok isn't connected (yet,
    /// or any more). The user can keep talking: what they say is queued.
    public var isAwaitingConnection: Bool {
        phase == .running && status.connection != .connected
    }

    @ObservationIgnored public let session: any ConversationSession
    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored private let clock: any BlauClock
    @ObservationIgnored private let signposter: Signposter
    @ObservationIgnored private let logger = Log.ui

    @ObservationIgnored private var pendingStart: (interval: SignpostInterval, startedAt: Duration)?
    @ObservationIgnored private var observers = 0
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private var levelTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var inputMeter = LevelMeter()
    @ObservationIgnored private var outputMeter = LevelMeter(attack: .milliseconds(30), release: .milliseconds(180))
    @ObservationIgnored private var lastInputAt: Duration?
    @ObservationIgnored private var lastOutputAt: Duration?

    public init(
        session: any ConversationSession,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.ui,
        configuration: Configuration = .standard
    ) {
        self.session = session
        self.clock = clock
        self.signposter = signposter
        self.configuration = configuration
        status = session.status
        phase = status.isRunning ? .running : .idle
    }

    isolated deinit {
        for task in levelTasks {
            task.cancel()
        }
        hintTask?.cancel()
        pendingStart?.interval.end(message: "cancelled")
    }

    // MARK: Actions

    /// Starts a conversation when idle (or after a failed start), ends it
    /// when one is running, and does nothing while a start or stop is in
    /// flight.
    public func tap() async {
        switch phase {
        case .idle: await start()
        case .running: await stop()
        case .starting, .stopping: return
        }
    }

    /// Mutes the microphone without ending the conversation. Does nothing
    /// unless a conversation is running and listening.
    public func pauseListening() async {
        guard phase == .running, !status.isListeningPaused else { return }
        await session.setListeningPaused(true)
        apply(session.status)
        guard status.isListeningPaused else { return }
        emit(.paused)
        logger.notice("Listening paused from the record button")
    }

    /// Unmutes the microphone. Does nothing unless listening is paused.
    public func resumeListening() async {
        guard phase == .running, status.isListeningPaused else { return }
        await session.setListeningPaused(false)
        apply(session.status)
        hideMutedSpeechHint()
        emit(.resumed)
        logger.notice("Listening resumed from the record button")
    }

    /// Whether a start or stop is in flight, so taps are ignored. The view
    /// disables the button only then: a running conversation can always be
    /// ended, even while its audio comes back (`reconnecting`).
    public var isTransitioning: Bool {
        phase == .starting || phase == .stopping
    }

    /// Whether the long-press menu has anything to offer: pause or resume
    /// while a conversation runs.
    public var canPauseOrResume: Bool {
        phase == .running && status.isRunning
    }

    // MARK: Following the session

    /// Follows the session's status and speech-while-muted reports (and,
    /// while a conversation runs on a visible screen, the levels) until the
    /// calling task is cancelled. Run it from the view's `.task`.
    public func run() async {
        observers += 1
        defer {
            observers -= 1
            updateLevelSubscription()
        }
        apply(session.status)
        updateLevelSubscription()
        let statuses = session.statusUpdates()
        let mutedSpeech = session.mutedSpeechActivity()
        // The stream says something changed; the session's current status
        // is what changed to. A buffered status can be older than one the
        // button already applied after its own call (start, pause), so it
        // is never applied as is.
        let statusTask = Task { [weak self] in
            for await _ in statuses {
                guard let self else { return }
                apply(session.status)
            }
        }
        let mutedSpeechTask = Task { [weak self] in
            for await activity in mutedSpeech {
                self?.receive(activity)
            }
        }
        // Both streams live as long as the session; if one ends anyway, stop
        // following the other too, so `run()` returns rather than half
        // following. Cancelling the caller cancels both.
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await statusTask.value }
                group.addTask { await mutedSpeechTask.value }
                await group.next()
                statusTask.cancel()
                mutedSpeechTask.cancel()
            }
        } onCancel: {
            statusTask.cancel()
            mutedSpeechTask.cancel()
        }
    }

    /// Re-reads the session's status, for example on returning to the
    /// foreground.
    public func synchronize() {
        apply(session.status)
    }

    /// Whether the button is on screen. Levels are only followed while it
    /// is, so a conversation in the background doesn't redraw it 50 times a
    /// second.
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        updateLevelSubscription()
    }

    // MARK: Starting and stopping

    private func start() async {
        phase = .starting
        failure = nil
        startFailureMessage = nil
        pendingStart?.interval.end(message: "superseded")
        pendingStart = (signposter.beginInterval(.sessionStart), clock.uptime)
        logger.notice("Starting a conversation from the record button")
        do {
            try await session.start()
            phase = .running
            apply(session.status)
        } catch is CancellationError {
            // Ended before it was listening (the Live Activity's Stop): what
            // the user asked for, so no error, alert or haptic.
            phase = .idle
            status = session.status
            pendingStart?.interval.end(message: "cancelled")
            pendingStart = nil
            logger.notice("The conversation was stopped while it started")
        } catch {
            let message = Self.message(for: error)
            phase = .idle
            status = session.status
            failure = .couldNotStart(message: message)
            startFailureMessage = message
            pendingStart?.interval.end(message: "failed")
            pendingStart = nil
            emit(.failed)
            logger.error("Couldn't start the conversation: \(String(describing: error), privacy: .public)")
        }
        updateLevelSubscription()
    }

    /// What the alert says about a failed start.
    static func message(for error: any Error) -> String {
        if error is ServiceUnavailableError {
            return String(
                localized: "Conversations aren't available in this build of Blau yet.")
        }
        return error.localizedDescription
    }

    private func stop() async {
        phase = .stopping
        emit(.stopped)
        pendingStart?.interval.end(message: "stopped")
        pendingStart = nil
        hideMutedSpeechHint()
        updateLevelSubscription()
        logger.notice("Ending the conversation from the record button")
        await session.stop()
        phase = .idle
        apply(session.status)
    }

    /// Takes a new status, and follows it when it changed without the
    /// button: a conversation that ended (the Live Activity's Stop) or
    /// started (the debug Voice Loop screen) elsewhere.
    private func apply(_ newStatus: ConversationStatus) {
        if status != newStatus {
            status = newStatus
        }
        switch phase {
        case .running where !newStatus.isRunning:
            phase = .idle
            pendingStart?.interval.end(message: "stopped")
            pendingStart = nil
            logger.notice("The conversation ended outside the record button")
        case .idle where newStatus.isRunning:
            phase = .running
            failure = nil
            logger.notice("A conversation started outside the record button")
        default:
            break
        }
        if !newStatus.isRunning || !newStatus.isListeningPaused {
            hideMutedSpeechHint()
        }
        completeStartIfListening()
        updateLevelSubscription()
    }

    /// Ends `session.start` the first time the button shows the microphone
    /// live after a tap.
    private func completeStartIfListening() {
        guard let pending = pendingStart, phase == .running else { return }
        let state = state
        guard state.isListening || state == .paused else { return }
        pendingStart = nil
        let latency = clock.uptime - pending.startedAt
        pending.interval.end(message: "listening")
        lastStartLatency = latency
        emit(.started)
        logger.notice(
            "Conversation listening \(latency.wholeMilliseconds, privacy: .public) ms after the tap")
    }

    // MARK: Muted speech

    private func receive(_ activity: MutedSpeechActivity) {
        guard phase == .running, status.isListeningPaused else { return }
        switch activity {
        case .started:
            hintTask?.cancel()
            hintTask = nil
            if !isMutedSpeechHintVisible {
                isMutedSpeechHintVisible = true
                logger.info("The user is talking while listening is paused")
            }
        case .ended:
            guard isMutedSpeechHintVisible else { return }
            hintTask?.cancel()
            let clock = clock
            let linger = configuration.mutedHintLinger
            hintTask = Task { [weak self] in
                do {
                    try await clock.sleep(for: linger)
                } catch {
                    return
                }
                self?.hideMutedSpeechHint()
            }
        }
    }

    private func hideMutedSpeechHint() {
        hintTask?.cancel()
        hintTask = nil
        if isMutedSpeechHintVisible {
            isMutedSpeechHintVisible = false
        }
    }

    // MARK: Levels

    private func updateLevelSubscription() {
        let wanted = observers > 0 && isVisible && phase == .running
        if wanted, levelTasks.isEmpty {
            let inputs = session.inputLevels()
            let outputs = session.outputLevels()
            levelTasks = [
                Task { [weak self] in
                    for await level in inputs {
                        self?.receiveInput(level)
                    }
                },
                Task { [weak self] in
                    for await level in outputs {
                        self?.receiveOutput(level)
                    }
                },
            ]
        } else if !wanted, !levelTasks.isEmpty {
            for task in levelTasks {
                task.cancel()
            }
            levelTasks = []
            resetLevels()
        }
    }

    private func receiveInput(_ level: Float) {
        // A muted microphone reads silence anyway; don't let a late frame
        // flash the ring.
        let target = state == .listening || state == .agentSpeaking ? level : 0
        let elapsed = elapsedSince(&lastInputAt)
        publish(inputMeter.update(to: target, elapsed: elapsed), to: \.inputLevel)
    }

    private func receiveOutput(_ level: Float) {
        let target = state == .agentSpeaking ? level : 0
        let elapsed = elapsedSince(&lastOutputAt)
        publish(outputMeter.update(to: target, elapsed: elapsed), to: \.outputLevel)
    }

    private func elapsedSince(_ last: inout Duration?) -> Duration {
        let now = clock.uptime
        defer { last = now }
        guard let last else { return configuration.maximumLevelGap }
        return min(now - last, configuration.maximumLevelGap)
    }

    /// Redraws only for a visible change, and always for the drop to zero.
    private func publish(_ value: Float, to keyPath: ReferenceWritableKeyPath<RecordButtonModel, Float>) {
        let current = self[keyPath: keyPath]
        guard abs(value - current) >= configuration.levelResolution || (value == 0 && current != 0) else { return }
        self[keyPath: keyPath] = value
    }

    private func resetLevels() {
        inputMeter.reset()
        outputMeter.reset()
        lastInputAt = nil
        lastOutputAt = nil
        if inputLevel != 0 { inputLevel = 0 }
        if outputLevel != 0 { outputLevel = 0 }
    }

    // MARK: Feedback

    private func emit(_ kind: Feedback) {
        feedback = FeedbackEvent(kind: kind, sequence: (feedback?.sequence ?? 0) + 1)
    }
}

extension Duration {
    /// Whole milliseconds, for logs.
    fileprivate var wholeMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
