import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauTopics
import Foundation
import Synchronization
import Testing

/// Offline re-segmentation as the lifecycle runs it when a conversation
/// finishes (#55): what it changes in the store, how it labels the topics
/// it changed, and what it never touches.
///
/// Two synthetic conversations (seeded, `SyntheticConversation`) where the
/// streaming topics are wrong on the fixture's 20-second exchanges:
///
/// | Seed | Reference | Streaming | Re-segmented |
/// | ---- | --------- | --------- | ------------ |
/// | 45 | 9, 17, 27, 36 | 9, 27, 36 (missed 17) | 9, 17, 27, 36 |
/// | 56 | 6, 18, 25, 32 | 6, 12, 18, 25, 32, 37 (two extra) | 6, 18, 25, 32 |
@Suite("Topic lifecycle re-segmentation")
struct TopicResegmentationLifecycleTests {
    static let missedChange = ScriptedTranscript(synthetic: 45)
    static let extraBreaks = ScriptedTranscript(synthetic: 56)

    static func play(_ fixture: LifecycleFixture) async throws {
        try await fixture.begin()
        try await fixture.play(0..<fixture.transcript.count)
        try await fixture.finish()
    }

    /// The topic starts the streaming segmenter alone stores.
    static func streamingStarts(_ transcript: ScriptedTranscript) async throws -> [Int] {
        let fixture = try LifecycleFixture(transcript, configuration: .init(resegmentation: nil))
        try await play(fixture)
        return try await fixture.topicStarts()
    }

    /// Every topic is titled over the exchanges it ended up with, and final.
    static func expectTitlesMatchTheTopics(_ fixture: LifecycleFixture) async throws {
        let topics = try await fixture.topics()
        let starts = try await fixture.topicStarts()
        for (index, topic) in topics.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : fixture.transcript.count
            #expect(topic.title == "Topic of \(end - starts[index]) Exchanges", "topic \(index)")
            #expect(topic.summary == "Covers \(end - starts[index]) exchanges.", "topic \(index)")
            #expect(!topic.titleIsProvisional)
            #expect(!topic.isOpen)
        }
    }

    // MARK: Splits

    @Test func aMissedChangeOfSubjectBecomesATopicWhenTheConversationEnds() async throws {
        let transcript = Self.missedChange
        #expect(try await Self.streamingStarts(transcript) == [0, 9, 27, 36])

        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<transcript.count)
        try await fixture.finish()

        #expect(try await fixture.topicStarts() == [0] + transcript.boundaries)
        // The topic that was split is titled again, though its title was
        // final; the new one is titled over its own exchanges.
        try await Self.expectTitlesMatchTheTopics(fixture)
        // The model was asked about the new boundary first.
        #expect(
            fixture.labeler.requests.contains {
                $0.kind == .boundary && $0.after.first?.userText == transcript.exchanges[17].user
            })
        // Opened once, closed once.
        let topics = try await fixture.topics()
        try await waitFor { log.closed.count == topics.count }
        #expect(Set(log.closed.map(\.id)) == Set(topics.map(\.id)))
        #expect(log.opened.contains { $0.id == topics[2].id })
    }

    @Test func aBoundaryTheModelVetoesIsNotAdded() async throws {
        let transcript = Self.missedChange
        let exchanges = transcript.exchanges.map(\.user)
        // Says no to a new topic anywhere between exchanges 9 and 27 (a
        // streaming candidate there included). Re-segmentation proposes 17
        // first, then, with 17 forbidden, the next best cut, and so on.
        let labeler = ScriptedLabeler { request in
            let position = request.after.first.flatMap { first in exchanges.firstIndex(of: first.userText) }
            let isNew = !(request.kind == .boundary && position.map { 9 < $0 && $0 < 27 } ?? false)
            return TopicShift(
                isNewTopic: isNew, title: "Topic of \(request.after.count) Exchanges",
                summary: "Covers \(request.after.count) exchanges.")
        }
        let fixture = try LifecycleFixture(transcript, labeler: labeler)
        try await fixture.begin()
        try await fixture.play(0..<transcript.count)
        let streamed = labeler.requests.count
        try await fixture.finish()
        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])
        let asked = labeler.requests[streamed...].filter { $0.kind == .boundary }.compactMap { request in
            request.after.first.flatMap { exchanges.firstIndex(of: $0.userText) }
        }
        #expect(asked.first == 17)
        #expect(asked.count > 1, "Only \(asked)")
        // Each position is asked about once, and the model is asked at most
        // `resegmentationQuestionLimit` times however often it says no.
        #expect(asked.count == Set(asked).count, "\(asked)")
        #expect(asked.count <= TopicLifecycle.resegmentationQuestionLimit, "\(asked)")
    }

    /// The engine's second merge pass can remove a streaming break because
    /// of a boundary it added (it is scored against it). Here the stream
    /// broke one topic at 8 and missed the change at 14; the engine moves
    /// the break to 10, adds 14, and then drops 10 as the same topic as the
    /// exchanges before it. If the model vetoes 14, the break must survive
    /// (moved to 10, the engine's result without 14), not vanish with it.
    @Test func aVetoedAdditionTakesNothingElseWithIt() async throws {
        let layout = IndexedTextEmbedder.Layout(topics: [(0, 14), (1, 8)], noise: 0.6, seed: 8)
        let embedder = IndexedTextEmbedder(layout)
        let transcript = layout.transcript
        let armed = Mutex(false)
        // Agrees with every streaming candidate; vetoes every boundary
        // re-segmentation proposes once `armed`.
        let labeler = ScriptedLabeler { request in
            let vetoes = request.kind == .boundary && armed.withLock { $0 }
            return TopicShift(
                isNewTopic: !vetoes, title: "Topic of \(request.after.count) Exchanges",
                summary: "Covers \(request.after.count) exchanges.")
        }
        func run(_ configuration: TopicLifecycle.Configuration, vetoing: Bool) async throws -> [Int] {
            armed.withLock { $0 = false }
            let fixture = try LifecycleFixture(
                transcript, labeler: labeler, configuration: configuration, embedder: embedder)
            try await fixture.begin()
            try await fixture.play(0..<transcript.count)
            armed.withLock { $0 = vetoing }
            try await fixture.finish()
            return try await fixture.topicStarts()
        }

        #expect(try await run(.init(resegmentation: nil), vetoing: false) == [0, 8])
        #expect(try await run(.standard, vetoing: false) == [0, 14])

        let before = labeler.requests.count
        let vetoed = try await run(.standard, vetoing: true)
        let asked = Set(
            labeler.requests[before...].filter { $0.kind == .boundary }
                .compactMap { $0.after.first.flatMap { IndexedTextEmbedder.index(in: $0.userText) } })
        #expect(asked.contains(14))
        // What the engine proposes with every position the model turned
        // down forbidden.
        let expected = TopicResegmenter().resegment(
            embeddings: layout.vectors, timeRanges: transcript.units().map(\.timeRange), boundaries: [8],
            forbidden: asked)
        #expect(expected.changes == [.moved(from: 8, to: 10)])
        #expect(vetoed == [0] + expected.boundaries)
        #expect(vetoed == [0, 10])
    }

    /// After each veto the engine proposes the next best cut, so a model
    /// that always says no is asked a bounded number of times, then nothing
    /// is added.
    @Test func aModelThatVetoesEverythingIsAskedABoundedNumberOfTimes() async throws {
        let layout = IndexedTextEmbedder.Layout(
            topics: (0..<6).map { (topic: $0, count: 8) }, noise: 0.3, seed: 3)
        let armed = Mutex(false)
        let labeler = ScriptedLabeler { request in
            TopicShift(
                isNewTopic: !(request.kind == .boundary && armed.withLock { $0 }),
                title: "Topic of \(request.after.count) Exchanges", summary: "Covers \(request.after.count) exchanges.")
        }
        // The streaming segmenter misses every change of subject.
        let fixture = try LifecycleFixture(
            layout.transcript, labeler: labeler, topicConfig: TopicConfig(minimumDepth: 100),
            embedder: IndexedTextEmbedder(layout))
        try await fixture.begin()
        try await fixture.play(0..<layout.transcript.count)
        #expect(try await fixture.topicStarts() == [0])
        let streamed = labeler.requests.count
        armed.withLock { $0 = true }
        try await fixture.finish()

        let asked = labeler.requests[streamed...].filter { $0.kind == .boundary }
        #expect(asked.count == TopicLifecycle.resegmentationQuestionLimit)
        #expect(try await fixture.topicStarts() == [0])
    }

    @Test func turningItOffKeepsTheStreamingTopics() async throws {
        let fixture = try LifecycleFixture(Self.missedChange, configuration: .init(resegmentation: nil))
        try await Self.play(fixture)
        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])
    }

    // MARK: Merges

    @Test func breaksInsideOneTopicAreMergedAwayAndTheTopicRetitled() async throws {
        let transcript = Self.extraBreaks
        #expect(try await Self.streamingStarts(transcript) == [0, 6, 12, 18, 25, 32, 37])

        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        let log = LifecycleEventLog(fixture.lifecycle)
        try await fixture.play(0..<transcript.count)
        let streamed = try await fixture.topics()
        try await fixture.finish()

        #expect(try await fixture.topicStarts() == [0] + transcript.boundaries)
        try await Self.expectTitlesMatchTheTopics(fixture)
        // The topics that started at exchanges 12 and 37 were merged into
        // the ones before them.
        let removed = Set(streamed.map(\.id)).subtracting(try await fixture.topics().map(\.id))
        #expect(removed.count == 2)
        try await waitFor { Set(log.removed).isSuperset(of: removed) }
        // A topic that had closed and was merged into is revised
        // (`.updated`), never closed twice.
        let closed = log.closed.map(\.id)
        #expect(closed.count == Set(closed).count)
    }

    // MARK: What the user owns

    @Test func aRenamedTopicIsNeverSplit() async throws {
        let transcript = Self.missedChange
        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        try await fixture.play(0..<transcript.count)
        let topic = try #require(try await fixture.topics().dropFirst().first)
        try await fixture.lifecycle.rename(topic.id, to: "Everything")
        try await fixture.finish()

        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])
        #expect(try await fixture.topicSnapshot(topic.id).title == "Everything")
    }

    @Test func aTopicRenamedOutsideTheLifecycleIsNeverSplit() async throws {
        // A rename that reaches the store some other way (another device).
        let transcript = Self.missedChange
        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        try await fixture.play(0..<transcript.count)
        let topic = try #require(try await fixture.topics().dropFirst().first)
        try await fixture.store.renameTopic(topic.id, to: "From My iPad")
        try await fixture.finish()

        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])
        #expect(try await fixture.topicSnapshot(topic.id).title == "From My iPad")
    }

    /// `rename` isn't queued behind the lifecycle, so the user can rename
    /// the topic re-segmentation is about to split while the model is still
    /// being asked about the new boundary. The rename wins: the topic keeps
    /// its edges and its title.
    @Test(arguments: [false, true])
    func aTopicRenamedWhileTheModelIsAskedIsNotSplit(fromAnotherDevice: Bool) async throws {
        let transcript = Self.missedChange
        let target = transcript.exchanges[17].user
        let armed = Mutex(false)
        let gate = Gate()
        let labeler = ScriptedLabeler { request in
            if request.kind == .boundary, request.after.first?.userText == target, armed.withLock({ $0 }) {
                await gate.wait()
            }
            return switch request.kind {
            case .boundary: TopicShift(isNewTopic: true, title: "Boundary Guess", summary: "A new subject.")
            case .topic:
                TopicShift(
                    isNewTopic: true, title: "Topic of \(request.after.count) Exchanges",
                    summary: "Covers \(request.after.count) exchanges.")
            }
        }
        let fixture = try LifecycleFixture(transcript, labeler: labeler)
        try await fixture.begin()
        try await fixture.play(0..<transcript.count)
        let topic = try #require(try await fixture.topics().dropFirst().first)
        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])

        armed.withLock { $0 = true }
        let finishing = Task { try await fixture.finish() }
        await gate.waitForWaiter()
        if fromAnotherDevice {
            try await fixture.store.renameTopic(topic.id, to: "Everything")
        } else {
            try await fixture.lifecycle.rename(topic.id, to: "Everything")
        }
        gate.open()
        try await finishing.value

        #expect(try await fixture.topicStarts() == [0, 9, 27, 36])
        let renamed = try await fixture.topicSnapshot(topic.id)
        #expect(renamed.title == "Everything")
        #expect(renamed.startedAt == topic.startedAt)
        #expect(renamed.endedAt == topic.endedAt)
    }

    @Test func aTopicTheUserSplitKeepsItsEdges() async throws {
        let transcript = Self.missedChange
        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        try await fixture.play(0..<30)
        let topic = try #require(try await fixture.topics().dropFirst().first)
        // The user splits at exchange 20, not where the subject changes;
        // both parts are theirs.
        _ = try await fixture.lifecycle.split(topic.id, atUtterance: fixture.users[20].id)
        await fixture.lifecycle.waitUntilIdle()
        try await fixture.play(30..<transcript.count)
        try await fixture.finish()
        #expect(try await fixture.topicStarts() == [0, 9, 20, 27, 36])
    }

    @Test func breaksNextToRenamedTopicsStay() async throws {
        let transcript = Self.extraBreaks
        let fixture = try LifecycleFixture(transcript)
        try await fixture.begin()
        try await fixture.play(0..<transcript.count)
        for topic in try await fixture.topics() {
            try await fixture.lifecycle.rename(topic.id, to: "Mine \(topic.ordinal)")
        }
        let before = try await fixture.topics()
        try await fixture.finish()
        let after = try await fixture.topics()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.title) == before.map(\.title))
        #expect(after.map(\.startedAt) == before.map(\.startedAt))
    }

    /// After a relaunch the segmenter only has the exchanges since; the
    /// topic carried over from before is left alone. (The relaunched
    /// segmenter raises no candidates, so every change of subject after the
    /// relaunch would be re-segmentation's to find.)
    @Test func aResumedConversationsOpenTopicIsLeftAlone() async throws {
        let blind = TopicConfig(minimumDepth: 100)
        func run(resegmentation: TopicResegmenter.Configuration?) async throws -> (before: [Int], after: [Int]) {
            let transcript = Self.missedChange
            let fixture = try LifecycleFixture(transcript)
            try await fixture.begin()
            try await fixture.play(0..<12)
            let before = try await fixture.topicStarts()
            let relaunched = TopicLifecycle(
                store: fixture.store, labeling: .test([fixture.labeler]),
                configuration: .init(exchangeSettleDelay: nil, resegmentation: resegmentation), clock: fixture.clock
            ) {
                StreamingTopicSegmenter(embedder: LexicalTextEmbedder(), config: blind, signposter: .disabled(.topics))
            }
            await relaunched.beginConversation(fixture.conversation, at: fixture.origin)
            for index in 12..<transcript.count {
                try await fixture.store.commitUtterance(fixture.users[index])
                await relaunched.ingest(fixture.users[index])
                try await fixture.store.commitUtterance(fixture.agents[index])
                await relaunched.ingest(fixture.agents[index])
            }
            try await fixture.store.endConversation(
                fixture.conversation, at: fixture.origin.addingTimeInterval(Double(transcript.count) * 20))
            await relaunched.finishConversation(fixture.conversation)
            await relaunched.waitUntilIdle()
            return (before, try await fixture.topicStarts())
        }
        let resegmented = try await run(resegmentation: .standard)
        #expect(resegmented.after == resegmented.before)
        let streaming = try await run(resegmentation: nil)
        #expect(streaming.after == streaming.before)
    }

    // MARK: The fixture set, end to end

    /// The acceptance criterion through the whole lifecycle and store: the
    /// stored topics' Pk improves with re-segmentation and no conversation
    /// gets worse. By default the scripted transcripts and synthetic
    /// conversations 41–60; `BLAU_FULL_RESEGMENTATION_EVAL=1` runs all 60
    /// (measured: mean Pk 0.0279 → 0.0095 over 65 conversations, 10 better,
    /// none worse).
    @Test func pkOfTheStoredTopicsImprovesOnTheFixtureSet() async throws {
        let full = ProcessInfo.processInfo.environment["BLAU_FULL_RESEGMENTATION_EVAL"] == "1"
        let seeds: ClosedRange<UInt64> = full ? 1...60 : 41...60
        let transcripts = ScriptedTranscript.all + seeds.map { ScriptedTranscript(synthetic: $0) }
        var streamingPk = 0.0
        var resegmentedPk = 0.0
        var improved = 0
        var worse: [String] = []
        for transcript in transcripts {
            func pk(_ starts: [Int]) -> Double {
                SegmentationMetrics.pk(
                    reference: transcript.boundaries, hypothesis: Array(starts.dropFirst()), count: transcript.count)
            }
            let before = pk(try await Self.streamingStarts(transcript))
            let fixture = try LifecycleFixture(transcript)
            try await Self.play(fixture)
            let after = pk(try await fixture.topicStarts())
            streamingPk += before
            resegmentedPk += after
            if after > before + 1e-12 { worse.append(transcript.name) }
            if after < before - 1e-12 { improved += 1 }
        }
        streamingPk /= Double(transcripts.count)
        resegmentedPk /= Double(transcripts.count)
        if ProcessInfo.processInfo.environment["BLAU_PRINT_RESEGMENTATION"] == "1" {
            print(
                "Lifecycle, \(transcripts.count) conversations: Pk \(streamingPk) → \(resegmentedPk), better \(improved)"
            )
        }
        #expect(resegmentedPk <= 0.6 * streamingPk, "Pk \(streamingPk) → \(resegmentedPk)")
        #expect(improved >= 3)
        #expect(worse.isEmpty, "Worse: \(worse)")
    }
}

extension ScriptedTranscript {
    /// A synthetic conversation as a scripted transcript, for the
    /// lifecycle fixture (which puts every exchange 20 s apart).
    init(synthetic seed: UInt64) {
        let conversation = SyntheticConversation.generate(seed: seed)
        self.init(
            name: "synthetic \(seed)",
            exchanges: conversation.units.map { Exchange(user: $0.userText, agent: $0.agentText) },
            boundaries: conversation.boundaries,
            digression: conversation.digressions.first)
    }
}

extension LifecycleFixture {
    func topicSnapshot(_ id: UUID) async throws -> TopicSnapshot {
        try await store.topicSnapshot(id)
    }
}

/// Embeds exchange `#i` (the first `#` and number in the text) as the
/// `i`-th vector of a seeded `TopicVectors` layout, so a lifecycle test can
/// play a conversation with exact embeddings.
struct IndexedTextEmbedder: TextEmbedder {
    struct Layout: Sendable {
        let vectors: [[Float]]
        let reference: [Int]

        /// `topics`: (topic, exchanges) runs, in order.
        init(topics: [(topic: Int, count: Int)], noise: Float, seed: UInt64) {
            var generator = TopicVectors(noise: noise, seed: seed)
            vectors = topics.flatMap { Array(repeating: $0.topic, count: $0.count) }.map { generator.vector($0) }
            var reference: [Int] = []
            var start = 0
            for run in topics.dropLast() {
                start += run.count
                reference.append(start)
            }
            self.reference = reference
        }

        var transcript: ScriptedTranscript {
            ScriptedTranscript(
                name: "indexed",
                exchanges: vectors.indices.map {
                    ScriptedTranscript.Exchange(user: "Exchange #\($0).", agent: "Reply.")
                },
                boundaries: reference)
        }
    }

    let vectors: [[Float]]

    init(_ layout: Layout) {
        vectors = layout.vectors
    }

    var modelIdentifier: String { "indexed-test" }

    func embed(_ text: String) async throws -> [Float] {
        guard let index = Self.index(in: text), vectors.indices.contains(index) else {
            return [Float](repeating: 0, count: vectors.first?.count ?? 1)
        }
        return vectors[index]
    }

    static func index(in text: String) -> Int? {
        guard let range = text.range(of: "#[0-9]+", options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst())
    }
}
