import BlauAudio
import BlauCore
import Foundation
import Synchronization

@testable import BlauTranscription

/// A `Transcriber` whose events the test sends by hand.
final class ControlledTranscriber: Transcriber {
    let events: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let log = Mutex<[String]>([])

    init() {
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
    }

    /// What was called on it, in order.
    var calls: [String] { log.withLock { $0 } }

    func send(_ event: TranscriptEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func start() async throws {
        log.withLock { $0.append("start") }
    }

    func stop() async {
        log.withLock { $0.append("stop") }
    }

    func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        log.withLock { $0.append("phase \(transition)") }
    }
}

/// A second-pass recognizer that answers from a list and can be held, to
/// stand in for a slow model.
actor ScriptedSecondPassRecognizer: SecondPassRecognizer {
    enum Response: Sendable {
        case text(String)
        case failure
    }

    struct Failure: Error {}

    private var responses: [Response]
    private let fallback: (@Sendable ([Float]) -> String)?
    private var isHeld: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var received: [[Float]] = []
    private(set) var completed = 0

    /// - Parameters:
    ///   - responses: Answers, one per call, in order.
    ///   - held: Whether calls wait for `release()`.
    ///   - fallback: Answers once `responses` runs out.
    init(_ responses: [Response] = [], held: Bool = false, fallback: (@Sendable ([Float]) -> String)? = nil) {
        self.responses = responses
        self.isHeld = held
        self.fallback = fallback
    }

    var callCount: Int { received.count }

    func transcribe(_ samples: [Float]) async throws -> SecondPassTranscript {
        received.append(samples)
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        defer { completed += 1 }
        let response = responses.isEmpty ? .text(fallback?(samples) ?? "") : responses.removeFirst()
        switch response {
        case .text(let text): return SecondPassTranscript(text: text, confidence: 0.9)
        case .failure: throw Failure()
        }
    }

    /// Lets every waiting and future call through.
    func release() {
        isHeld = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Counts provider calls and answers from a list of steps, repeating the
/// last one.
final class CountingProvider: Sendable {
    enum Step: Sendable {
        case notInstalled
        case failure
        case recognizer(any SecondPassRecognizer)
    }

    struct LoadFailure: Error {}

    private let state: Mutex<(steps: [Step], calls: Int)>
    private let last: Step

    init(_ steps: [Step]) {
        precondition(!steps.isEmpty)
        state = Mutex((steps, 0))
        last = steps.last!
    }

    var calls: Int { state.withLock { $0.calls } }

    var provider: SecondPassRecognizerProvider {
        { [self] in
            let step = state.withLock { state in
                state.calls += 1
                return state.steps.isEmpty ? last : state.steps.removeFirst()
            }
            switch step {
            case .notInstalled: return nil
            case .failure: throw LoadFailure()
            case .recognizer(let recognizer): return recognizer
            }
        }
    }
}

/// A user utterance over `[start, end)` (16 kHz sample offsets).
func utterance(_ text: String, samples range: Range<Int64>, id: UUID = UUID()) -> Utterance {
    Utterance(
        id: id,
        conversationID: ConversationID(),
        speaker: .user,
        text: text,
        timeRange: TimeRange(
            start: .samples(range.lowerBound, sampleRate: 16_000), end: .samples(range.upperBound, sampleRate: 16_000)),
        startedAt: Date(timeIntervalSince1970: 1_000)
    )
}

/// Audio whose every sample is its own stream offset, so a test can tell
/// exactly which span was read.
func indexedAudio(seconds: Int) -> FixtureAudioSource {
    let source = FixtureAudioSource(block: (0..<(seconds * 16_000)).map(Float.init))
    source.position = Int64(seconds * 16_000)
    return source
}

/// Collects a stream's events as they come, so a test can look at them
/// before the stream finishes.
final class EventLog: Sendable {
    private final class Box: Sendable {
        let events = Mutex<[TranscriptEvent]>([])
    }

    private let box: Box
    private let task: Task<Void, Never>

    init(_ events: AsyncStream<TranscriptEvent>) {
        let box = Box()
        self.box = box
        task = Task {
            for await event in events {
                box.events.withLock { $0.append(event) }
            }
        }
    }

    var events: [TranscriptEvent] { box.events.withLock { $0 } }

    var finals: [Utterance] {
        events.compactMap { if case .final(let utterance) = $0 { utterance } else { nil } }
    }

    var refined: [Utterance] {
        events.compactMap { if case .refined(let utterance) = $0 { utterance } else { nil } }
    }

    /// Waits for the stream to finish.
    func finished() async {
        await task.value
    }
}
