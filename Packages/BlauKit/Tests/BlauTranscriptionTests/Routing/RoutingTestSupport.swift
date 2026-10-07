import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// A `RoutableTranscriber` the test drives: it emits what it is told to,
/// and `stop()` commits the utterance in progress, like the real ones.
actor FakeRoutableTranscriber: RoutableTranscriber {
    nonisolated let events: AsyncStream<TranscriptEvent>
    nonisolated let engine: TranscriptionEngine
    nonisolated let serial: Int
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let startError: (any Error)?

    private(set) var startPositions: [Duration?] = []
    private(set) var stops = 0
    private(set) var finishes = 0
    private(set) var isRunning = false
    private(set) var conversationIDs: [ConversationID] = []
    private(set) var transitions: [AppPhaseTransition] = []
    private var conversationID = ConversationID()
    private var open: (text: String, range: TimeRange)?

    init(engine: TranscriptionEngine, serial: Int, startError: (any Error)? = nil) {
        self.engine = engine
        self.serial = serial
        self.startError = startError
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
    }

    func start() async throws {
        try await start(resumingAt: nil)
    }

    func start(resumingAt position: Duration?) async throws {
        if let startError { throw startError }
        startPositions.append(position)
        isRunning = true
    }

    func stop() async {
        stops += 1
        isRunning = false
        if let open {
            commit(open.text, range: open.range)
        }
    }

    func finish() async {
        await stop()
        finishes += 1
        continuation.finish()
    }

    func setConversationID(_ id: ConversationID) async {
        conversationID = id
        conversationIDs.append(id)
    }

    func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        transitions.append(transition)
    }

    /// The speaker is mid-utterance: `text` so far, over `from..<to` seconds.
    func say(_ text: String, from: Double, to: Double) {
        let range = TimeRange(start: .seconds(from), end: .seconds(to))
        open = (text, range)
        continuation.yield(.partial(text: text, range: range))
    }

    /// Commits `text` over `from..<to` seconds.
    func commit(_ text: String, from: Double, to: Double) {
        commit(text, range: TimeRange(start: .seconds(from), end: .seconds(to)))
    }

    private func commit(_ text: String, range: TimeRange) {
        open = nil
        let utterance = Utterance(
            conversationID: conversationID, speaker: .user, text: text, timeRange: range, startedAt: .distantPast)
        continuation.yield(.final(utterance))
    }
}

/// Builds fake engines for the router and keeps every one it built.
final class FakeEngines: Sendable {
    private struct State {
        var available: [TranscriptionEngine: Bool] = [.parakeet: true, .apple: true]
        var makeErrors: [TranscriptionEngine: any Error] = [:]
        var startErrors: [TranscriptionEngine: any Error] = [:]
        var built: [FakeRoutableTranscriber] = []
        var makeGates: [TranscriptionEngine: Gate] = [:]
        var blockedMakes: [TranscriptionEngine: Int] = [:]
    }

    private let state = Mutex(State())

    /// Makes `make()` for `engine` wait for `gate` to open (a slow model
    /// load or asset download); `nil` lets it build at once again.
    func setMakeGate(_ engine: TranscriptionEngine, _ gate: Gate?) {
        state.withLock { $0.makeGates[engine] = gate }
    }

    /// How many `make()` calls for `engine` have waited on its gate.
    func blockedMakes(_ engine: TranscriptionEngine) -> Int {
        state.withLock { $0.blockedMakes[engine] ?? 0 }
    }

    /// The engines built so far that are running now.
    func running() async -> [FakeRoutableTranscriber] {
        var running: [FakeRoutableTranscriber] = []
        for transcriber in state.withLock({ $0.built }) where await transcriber.isRunning {
            running.append(transcriber)
        }
        return running
    }

    func setAvailable(_ engine: TranscriptionEngine, _ available: Bool) {
        state.withLock { $0.available[engine] = available }
    }

    func setMakeError(_ engine: TranscriptionEngine, _ error: (any Error)?) {
        state.withLock { $0.makeErrors[engine] = error }
    }

    func setStartError(_ engine: TranscriptionEngine, _ error: (any Error)?) {
        state.withLock { $0.startErrors[engine] = error }
    }

    func built(_ engine: TranscriptionEngine) -> [FakeRoutableTranscriber] {
        state.withLock { $0.built.filter { $0.engine == engine } }
    }

    /// The engine built last for `engine`.
    func latest(_ engine: TranscriptionEngine) -> FakeRoutableTranscriber? {
        built(engine).last
    }

    func provider(_ engine: TranscriptionEngine) -> TranscriberRouter.EngineProvider {
        TranscriberRouter.EngineProvider(
            isAvailable: { [self] in state.withLock { $0.available[engine] ?? false } },
            make: { [self] in
                let gate = state.withLock { state -> Gate? in
                    guard let gate = state.makeGates[engine] else { return nil }
                    state.blockedMakes[engine, default: 0] += 1
                    return gate
                }
                await gate?.wait()
                return try state.withLock { state in
                    if let error = state.makeErrors[engine] { throw error }
                    let transcriber = FakeRoutableTranscriber(
                        engine: engine, serial: state.built.count, startError: state.startErrors[engine])
                    state.built.append(transcriber)
                    return transcriber
                }
            }
        )
    }
}

enum FakeEngineError: Error, Equatable {
    case cannotLoad
    case cannotStart
}
