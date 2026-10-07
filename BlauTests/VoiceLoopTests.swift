import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app-side pieces of the voice loop (#36). The orchestrator itself is
/// covered by `swift test` in BlauKit.
@Suite("Voice loop")
@MainActor
struct VoiceLoopTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func utterance(_ text: String, _ speaker: Speaker, in conversation: ConversationID, at offset: Double)
        -> BlauCore.Utterance
    {
        BlauCore.Utterance(
            conversationID: conversation, speaker: speaker, text: text,
            timeRange: TimeRange(start: .seconds(offset), duration: .seconds(1)),
            startedAt: Self.t0.addingTimeInterval(offset))
    }

    /// The recorder writes both roles into the store the persistence
    /// controller has open.
    @Test func theRecorderWritesBothRolesIntoTheOpenStore() async throws {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        try await recorder.record(utterance("How are you?", .user, in: conversation, at: 0))
        try await recorder.record(utterance("Doing well.", .agent, in: conversation, at: 2))
        try await recorder.finishConversation(conversation, at: Self.t0.addingTimeInterval(5))

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
        #expect(stored.id == conversation.rawValue)
        #expect(stored.endedAt != nil)
        #expect(stored.orderedUtterances.map(\.role) == [.user, .agent])
        #expect(stored.orderedUtterances.map(\.text) == ["How are you?", "Doing well."])
    }

    /// When the container is replaced mid-conversation (an iCloud account
    /// change), the conversation is reopened in the new store.
    @Test func aReplacedContainerGetsTheConversationReopened() async throws {
        let first = try BlauModelContainer.makeInMemory()
        let second = try BlauModelContainer.makeInMemory()
        let current = CurrentContainer(first)
        let recorder = PersistenceTranscriptRecorder { current.value }
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        try await recorder.record(utterance("Before", .user, in: conversation, at: 0))
        current.value = second
        try await recorder.record(utterance("After", .agent, in: conversation, at: 2))
        try await recorder.flush()

        let before = try ModelContext(first).fetch(FetchDescriptor<StoredUtterance>())
        let after = try ModelContext(second).fetch(FetchDescriptor<StoredUtterance>())
        #expect(before.map(\.text) == ["Before"])
        #expect(after.map(\.text) == ["After"])
        #expect(after.first?.conversation?.id == conversation.rawValue)
    }

    /// The transcript and the topic lifecycle (#54) can both ask for the
    /// store right after the container is replaced; they get the same one,
    /// with the conversation reopened, so neither write is dropped.
    @Test func callersAfterAContainerSwapShareOneStore() async throws {
        let first = try BlauModelContainer.makeInMemory()
        let second = try BlauModelContainer.makeInMemory()
        let current = CurrentContainer(first)
        let recorder = PersistenceTranscriptRecorder { current.value }
        let conversation = ConversationID()

        try await recorder.beginConversation(conversation, at: Self.t0)
        current.value = second
        async let one = recorder.conversationStore()
        async let two = recorder.conversationStore()
        let (storeOne, storeTwo) = try await (one, two)
        #expect(storeOne === storeTwo)
        #expect(storeOne.modelContainer === second)

        try await recorder.record(utterance("After", .agent, in: conversation, at: 2))
        try await recorder.flush()
        let after = try ModelContext(second).fetch(FetchDescriptor<StoredUtterance>())
        #expect(after.map(\.text) == ["After"])
        #expect(after.first?.conversation?.id == conversation.rawValue)
    }

    @Test func noOpenStoreIsAnError() async {
        let recorder = PersistenceTranscriptRecorder { nil }
        await #expect(throws: PersistenceTranscriptRecorder.StoreUnavailableError.self) {
            try await recorder.beginConversation(ConversationID(), at: Self.t0)
        }
    }

    @Test func theHUDRowsFollowTheSnapshot() {
        let loop = VoiceLoop(
            realtime: FakeRealtimeService(), speechModels: SpeechModels.fixtureManager(),
            performance: FixedPerformanceLevel())
        #expect(!loop.isAvailable)
        #expect(loop.hudReadout.value(for: "EOU → audio") == "–")
        #expect(
            loop.hudReadout.rows.map(\.label) == [
                "Turn", "Realtime", "Session", "EOU → audio", "Turn time", "Tokens", "Barge-in",
            ])
    }
}

/// The container a test's recorder sees; swapped to simulate an iCloud
/// account change.
@MainActor
private final class CurrentContainer {
    var value: ModelContainer?

    init(_ value: ModelContainer?) {
        self.value = value
    }
}
