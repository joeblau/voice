import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauTopics
import Foundation
import Synchronization
import Testing

/// A scripted transcript played into a `TopicLifecycle` the way the app
/// does it: each utterance is committed to a `ConversationStore`, then fed
/// to the lifecycle; each agent reply settles after a second on a manual
/// clock.
///
/// Exchange `i` is a user utterance at `20i` s (8 s long) and the agent's
/// reply at `20i + 10` s (8 s long), from the transcript's origin.
struct LifecycleFixture {
    let transcript: ScriptedTranscript
    let store: ConversationStore
    let clock: ManualClock
    let labeler: ScriptedLabeler
    let lifecycle: TopicLifecycle
    let conversation = ConversationID()
    let users: [Utterance]
    let agents: [Utterance]
    let origin: Date

    init(
        _ transcript: ScriptedTranscript,
        labeler: ScriptedLabeler = .lifecycle(),
        configuration: TopicLifecycle.Configuration = .standard
    ) throws {
        self.transcript = transcript
        self.labeler = labeler
        let container = try BlauModelContainer.makeInMemory()
        // The store's save timer runs on a clock of its own that never moves;
        // the tests read through the store, which sees unsaved changes.
        store = ConversationStore(modelContainer: container, clock: ManualClock())
        clock = ManualClock()
        let labeling = TopicLabelingService.test([labeler])
        lifecycle = TopicLifecycle(store: store, labeling: labeling, configuration: configuration, clock: clock) {
            StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics))
        }
        let units = transcript.units()
        origin = units.first?.startedAt ?? Date(timeIntervalSinceReferenceDate: 800_000_000)
        let conversation = conversation
        let origin = origin
        func utterance(_ speaker: Speaker, _ text: String, at offset: Double) -> Utterance {
            Utterance(
                conversationID: conversation, speaker: speaker, text: text,
                timeRange: TimeRange(start: .seconds(offset), duration: .seconds(8)),
                startedAt: origin.addingTimeInterval(offset),
                speakerDecision: speaker == .user ? .accept : nil)
        }
        users = transcript.exchanges.indices.map {
            utterance(.user, transcript.exchanges[$0].user, at: Double($0) * 20)
        }
        agents = transcript.exchanges.indices.map {
            utterance(.agent, transcript.exchanges[$0].agent, at: Double($0) * 20 + 10)
        }
    }

    /// Starts the conversation in the store and the lifecycle.
    func begin() async throws {
        try await store.startConversation(id: conversation, at: origin)
        await lifecycle.beginConversation(conversation, at: origin)
        await lifecycle.waitUntilIdle()
    }

    /// Plays exchanges `range`, calling `after` once each has been scored.
    func play(_ range: Range<Int>, after: (Int) async throws -> Void = { _ in }) async throws {
        for index in range {
            try await record(users[index])
            try await record(agents[index])
            await lifecycle.waitUntilIdle()
            await clock.waitForSleepers()
            clock.advance(by: .seconds(1))
            try await waitFor { await lifecycle.exchangeCount == index + 1 }
            await lifecycle.waitUntilIdle()
            try await after(index)
        }
    }

    /// Commits `utterance` to the store, then feeds it to the lifecycle.
    func record(_ utterance: Utterance) async throws {
        try await store.commitUtterance(utterance)
        await lifecycle.ingest(utterance)
    }

    /// Ends the conversation in the store and the lifecycle.
    func finish() async throws {
        try await store.endConversation(conversation, at: origin.addingTimeInterval(Double(transcript.count) * 20))
        await lifecycle.finishConversation(conversation)
        await lifecycle.waitUntilIdle()
    }

    func topics() async throws -> [TopicSnapshot] {
        try await store.topicSnapshots(in: conversation)
    }

    /// The topic each exchange's user utterance belongs to.
    func topicOfExchange(_ index: Int) async throws -> UUID? {
        let topics = try await topics()
        for topic in topics
        where try await store.topicUtterances(topic.id).contains(where: { $0.id == users[index].id }) {
            return topic.id
        }
        return nil
    }

    /// The first exchange of each stored topic.
    func topicStarts() async throws -> [Int] {
        try await topics().compactMap { topic in
            users.firstIndex { $0.startedAt >= topic.startedAt }
        }
    }
}

extension ScriptedLabeler {
    /// Agrees with every candidate. A boundary title names the new topic's
    /// first exchange; a topic title and summary count its exchanges.
    static func lifecycle(confirms: Bool = true) -> ScriptedLabeler {
        ScriptedLabeler { request in
            switch request.kind {
            case .boundary:
                TopicShift(
                    isNewTopic: confirms, title: "Boundary Guess", summary: "A new subject starts here.")
            case .topic:
                TopicShift(
                    isNewTopic: true, title: "Topic of \(request.after.count) Exchanges",
                    summary: "Covers \(request.after.count) exchanges.")
            }
        }
    }

    /// The `.topic` requests, by how many exchanges they covered.
    var topicRequestSizes: [Int] {
        requests.filter { $0.kind == .topic }.map(\.after.count)
    }
}

/// Collects a lifecycle's events.
final class LifecycleEventLog: Sendable {
    private let events = Mutex<[TopicLifecycleEvent]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ lifecycle: TopicLifecycle) {
        let stream = lifecycle.events()
        task.withLock {
            $0 = Task { [weak self] in
                for await event in stream {
                    self?.events.withLock { $0.append(event) }
                }
            }
        }
    }

    var all: [TopicLifecycleEvent] { events.withLock { $0 } }

    var removed: [UUID] {
        all.compactMap { if case .removed(let id) = $0 { id } else { nil } }
    }

    var closed: [TopicSnapshot] {
        all.compactMap { if case .closed(let snapshot) = $0 { snapshot } else { nil } }
    }

    var opened: [TopicSnapshot] {
        all.compactMap { if case .opened(let snapshot) = $0 { snapshot } else { nil } }
    }

    deinit {
        task.withLock { $0?.cancel() }
    }
}

/// Polls `condition` for up to five seconds of real time.
func waitFor(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<5_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
}
