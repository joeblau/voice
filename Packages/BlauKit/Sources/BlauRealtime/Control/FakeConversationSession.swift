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
/// Every call is recorded for assertions.
@MainActor
public final class FakeConversationSession: ConversationSession {
    /// A call the session received.
    public enum Call: Sendable, Hashable {
        case start
        case stop
        case setListeningPaused(Bool)
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
    /// The status `start()` reports once it returns.
    public var statusAfterStart: ConversationStatus = .listening

    private let audio: any AudioService
    private let clock: any BlauClock
    private let startDelay: Duration
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

    public func start() async throws {
        calls.append(.start)
        if let error = startError {
            startError = nil
            throw error
        }
        if startDelay > .zero {
            try await clock.sleep(for: startDelay)
        }
        try await audio.startCapture()
        status = statusAfterStart
    }

    public func stop() async {
        calls.append(.stop)
        guard status.isRunning else { return }
        await audio.stopCapture()
        status = .idle
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
