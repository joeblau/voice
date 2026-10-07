import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

/// The topic lifecycle's store calls (#54): splits, boundary moves, merges,
/// labels that respect manual titles, and renames.
@Suite("ConversationStore topic lifecycle")
struct ConversationStoreTopicEditTests {
    /// A conversation with one open topic and utterances at `offsets`.
    private func conversation(
        _ fixture: StoreFixture, utterancesAt offsets: [TimeInterval]
    ) async throws -> (ConversationID, UUID, [UUID]) {
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        let topic = try await store.openTopic(at: storeT0)
        var ids: [UUID] = []
        for offset in offsets {
            let utterance = makeUtterance("at \(Int(offset))", in: id, at: offset)
            try await store.commitUtterance(utterance)
            ids.append(utterance.id)
        }
        return (id, topic, ids)
    }

    private func topicIDs(of fixture: StoreFixture) throws -> [UUID?] {
        try #require(try fixture.saved(Conversation.self).first).orderedUtterances.map(\.topic?.id)
    }

    // MARK: Split

    @Test func splittingMovesLaterUtterancesAndTheCurrentTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9, 12])

        let second = try await store.splitTopic(first, at: storeT0 + 9, title: "Next")
        #expect(await store.openTopicID == second)
        try await store.commitUtterance(makeUtterance("later", in: id, at: 20))
        try await store.flush()

        #expect(try topicIDs(of: fixture) == [first, first, second, second, second])
        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.map(\.id) == [first, second])
        #expect(topics.map(\.ordinal) == [0, 1])
        #expect(topics[0].endedAt == storeT0 + 9)
        #expect(topics[1].isOpen)
        #expect(topics[1].title == "Next")
        #expect(topics[1].titleIsProvisional)
    }

    @Test func splittingAMiddleTopicKeepsTheOrderAndTheEnd() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9, 25])
        let third = try await store.openTopic(at: storeT0 + 20)

        let second = try await store.splitTopic(first, at: storeT0 + 5)
        try await store.flush()

        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.map(\.id) == [first, second, third])
        #expect(topics.map(\.ordinal) == [0, 1, 2])
        #expect(topics[1].endedAt == storeT0 + 20)
        #expect(try topicIDs(of: fixture) == [first, second, second, third])
        #expect(await store.openTopicID == third)
    }

    @Test func splittingOutsideTheTopicThrows() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5])
        let second = try await store.openTopic(at: storeT0 + 10)
        await #expect(throws: ConversationStoreError.invalidTopicBoundary(first)) {
            try await store.splitTopic(first, at: storeT0)
        }
        await #expect(throws: ConversationStoreError.invalidTopicBoundary(first)) {
            try await store.splitTopic(first, at: storeT0 + 10)
        }
        await #expect(throws: ConversationStoreError.invalidTopicBoundary(second)) {
            try await store.splitTopic(second, at: storeT0 + 2)
        }
    }

    /// Labeling lags behind the conversation, so a boundary can land after
    /// the conversation ended.
    @Test func aTopicOfAnEndedConversationCanBeSplit() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9])
        try await store.endConversation(at: storeT0 + 30)

        let second = try await store.splitTopic(first, at: storeT0 + 5)
        try await store.commitUtterance(makeUtterance("late agent transcript", in: id, at: 31, speaker: .agent))
        try await store.flush()

        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.map(\.endedAt) == [storeT0 + 5, storeT0 + 30])
        #expect(try topicIDs(of: fixture) == [first, second, second, second])
    }

    @Test func openingATopicInAnEndedConversationSplitsTheTopicCoveringIt() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1, 9])
        try await store.endConversation(at: storeT0 + 30)

        let second = try await store.openTopic(in: id, at: storeT0 + 9)
        try await store.flush()
        #expect(second != first)
        #expect(try topicIDs(of: fixture) == [first, second])
    }

    @Test func openingTheFirstTopicOfAnEndedConversationAdoptsItsUtterances() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        try await store.commitUtterance(makeUtterance("hello", in: id, at: 1))
        try await store.endConversation(at: storeT0 + 10)
        try await store.commitUtterance(makeUtterance("late", in: id, at: 11, speaker: .agent))

        let topic = try await store.openTopic(in: id, at: storeT0)
        try await store.flush()

        let saved = try #require(try fixture.saved(Topic.self).first)
        #expect(saved.id == topic)
        #expect(saved.endedAt == storeT0 + 10)
        #expect(try topicIDs(of: fixture) == [topic, topic])
    }

    @Test func openingATopicInTheActiveConversationIsOpenTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1, 9])
        let second = try await store.openTopic(in: id, at: storeT0 + 9)
        #expect(await store.openTopicID == second)
        try await store.flush()
        #expect(try topicIDs(of: fixture) == [first, second])
    }

    // MARK: Move

    @Test func movingATopicStartEarlierTakesUtterancesFromThePreviousTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9, 12])
        let second = try await store.openTopic(at: storeT0 + 12)

        try await store.moveTopicStart(second, to: storeT0 + 5)
        try await store.flush()
        #expect(try topicIDs(of: fixture) == [first, second, second, second])
        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics[0].endedAt == storeT0 + 5)
        #expect(topics[1].startedAt == storeT0 + 5)
    }

    @Test func movingATopicStartLaterGivesUtterancesBack() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9, 12])
        let second = try await store.openTopic(at: storeT0 + 5)

        try await store.moveTopicStart(second, to: storeT0 + 12)
        try await store.flush()
        #expect(try topicIDs(of: fixture) == [first, first, first, second])
    }

    @Test func movingTheFirstTopicOrOutsideTheSpanThrows() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5])
        let second = try await store.openTopic(at: storeT0 + 5)
        await #expect(throws: ConversationStoreError.noPreviousTopic(first)) {
            try await store.moveTopicStart(first, to: storeT0 + 1)
        }
        await #expect(throws: ConversationStoreError.invalidTopicBoundary(second)) {
            try await store.moveTopicStart(second, to: storeT0)
        }
    }

    // MARK: Merge

    @Test func mergingGivesThePreviousTopicTheUtterancesAndTheCurrentPosition() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9])
        let second = try await store.openTopic(at: storeT0 + 5)

        let survivor = try await store.mergeTopicWithPrevious(second)
        #expect(survivor == first)
        #expect(await store.openTopicID == first)
        try await store.commitUtterance(makeUtterance("after the merge", in: id, at: 20))
        try await store.flush()

        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.map(\.id) == [first])
        #expect(topics[0].isOpen)
        #expect(try topicIDs(of: fixture) == [first, first, first, first])
        #expect(try fixture.savedCount(Topic.self) == 1)
    }

    @Test func mergingAMiddleTopicRenumbersTheRest() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5, 9])
        let second = try await store.openTopic(at: storeT0 + 5)
        let third = try await store.openTopic(at: storeT0 + 9)

        try await store.mergeTopicWithPrevious(second)
        try await store.flush()
        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.map(\.id) == [first, third])
        #expect(topics.map(\.ordinal) == [0, 1])
        #expect(topics[0].endedAt == storeT0 + 9)
        #expect(await store.openTopicID == third)
    }

    @Test func mergingKeepsAManualTitle() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1, 5])
        let second = try await store.openTopic(at: storeT0 + 5)
        try await store.renameTopic(second, to: "Fundraising")

        try await store.mergeTopicWithPrevious(second)
        let merged = try await store.topicSnapshot(first)
        #expect(merged.title == "Fundraising")
        #expect(!merged.titleIsProvisional)
    }

    @Test func theFirstTopicCantBeMerged() async throws {
        let fixture = try StoreFixture()
        let (_, first, _) = try await conversation(fixture, utterancesAt: [1])
        await #expect(throws: ConversationStoreError.noPreviousTopic(first)) {
            try await fixture.store.mergeTopicWithPrevious(first)
        }
    }

    @Test func onlyEmptyTopicsAreRemoved() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (id, first, _) = try await conversation(fixture, utterancesAt: [1])
        #expect(try await store.removeTopicIfEmpty(first) == false)

        let empty = try await store.openTopic(at: storeT0 + 10)
        #expect(try await store.removeTopicIfEmpty(empty))
        #expect(await store.openTopicID == nil)
        try await store.flush()
        #expect(try await store.topicSnapshots(in: id).map(\.id) == [first])
    }

    // MARK: Titles

    @Test func labelsNeverOverwriteAManualTitle() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, topic, _) = try await conversation(fixture, utterancesAt: [1])

        #expect(try await store.applyTopicLabel(topic, title: "First Guess", summary: "One.", finalizesTitle: false))
        #expect(try await store.topicSnapshot(topic).titleIsProvisional)

        try await store.renameTopic(topic, to: "  My Title  ")
        let applied = try await store.applyTopicLabel(
            topic, title: "Refined Title", summary: "The whole topic.", finalizesTitle: true)
        #expect(!applied)

        let snapshot = try await store.topicSnapshot(topic)
        #expect(snapshot.title == "My Title")
        #expect(!snapshot.titleIsProvisional)
        #expect(snapshot.summary == "The whole topic.")
    }

    @Test func aRefinedTitleIsFinal() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let (_, topic, _) = try await conversation(fixture, utterancesAt: [1])
        #expect(try await store.applyTopicLabel(topic, title: "Refined", summary: nil, finalizesTitle: true))
        #expect(!(try await store.applyTopicLabel(topic, title: "Again", summary: nil, finalizesTitle: true)))
        #expect(try await store.topicSnapshot(topic).title == "Refined")
    }

    @Test func anEmptyRenameThrows() async throws {
        let fixture = try StoreFixture()
        let (_, topic, _) = try await conversation(fixture, utterancesAt: [1])
        await #expect(throws: ConversationStoreError.emptyTitle) {
            try await fixture.store.renameTopic(topic, to: "  \n")
        }
    }

    /// A rename is saved at once, without waiting for the coalescing timer,
    /// and survives a relaunch of an on-disk store (the same store CloudKit
    /// mirrors from).
    @Test func aRenameIsSavedAtOnceAndSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "blau-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Blau.store")

        let topicID: UUID
        do {
            let container = try BlauModelContainer.makeLocal(url: url)
            let store = ConversationStore(modelContainer: container, clock: ManualClock(now: storeT0))
            try await store.startConversation(at: storeT0)
            topicID = try await store.openTopic(at: storeT0)
            try await store.renameTopic(topicID, to: "Seed Round")
            // No flush: the rename saved itself.
            let saved = try ModelContext(container).fetch(FetchDescriptor<Topic>())
            #expect(saved.first?.title == "Seed Round")
        }

        let relaunched = try BlauModelContainer.makeLocal(url: url)
        let saved = try #require(try ModelContext(relaunched).fetch(FetchDescriptor<Topic>()).first)
        #expect(saved.id == topicID)
        #expect(saved.title == "Seed Round")
        #expect(saved.titleIsProvisional == false)
    }

    // MARK: Reading

    @Test func topicUtterancesComeBackInOrderOnTheConversationTimeline() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        let topic = try await store.openTopic(at: storeT0)
        let agent = makeUtterance("reply", in: id, at: 8, speaker: .agent)
        let user = makeUtterance("question", in: id, at: 3)
        try await store.commitUtterance(agent)
        try await store.commitUtterance(user)

        let utterances = try await store.topicUtterances(topic)
        #expect(utterances.map(\.id) == [user.id, agent.id])
        #expect(utterances.map(\.speaker) == [.user, .agent])
        #expect(utterances.map(\.conversationID) == [id, id])
        #expect(utterances[0].timeRange == TimeRange(start: .seconds(3), duration: .seconds(2)))
        #expect(utterances[1].startedAt == storeT0 + 8)

        let snapshot = try await store.topicSnapshot(topic)
        #expect(snapshot.utteranceCount == 2)
        #expect(snapshot.conversationID == id)
        #expect(snapshot.hasPlaceholderTitle)
        #expect(snapshot.meaningfulTitle == nil)
    }
}
