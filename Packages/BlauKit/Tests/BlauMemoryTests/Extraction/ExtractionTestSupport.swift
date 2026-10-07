import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

/// Fakes and fixtures for the fact extraction tests.
enum ExtractionTestSupport {
    /// 2026-10-08 12:00 UTC, so tests never read the wall clock.
    static let t0 = Date(timeIntervalSince1970: 1_791_460_800)

    static let utc = TimeZone(identifier: "UTC")!

    /// The JSON reply the model would give.
    static func reply(
        entities: [[String: Any]] = [],
        facts: [[String: Any]] = [],
        summary: String = ""
    ) -> String {
        let object: [String: Any] = ["entities": entities, "facts": facts, "summary": summary]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func entity(_ name: String, _ type: String, aliases: [String] = [], summary: String = "") -> [String: Any] {
        ["name": name, "type": type, "aliases": aliases, "summary": summary]
    }

    static func fact(
        _ subject: String, _ predicate: String, _ object: String, confidence: Double = 0.9, source: Int = 1,
        replaces: [String] = []
    ) -> [String: Any] {
        [
            "subject": subject, "predicate": predicate, "object": object, "confidence": confidence,
            "source": source, "replaces": replaces,
        ]
    }

    /// A pipeline utterance `offset` seconds after `t0`.
    static func utterance(
        _ text: String, speaker: Speaker = .user, at offset: TimeInterval, id: UUID = UUID(),
        conversation: ConversationID = ConversationID()
    ) -> Utterance {
        Utterance(
            id: id, conversationID: conversation, speaker: speaker, text: text,
            timeRange: TimeRange(start: .seconds(offset), duration: .seconds(2)),
            startedAt: t0.addingTimeInterval(offset),
            speakerDecision: speaker == .user ? .accept : nil)
    }
}

/// A `TextGenerator` that answers from an async closure, records requests,
/// and can be switched off.
final class ScriptedTextGenerator: TextGenerator {
    private let available: Mutex<Bool>
    private let handler: @Sendable (TextGenerationRequest, Int) async throws -> String
    private let recorded = Mutex<[TextGenerationRequest]>([])

    /// - Parameter handler: Gets the request and its 0-based call index.
    init(
        available: Bool = true,
        handler: @escaping @Sendable (TextGenerationRequest, Int) async throws -> String
    ) {
        self.available = Mutex(available)
        self.handler = handler
    }

    /// Answers every request with the next reply (the last one repeats).
    convenience init(replies: [String]) {
        self.init { _, index in replies[min(index, replies.count - 1)] }
    }

    var requests: [TextGenerationRequest] { recorded.withLock { $0 } }

    func setAvailable(_ value: Bool) { available.withLock { $0 = value } }

    func isAvailable() async -> Bool { available.withLock { $0 } }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        let index = recorded.withLock { requests in
            requests.append(request)
            return requests.count - 1
        }
        return try await handler(request, index)
    }
}

/// Holds a request until the test releases it.
final class Latch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    var waiterCount: Int { state.withLock { $0.waiters.count } }
}

/// A `TextEmbedder` with hand-picked vectors per name (lowercased); other
/// names get a vector of their own, orthogonal to the rest.
struct TableEmbedder: TextEmbedder {
    let modelIdentifier = "table-embedder@1"
    let table: [String: [Float]]

    func embed(_ text: String) async throws -> [Float] {
        if let vector = table[text.lowercased()] { return vector }
        var vector = [Float](repeating: 0, count: 8)
        let seed = text.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        vector[seed % 4 + 4] = 1
        return vector
    }
}

struct FakeGeneratorError: Error {}

/// A closed topic in a `ConversationStore` over an in-memory container.
struct TopicFixture {
    let container: ModelContainer
    let conversations: ConversationStore
    let facts: SwiftDataMemoryFactStore

    init() throws {
        container = try BlauModelContainer.makeInMemory()
        conversations = ConversationStore(modelContainer: container, savePolicy: .immediate)
        facts = SwiftDataMemoryFactStore(modelContainer: container)
    }

    /// Records `utterances` as one conversation with one topic, closed.
    ///
    /// - Returns: The topic's id.
    @discardableResult
    func recordTopic(_ utterances: [(Speaker, String, TimeInterval)], startingAt offset: TimeInterval = 0) async throws
        -> (topicID: UUID, utterances: [Utterance])
    {
        let conversation = ConversationID()
        let start = ExtractionTestSupport.t0.addingTimeInterval(offset)
        try await conversations.startConversation(id: conversation, at: start)
        let topicID = try await conversations.openTopic(at: start, title: "Work")
        var stored: [Utterance] = []
        for (speaker, text, at) in utterances {
            let utterance = ExtractionTestSupport.utterance(
                text, speaker: speaker, at: offset + at, conversation: conversation)
            try await conversations.commitUtterance(utterance)
            stored.append(utterance)
        }
        try await conversations.endConversation(conversation, at: start.addingTimeInterval(600))
        return (topicID, stored)
    }

    /// Every fact in the store, via a fresh context.
    func storedFacts() throws -> [Fact] {
        try ModelContext(container).fetch(FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.validFrom)]))
    }

    func storedEntities() throws -> [MemoryEntity] {
        try ModelContext(container).fetch(FetchDescriptor<MemoryEntity>(sortBy: [SortDescriptor(\.name)]))
    }
}

/// Polls `condition` for up to five seconds of real time.
func eventually(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<5_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
}
