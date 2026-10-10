import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

/// `ConversationStore.markEnded(utteranceID:reason:)`: the interrupted mark
/// on a stored agent reply (schema v3, #160).
@Suite("ConversationStore interrupted mark")
struct ConversationStoreEndReasonTests {
    @Test func markingAStoredReplyPersistsTheReason() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let reply = makeUtterance("The bridge opened in", in: conversation, at: 4, speaker: .agent)
        try await store.commitUtterance(reply)

        #expect(try await store.markEnded(utteranceID: reply.id, reason: .bargedIn))
        try await store.flush()

        let saved = try #require(try fixture.saved(StoredUtterance.self).first)
        #expect(saved.endReason == .bargedIn)
        #expect(saved.endReasonRaw == "bargedin")
        #expect(saved.isInterrupted)
    }

    @Test func unmarkedRowsAreNotInterrupted() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("Sure.", in: conversation, at: 4, speaker: .agent))
        try await store.flush()

        let saved = try #require(try fixture.saved(StoredUtterance.self).first)
        #expect(saved.endReasonRaw == nil)
        #expect(saved.endReason == nil)
        #expect(!saved.isInterrupted)
    }

    /// The server's corrected transcript of a cut reply re-commits it after
    /// the mark: the text changes, the mark stays.
    @Test func recommittingAMarkedReplyKeepsTheMark() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        var reply = makeUtterance("The Golden Gate Bridge", in: conversation, at: 4, speaker: .agent)
        try await store.commitUtterance(reply)
        try await store.markEnded(utteranceID: reply.id, reason: .interrupted)
        reply.text = "The Golden Gate"
        try await store.commitUtterance(reply)
        try await store.flush()

        let saved = try fixture.saved(StoredUtterance.self)
        #expect(saved.map(\.text) == ["The Golden Gate"])
        #expect(saved.map(\.endReason) == [.interrupted])
    }

    @Test func anUnknownUtteranceIsLeftAlone() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        try await store.startConversation()
        let before = await store.statistics.pendingChangeCount

        #expect(!(try await store.markEnded(utteranceID: UUID(), reason: .stopped)))
        #expect(await store.statistics.pendingChangeCount == before)
        #expect(try fixture.savedCount(StoredUtterance.self) == 0)
    }

    /// The mark lands on rows of other conversations too, and after a
    /// relaunch: the store looks the id up.
    @Test func aReplyInAnEndedConversationCanBeMarkedAfterARelaunch() async throws {
        let fixture = try StoreFixture()
        let conversation = try await fixture.store.startConversation(at: storeT0)
        let reply = makeUtterance("Let me think about", in: conversation, at: 4, speaker: .agent)
        try await fixture.store.commitUtterance(reply)
        try await fixture.store.endConversation(at: storeT0 + 60)

        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        #expect(try await relaunched.markEnded(utteranceID: reply.id, reason: .stopped))
        try await relaunched.flush()

        #expect(try fixture.saved(StoredUtterance.self).map(\.endReason) == [.stopped])
    }

    @Test func markingTwiceWithTheSameReasonChangesNothing() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let reply = makeUtterance("Well", in: conversation, at: 4, speaker: .agent)
        try await store.commitUtterance(reply)
        try await store.markEnded(utteranceID: reply.id, reason: .bargedIn)
        try await store.flush()
        let saves = await store.statistics.saveCount

        #expect(try await store.markEnded(utteranceID: reply.id, reason: .bargedIn))
        #expect(await store.statistics.pendingChangeCount == 0)
        try await store.flush()
        #expect(await store.statistics.saveCount == saves)

        // `nil` clears it.
        try await store.markEnded(utteranceID: reply.id, reason: nil)
        try await store.flush()
        #expect(try fixture.saved(StoredUtterance.self).map(\.endReasonRaw) == [nil])
    }

    /// A reason written by a newer app version reads as unknown, not as a
    /// crash or a wrong reason; the raw value is kept.
    @Test func anUnknownRawReasonReadsAsNoReason() throws {
        let reply = StoredUtterance(
            role: .agent, text: "Hm", startedAt: storeT0, isFinal: true, source: .grok, endReason: .stopped)
        #expect(reply.endReason == .stopped)
        reply.endReasonRaw = "droppedConnection"
        #expect(reply.endReason == nil)
        #expect(!reply.isInterrupted)
        #expect(reply.endReasonRaw == "droppedConnection")
    }

    @Test func theRawValuesArePinned() {
        // Stored and synced: renaming one would orphan every row holding it.
        #expect(UtteranceEndReason.allCases.map(\.rawValue) == ["interrupted", "bargedin", "stopped"])
    }
}
