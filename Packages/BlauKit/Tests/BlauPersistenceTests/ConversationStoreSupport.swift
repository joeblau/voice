import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

/// A fixed reference date so tests never read the wall clock.
let storeT0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A store over a fresh in-memory container, driven by a manual clock.
struct StoreFixture {
    let container: ModelContainer
    let clock: ManualClock
    let signposts: RecordingSignpostBackend
    let store: ConversationStore

    init(policy: ConversationStoreSavePolicy = .coalesced) throws {
        container = try BlauModelContainer.makeInMemory()
        clock = ManualClock(now: storeT0)
        signposts = RecordingSignpostBackend()
        store = ConversationStore(
            modelContainer: container,
            savePolicy: policy,
            clock: clock,
            signposter: Signposter(category: .data, backend: signposts)
        )
    }

    /// A fresh context on the same container: sees only what the store saved.
    func savedCount<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    func saved<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    /// Moves the clock past the coalescing interval and waits for the
    /// deferred save to finish.
    func fireDeferredSave(expectingSaveCount count: Int) async throws {
        await clock.waitForSleepers()
        clock.advance(by: store.savePolicy.interval)
        try await waitUntil { await store.statistics.saveCount >= count }
    }
}

/// Polls `condition` for up to five seconds of real time.
func waitUntil(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<5_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
}

/// A committed user utterance `offset` seconds after `storeT0`.
func makeUtterance(
    _ text: String,
    in conversation: ConversationID,
    at offset: TimeInterval,
    speaker: Speaker = .user,
    id: UUID = UUID(),
    duration: Duration = .seconds(2)
) -> BlauCore.Utterance {
    BlauCore.Utterance(
        id: id,
        conversationID: conversation,
        speaker: speaker,
        text: text,
        timeRange: TimeRange(start: .seconds(offset), duration: duration),
        startedAt: storeT0.addingTimeInterval(offset),
        speakerDecision: speaker == .user ? .accept : nil
    )
}
