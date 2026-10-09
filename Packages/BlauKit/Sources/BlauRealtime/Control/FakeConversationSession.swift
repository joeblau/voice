import BlauAudio
import BlauCore
import Foundation

/// A `ConversationSession` for previews, UI tests and unit tests.
///
/// `start()` and `stop()` drive an `AudioService` (the environment's
/// `FakeAudioService`, or an `UnavailableService` to see the failure path)
/// and report a conversation that is listening on a connected session.
/// Tests push everything else by hand: `update(_:)` for status changes,
/// `sendInputLevel(_:)`, `sendOutputLevel(_:)` and `sendMutedSpeech(_:)`.
/// A `stop()` while a (delayed) `start()` is in flight ends that start,
/// which throws `CancellationError`, as the live session does. Every call
/// is recorded for assertions.
@MainActor
public final class FakeConversationSession: ConversationSession {
    /// A call the session received.
    public enum Call: Sendable, Hashable {
        /// `start()`, or `start(continuing:)` with a topic (#58).
        case start
        case stop
        case setListeningPaused(Bool)
        /// `continueTopic(_:)` while a conversation runs.
        case continueTopic(UUID)
    }

    public private(set) var status: ConversationStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            for continuation in statusSubscribers.values {
                continuation.yield(status)
            }
        }
    }

    /// Every call, oldest first.
    public private(set) var calls: [Call] = []

    /// When set, the next `start()` throws it (once).
    public var startError: (any Error)?
    /// The earlier topics conversations were started with or told to
    /// continue (#58), oldest first.
    public private(set) var continuedTopics: [RealtimeContinuedTopic] = []
    /// The status `start()` reports once it returns.
    public var statusAfterStart: ConversationStatus = .listening

    private let audio: any AudioService
    private let clock: any BlauClock
    private let startDelay: Duration
    /// Bumped by every `start()`, and by a `stop()` that ends one in flight.
    private var startGeneration: UInt64 = 0
    private var isStarting = false
    private var nextID: UInt64 = 0
    private var statusSubscribers: [UInt64: AsyncStream<ConversationStatus>.Continuation] = [:]
    private var inputSubscribers: [UInt64: AsyncStream<Float>.Continuation] = [:]
    private var outputSubscribers: [UInt64: AsyncStream<Float>.Continuation] = [:]
    private var mutedSpeechSubscribers: [UInt64: AsyncStream<MutedSpeechActivity>.Continuation] = [:]

    /// - Parameters:
    ///   - audio: What `start()` and `stop()` start and stop capture on.
    ///   - clock: What `startDelay` is measured on.
    ///   - startDelay: How long `start()` takes, to see the connecting
    ///     state.
    public init(
        audio: any AudioService = FakeAudioService(), clock: any BlauClock = SystemClock(),
        startDelay: Duration = .zero
    ) {
        self.audio = audio
        self.clock = clock
        self.startDelay = startDelay
    }

    // MARK: Pushing changes (tests and previews)

    /// Replaces the status, as a live session would report a change.
    public func update(_ status: ConversationStatus) {
        self.status = status
    }

    /// Changes part of the status.
    public func update(_ change: (inout ConversationStatus) -> Void) {
        var status = status
        change(&status)
        self.status = status
    }

    public func sendInputLevel(_ level: Float) {
        for continuation in inputSubscribers.values {
            continuation.yield(level)
        }
    }

    public func sendOutputLevel(_ level: Float) {
        for continuation in outputSubscribers.values {
            continuation.yield(level)
        }
    }

    public func sendMutedSpeech(_ activity: MutedSpeechActivity) {
        for continuation in mutedSpeechSubscribers.values {
            continuation.yield(activity)
        }
    }

    /// Live level subscriptions (input + output), for tests that check the
    /// model only meters while it should.
    public var levelSubscriberCount: Int { inputSubscribers.count + outputSubscribers.count }

    // MARK: ConversationSession

    public func statusUpdates() -> AsyncStream<ConversationStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationStatus.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(status)
        let id = register(continuation, in: \.statusSubscribers)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.statusSubscribers[id] = nil }
        }
        return stream
    }

    public func inputLevels() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        let id = register(continuation, in: \.inputSubscribers)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.inputSubscribers[id] = nil }
        }
        return stream
    }

    public func outputLevels() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        let id = register(continuation, in: \.outputSubscribers)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.outputSubscribers[id] = nil }
        }
        return stream
    }

    public func mutedSpeechActivity() -> AsyncStream<MutedSpeechActivity> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MutedSpeechActivity.self, bufferingPolicy: .bufferingNewest(4))
        let id = register(continuation, in: \.mutedSpeechSubscribers)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.mutedSpeechSubscribers[id] = nil }
        }
        return stream
    }

    public func start(continuing topic: RealtimeContinuedTopic?) async throws {
        calls.append(.start)
        if let topic {
            continuedTopics.append(topic)
        }
        if let error = startError {
            startError = nil
            throw error
        }
        startGeneration &+= 1
        let generation = startGeneration
        isStarting = true
        defer {
            if generation == startGeneration { isStarting = false }
        }
        if startDelay > .zero {
            try await clock.sleep(for: startDelay)
        }
        guard generation == startGeneration else { throw CancellationError() }
        try await audio.startCapture()
        guard generation == startGeneration else {
            await audio.stopCapture()
            throw CancellationError()
        }
        status = statusAfterStart
    }

    public func stop() async {
        calls.append(.stop)
        if isStarting {
            // Stopped while starting (the Live Activity's Stop): the start
            // in flight sees the new generation and throws
            // `CancellationError`.
            startGeneration &+= 1
            isStarting = false
            return
        }
        guard status.isRunning else { return }
        await audio.stopCapture()
        status = .idle
    }

    /// Records the topic; throws `TurnOrchestrator.OrchestratorError.notRunning`
    /// when no conversation is running, as the live session does.
    public func continueTopic(_ topic: RealtimeContinuedTopic) async throws {
        calls.append(.continueTopic(topic.topicID))
        guard status.isRunning else { throw TurnOrchestrator.OrchestratorError.notRunning }
        continuedTopics.append(topic)
    }

    public func setListeningPaused(_ paused: Bool) async {
        calls.append(.setListeningPaused(paused))
        guard status.isRunning else { return }
        update { $0.isListeningPaused = paused }
    }

    private func register<Element>(
        _ continuation: AsyncStream<Element>.Continuation,
        in subscribers: ReferenceWritableKeyPath<FakeConversationSession, [UInt64: AsyncStream<Element>.Continuation]>
    ) -> UInt64 {
        let id = nextID
        nextID += 1
        self[keyPath: subscribers][id] = continuation
        return id
    }
}
