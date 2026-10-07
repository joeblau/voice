// In-memory stand-ins for the service protocols, for SwiftUI previews,
// UI-test launches and unit tests. They never touch hardware, the network or
// models, and they record what they were asked to do so tests can check it.

import Foundation
import Synchronization

// MARK: - Audio

/// An `AudioService` that only tracks whether it is "capturing".
public final class FakeAudioService: AudioService {
    private struct State {
        var isCapturing = false
        var startCount = 0
        var transitions: [AppPhaseTransition] = []
    }

    private let state = Mutex(State())
    private let startError: (any Error)?

    /// - Parameters:
    ///   - isCapturing: The initial state.
    ///   - startError: When set, `startCapture()` throws it.
    public init(isCapturing: Bool = false, startError: (any Error)? = nil) {
        self.startError = startError
        state.withLock { $0.isCapturing = isCapturing }
    }

    public var isCapturing: Bool { state.withLock { $0.isCapturing } }

    /// How many times `startCapture()` succeeded.
    public var startCount: Int { state.withLock { $0.startCount } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func startCapture() async throws {
        if let startError { throw startError }
        state.withLock { state in
            state.isCapturing = true
            state.startCount += 1
        }
    }

    public func stopCapture() async {
        state.withLock { $0.isCapturing = false }
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }
}

// MARK: - Voice ID

/// A `VoiceGate` that returns scripted decisions.
public final class FakeVoiceGate: VoiceGate {
    private struct State {
        var decisions: [SpeakerDecision]
        var evaluatedSegments: [AudioFrame] = []
        var transitions: [AppPhaseTransition] = []
    }

    private let state: Mutex<State>
    private let enrolled: Bool
    private let fallback: SpeakerDecision

    /// - Parameters:
    ///   - isEnrolled: Whether a voiceprint is "enrolled". When `false`,
    ///     every segment is rejected.
    ///   - decisions: Returned in order, one per `evaluate(_:)` call.
    ///   - fallback: Returned once `decisions` runs out.
    public init(isEnrolled: Bool = true, decisions: [SpeakerDecision] = [], fallback: SpeakerDecision = .accept) {
        self.enrolled = isEnrolled
        self.fallback = fallback
        self.state = Mutex(State(decisions: decisions))
    }

    public var isEnrolled: Bool { enrolled }

    /// Every segment passed to `evaluate(_:)`, oldest first.
    public var evaluatedSegments: [AudioFrame] { state.withLock { $0.evaluatedSegments } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func evaluate(_ segment: AudioFrame) async throws -> SpeakerDecision {
        state.withLock { state in
            state.evaluatedSegments.append(segment)
            guard enrolled else { return .reject }
            return state.decisions.isEmpty ? fallback : state.decisions.removeFirst()
        }
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }
}

// MARK: - Realtime

/// A `RealtimeService` that records the utterances sent to "Grok".
public final class FakeRealtimeService: RealtimeService {
    /// Thrown by `send(_:)` when no session is open.
    public struct NotConnectedError: Error, Hashable, Sendable {
        public init() {}
    }

    private struct State {
        var isConnected = false
        var sentUtterances: [Utterance] = []
        var transitions: [AppPhaseTransition] = []
    }

    private let state = Mutex(State())

    public init(isConnected: Bool = false) {
        state.withLock { $0.isConnected = isConnected }
    }

    public var isConnected: Bool { state.withLock { $0.isConnected } }

    /// Every utterance sent, oldest first.
    public var sentUtterances: [Utterance] { state.withLock { $0.sentUtterances } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func connect() async throws {
        state.withLock { $0.isConnected = true }
    }

    public func disconnect() async {
        state.withLock { $0.isConnected = false }
    }

    public func send(_ utterance: Utterance) async throws {
        try state.withLock { state throws(NotConnectedError) in
            guard state.isConnected else { throw NotConnectedError() }
            state.sentUtterances.append(utterance)
        }
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }
}

// MARK: - Topics

/// A `TopicService` that records the utterances it is fed.
public final class FakeTopicService: TopicService {
    private struct State {
        var ingested: [Utterance] = []
        var transitions: [AppPhaseTransition] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Every utterance ingested, oldest first.
    public var ingestedUtterances: [Utterance] { state.withLock { $0.ingested } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func ingest(_ utterance: Utterance) async {
        state.withLock { $0.ingested.append(utterance) }
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }
}

// MARK: - Memory

/// A `MemoryService` over a fixed list of memories, ranked by keyword
/// overlap: the fraction of the query's words that appear in a memory.
public final class FakeMemoryService: MemoryService {
    private struct State {
        var queries: [String] = []
        var transitions: [AppPhaseTransition] = []
    }

    /// The searchable memories, each with a stable identifier.
    public let memories: [MemoryHit]

    private let state = Mutex(State())

    public init(memories: [String] = []) {
        self.memories = memories.map { MemoryHit(text: $0, score: 0) }
    }

    /// Every query searched, oldest first.
    public var queries: [String] { state.withLock { $0.queries } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func search(_ query: String, limit: Int) async throws -> [MemoryHit] {
        state.withLock { $0.queries.append(query) }
        let terms = Set(Self.words(in: query))
        guard !terms.isEmpty, limit > 0 else { return [] }

        let ranked = memories.enumerated().compactMap { index, memory -> (Int, MemoryHit)? in
            let matches = terms.intersection(Self.words(in: memory.text)).count
            guard matches > 0 else { return nil }
            return (index, MemoryHit(id: memory.id, text: memory.text, score: Double(matches) / Double(terms.count)))
        }
        // Best score first; ties keep the memories' original order.
        return
            ranked
            .sorted { ($1.1.score, $0.0) < ($0.1.score, $1.0) }
            .prefix(limit)
            .map(\.1)
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
