import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauTopics
import Foundation
import SwiftData
import Testing

@Suite("Topic lifecycle")
struct TopicLifecycleTests {
    // MARK: Opening

    /// Acceptance: a new topic appears within about two exchanges of a real
    /// switch. "Appears" means the switch's first exchange is stored in a
    /// different topic from the previous topic's first exchange; the lag is
    /// how many more exchanges were scored before that was true.
    @Test(arguments: ScriptedTranscript.all)
    func aNewTopicAppearsWithinTwoExchangesOfASwitch(_ transcript: ScriptedTranscript) async throws {
        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        let starts = [0] + transcript.boundaries
        var appearedAfter: [Int: Int] = [:]
        try await fixture.play(0..<transcript.count) { index in
            for (position, boundary) in transcript.boundaries.enumerated()
            where boundary <= index && appearedAfter[boundary] == nil {
                let previousStart = starts[position]
                let switched = try await fixture.topicOfExchange(boundary)
                let before = try await fixture.topicOfExchange(previousStart)
                if switched != nil, switched != before {
                    appearedAfter[boundary] = index
                }
            }
        }
        try await fixture.finish()

        for boundary in transcript.boundaries {
            let appeared = try #require(appearedAfter[boundary], "No topic for the switch at exchange \(boundary)")
            #expect(appeared - boundary <= 2, "The switch at exchange \(boundary) appeared after exchange \(appeared)")
        }
        // Once confirmed, every boundary sits where the transcript changes
        // subject, and the digression was taken back.
        #expect(try await fixture.topicStarts() == starts)
        let topics = try await fixture.topics()
        #expect(topics.allSatisfy { !$0.titleIsProvisional && $0.summary != nil && !$0.isOpen })
    }

    @Test func theFirstTopicOpensWithTheConversationAndIsTitledAfterThreeExchanges() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        let opened = try await fixture.topics()
        #expect(opened.count == 1)
        #expect(opened.first?.hasPlaceholderTitle == true)
        #expect(opened.first?.startedAt == fixture.origin)
        #expect(await fixture.lifecycle.currentTopicID == opened.first?.id)

        try await fixture.play(0..<2)
        #expect(try await fixture.topics().first?.hasPlaceholderTitle == true)

        try await fixture.play(2..<3)
        let titled = try #require(try await fixture.topics().first)
        #expect(titled.title == "Topic of 3 Exchanges")
        #expect(titled.titleIsProvisional)
        #expect(titled.summary == "Covers 3 exchanges.")
    }

    @Test func aProvisionalTopicCarriesTheModelsTitleUntilItIsRefined() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<8)

        let topics = try await fixture.topics()
        #expect(topics.count == 2)
        #expect(topics[1].title == "Boundary Guess")
        #expect(topics[1].titleIsProvisional)
        #expect(topics[1].isOpen)
        #expect(log.opened.contains { $0.id == topics[1].id })
        // The first topic is only refined once the boundary is confirmed.
        #expect(topics[0].titleIsProvisional)
    }

    // MARK: Closing

    @Test func aClosedTopicIsRefinedOverAllItsExchanges() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<ScriptedTranscript.threeTopics.count)
        try await fixture.finish()

        let topics = try await fixture.topics()
        #expect(topics.map(\.title) == Array(repeating: "Topic of 6 Exchanges", count: 3))
        #expect(topics.map(\.summary) == Array(repeating: "Covers 6 exchanges.", count: 3))
        #expect(topics.allSatisfy { !$0.titleIsProvisional })
        // Each closed topic was labeled once over its six exchanges.
        #expect(fixture.labeler.topicRequestSizes.filter { $0 == 6 }.count == 3)
        // Continuity and memory hear about each topic as it closes.
        try await waitFor { log.closed.count == 3 }
        #expect(log.closed.map(\.id) == topics.map(\.id))
        #expect(log.closed.allSatisfy { $0.summary == "Covers 6 exchanges." })
    }

    @Test func theFinalTopicsAreSavedWhenTheConversationFinishes() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<6)
        try await fixture.finish()

        // A fresh context only sees what was saved.
        let saved = try ModelContext(fixture.store.modelContainer).fetch(FetchDescriptor<Topic>())
        #expect(saved.map(\.title) == ["Topic of 6 Exchanges"])
        #expect(saved.map(\.titleIsProvisional) == [false])
        #expect(saved.map(\.summary) == ["Covers 6 exchanges."])
    }

    @Test func anEmptyConversationLeavesNoTopicBehind() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.finish()
        #expect(try await fixture.topics().isEmpty)
    }

    @Test func utterancesThatArriveAfterTheFinishDontReopenTopics() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<5)
        try await fixture.finish()
        let before = try await fixture.topics()

        try await fixture.record(fixture.users[5])
        await fixture.lifecycle.waitUntilIdle()
        let after = try await fixture.topics()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.title) == before.map(\.title))
        #expect(await fixture.lifecycle.conversationID == nil)
    }

    // MARK: Taking back

    @Test func aDigressionsProvisionalTopicIsTakenBack() async throws {
        let fixture = try LifecycleFixture(.briefDigression)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        var counts: [Int] = []
        try await fixture.play(0..<10) { _ in counts.append(try await fixture.topics().count) }

        // A provisional topic opened at the digression and was merged back.
        #expect(counts.contains(2))
        #expect(counts.last == 1)
        try await waitFor { !log.removed.isEmpty }
        let topics = try await fixture.topics()
        #expect(try await fixture.topicOfExchange(6) == topics.first?.id)
    }

    @Test func aRenamedProvisionalTopicIsKeptWhenTheSegmenterTakesItBack() async throws {
        let fixture = try LifecycleFixture(.briefDigression)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<8)
        let before = try await fixture.topics()
        #expect(before.count == 2)
        let first = try #require(before.first)
        let digression = try #require(before.last)
        #expect(digression.titleIsProvisional)

        // Naming the provisional topic accepts the break: the segmenter's
        // take-back must neither delete it nor move its title.
        try await fixture.lifecycle.rename(digression.id, to: "My Digression")
        try await fixture.play(8..<ScriptedTranscript.briefDigression.count)
        try await fixture.finish()

        let topics = try await fixture.topics()
        #expect(Array(topics.prefix(2).map(\.id)) == [first.id, digression.id])
        #expect(topics.first?.title == "Topic of 6 Exchanges")
        #expect(topics.first?.titleIsProvisional == false)
        #expect(topics.dropFirst().first?.title == "My Digression")
        #expect(topics.dropFirst().first?.titleIsProvisional == false)
        #expect(!log.removed.contains(digression.id))
        // The topic the break closed was still refined.
        try await waitFor { log.closed.contains { $0.id == first.id } }
    }

    @Test func renamingBothSidesOfAProvisionalBreakKeepsBothTitles() async throws {
        let fixture = try LifecycleFixture(.briefDigression)
        try await fixture.begin()
        try await fixture.play(0..<8)
        let before = try await fixture.topics()
        #expect(before.count == 2)
        try await fixture.lifecycle.rename(before[0].id, to: "YC Prep")
        try await fixture.lifecycle.rename(before[1].id, to: "My Digression")

        try await fixture.play(8..<ScriptedTranscript.briefDigression.count)
        try await fixture.finish()

        let topics = try await fixture.topics()
        #expect(Array(topics.prefix(2).map(\.id)) == before.map(\.id))
        #expect(Array(topics.prefix(2).map(\.title)) == ["YC Prep", "My Digression"])
    }

    @Test func aVetoedCandidateNeverOpensATopic() async throws {
        let fixture = try LifecycleFixture(.threeTopics, labeler: .lifecycle(confirms: false))
        try await fixture.begin()
        var counts: [Int] = []
        try await fixture.play(0..<18) { _ in counts.append(try await fixture.topics().count) }
        #expect(counts.allSatisfy { $0 == 1 })
    }

    @Test func withoutCandidateTopicsTheTopicWaitsForConfirmation() async throws {
        let fixture = try LifecycleFixture(
            .threeTopics, configuration: .init(opensTopicsAtCandidates: false))
        try await fixture.begin()
        try await fixture.play(0..<ScriptedTranscript.threeTopics.count)
        try await fixture.finish()
        #expect(try await fixture.topicStarts() == [0, 6, 12])
    }

    // MARK: Manual edits

    @Test func aManualTitleSurvivesRefinementOnClose() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<4)
        let first = try #require(try await fixture.topics().first)
        try await fixture.lifecycle.rename(first.id, to: "Bread Notes")

        try await fixture.play(4..<18)
        try await fixture.finish()
        let topics = try await fixture.topics()
        #expect(topics.first?.title == "Bread Notes")
        #expect(topics.first?.titleIsProvisional == false)
        // The summary is still refined.
        #expect(topics.first?.summary == "Covers 6 exchanges.")
    }

    @Test func aRenamedProvisionalTopicKeepsItsTitleWhenConfirmed() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<8)
        let provisional = try #require(try await fixture.topics().last)
        #expect(provisional.titleIsProvisional)
        try await fixture.lifecycle.rename(provisional.id, to: "Running")

        try await fixture.play(8..<18)
        try await fixture.finish()
        let topics = try await fixture.topics()
        #expect(topics.map(\.title) == ["Topic of 6 Exchanges", "Running", "Topic of 6 Exchanges"])
    }

    @Test func mergingAProvisionalTopicAwayIgnoresItsConfirmation() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<8)
        let topics = try await fixture.topics()
        #expect(topics.count == 2)

        let survivor = try await fixture.lifecycle.mergeWithPrevious(topics[1].id)
        #expect(survivor == topics[0].id)
        #expect(await fixture.lifecycle.currentTopicID == survivor)
        // The segmenter confirms that boundary after exchange 10; it stays
        // merged.
        try await fixture.play(8..<12)
        #expect(try await fixture.topics().count == 1)

        try await fixture.play(12..<18)
        try await fixture.finish()
        #expect(try await fixture.topicStarts() == [0, 12])
    }

    @Test func splittingTheCurrentTopicStartsANewTopicThere() async throws {
        let fixture = try LifecycleFixture(.singleTopic)
        try await fixture.begin()
        try await fixture.play(0..<6)
        let topic = try #require(try await fixture.topics().first)

        let newID = try await fixture.lifecycle.split(topic.id, atUtterance: fixture.users[3].id)
        #expect(await fixture.lifecycle.currentTopicID == newID)
        await fixture.lifecycle.waitUntilIdle()
        let split = try await fixture.topics()
        #expect(split.map(\.id) == [topic.id, newID])
        #expect(split[1].title == "Topic of 3 Exchanges")
        #expect(split[1].titleIsProvisional)
        #expect(split[0].title == "Topic of 3 Exchanges")
        #expect(!split[0].titleIsProvisional)

        try await fixture.play(6..<ScriptedTranscript.singleTopic.count)
        try await fixture.finish()
        #expect(try await fixture.topicStarts() == [0, 3])
        #expect(try await fixture.topicOfExchange(13) == newID)
    }

    @Test func splittingAtTheFirstUtteranceOrOutsideTheTopicIsRefused() async throws {
        let fixture = try LifecycleFixture(.singleTopic)
        try await fixture.begin()
        try await fixture.play(0..<3)
        let topic = try #require(try await fixture.topics().first)
        await #expect(throws: TopicLifecycle.EditError.splitAtFirstUtterance) {
            try await fixture.lifecycle.split(topic.id, atUtterance: fixture.users[0].id)
        }
        let unknown = UUID()
        await #expect(throws: TopicLifecycle.EditError.utteranceNotInTopic(unknown)) {
            try await fixture.lifecycle.split(topic.id, atUtterance: unknown)
        }
    }

    @Test func mergingAFinishedTopicRefinesTheMergedTopic() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<ScriptedTranscript.threeTopics.count)
        try await fixture.finish()
        let topics = try await fixture.topics()

        let survivor = try await fixture.lifecycle.mergeWithPrevious(topics[1].id)
        await fixture.lifecycle.waitUntilIdle()
        #expect(survivor == topics[0].id)
        let merged = try await fixture.topics()
        #expect(merged.map(\.id) == [topics[0].id, topics[2].id])
        // The title was final, so it stays; the summary covers both parts.
        #expect(merged[0].title == "Topic of 6 Exchanges")
        #expect(merged[0].summary == "Covers 12 exchanges.")
    }

    /// Continuity and memory hear `.closed` once per topic; a later edit to
    /// a closed topic arrives as `.updated` with its revised final label.
    @Test func editingAClosedTopicReportsARevisionNotASecondClose() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<ScriptedTranscript.threeTopics.count)
        try await fixture.finish()
        try await waitFor { log.closed.count == 3 }
        let topics = try await fixture.topics()

        let survivor = try await fixture.lifecycle.mergeWithPrevious(topics[1].id)
        await fixture.lifecycle.waitUntilIdle()
        try await waitFor {
            log.updated.contains { $0.id == survivor && $0.summary == "Covers 12 exchanges." }
        }
        #expect(log.removed.contains(topics[1].id))
        #expect(log.closed.count == 3)
        let revised = try #require(log.updated.last { $0.id == survivor })
        #expect(!revised.isOpen)
        #expect(!revised.titleIsProvisional)
    }

    @Test func splittingTheOpenTopicClosesItsFirstPart() async throws {
        let fixture = try LifecycleFixture(.singleTopic)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<6)
        let topic = try #require(try await fixture.topics().first)
        #expect(topic.isOpen)

        let newID = try await fixture.lifecycle.split(topic.id, atUtterance: fixture.users[3].id)
        await fixture.lifecycle.waitUntilIdle()
        try await waitFor { log.closed.contains { $0.id == topic.id } }
        #expect(!log.closed.contains { $0.id == newID })
        #expect(log.opened.contains { $0.id == newID })
    }

    @Test func renamingTheCurrentTopicBeforeItIsTitledSkipsItsProvisionalTitle() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<2)
        let current = try #require(await fixture.lifecycle.currentTopicID)

        try await fixture.lifecycle.rename(current, to: "Bread Notes")
        // Saved at once, before the queued pipeline update runs.
        let renamed = try #require(try await fixture.topics().first { $0.id == current })
        #expect(renamed.title == "Bread Notes")
        #expect(!renamed.titleIsProvisional)
        await fixture.lifecycle.waitUntilIdle()
        // The topic isn't given a provisional title after three exchanges.
        try await fixture.play(2..<5)
        #expect(fixture.labeler.topicRequestSizes.isEmpty)
        #expect(try await fixture.topics().first { $0.id == current }?.title == "Bread Notes")
    }

    @Test func renamingAnUnknownTopicThrows() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        let unknown = UUID()
        await #expect(throws: ConversationStoreError.topicNotFound(unknown)) {
            try await fixture.lifecycle.rename(unknown, to: "Anything")
        }
    }

    // MARK: Resuming

    @Test func aResumedConversationContinuesItsOpenTopic() async throws {
        let fixture = try LifecycleFixture(.threeTopics)
        try await fixture.begin()
        try await fixture.play(0..<3)
        let open = try #require(try await fixture.topics().first)

        // A relaunch: a new lifecycle over the same store.
        let relaunched = TopicLifecycle(
            store: fixture.store, labeling: .test([fixture.labeler]), clock: fixture.clock
        ) {
            StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), signposter: .disabled(.topics))
        }
        await relaunched.beginConversation(fixture.conversation, at: fixture.origin.addingTimeInterval(70))
        await relaunched.waitUntilIdle()
        #expect(await relaunched.currentTopicID == open.id)
        #expect(try await fixture.topics().count == 1)
    }

}
