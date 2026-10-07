import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

/// A fixed reference date so tests never read the wall clock.
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func makeContext() throws -> ModelContext {
    ModelContext(try BlauModelContainer.makeInMemory())
}

private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
    try context.fetchCount(FetchDescriptor<T>())
}

@Suite("SchemaV1 create, fetch and delete")
struct SchemaV1CRUDTests {
    @Test func createsAndFetchesAConversationWithTopicsAndUtterances() throws {
        let context = try makeContext()
        let conversation = Conversation(startedAt: t0, title: "Morning")
        context.insert(conversation)
        let first = Topic(conversation: conversation, startedAt: t0, ordinal: 0)
        let second = Topic(
            conversation: conversation, startedAt: t0 + 120, title: "Fundraising", titleIsProvisional: false,
            summary: "- Seed round timing", ordinal: 1)
        context.insert(first)
        context.insert(second)
        let question = StoredUtterance(
            conversation: conversation, topic: second, role: .user, text: "When should we raise?",
            startedAt: t0 + 121, endedAt: t0 + 123, asrConfidence: 0.92, voiceScore: 0.71, isFinal: true,
            source: .parakeet)
        let answer = StoredUtterance(
            conversation: conversation, topic: second, role: .agent, text: "After you hit your milestones.",
            startedAt: t0 + 124, isFinal: true, source: .grok)
        context.insert(answer)
        context.insert(question)
        try context.save()

        let fetchContext = ModelContext(context.container)
        let conversations = try fetchContext.fetch(FetchDescriptor<Conversation>())
        let fetched = try #require(conversations.first)
        #expect(conversations.count == 1)
        #expect(fetched.id == conversation.id)
        #expect(fetched.title == "Morning")
        #expect(fetched.startedAt == t0)
        #expect(fetched.isOpen)
        #expect(fetched.orderedTopics.map(\.title) == [Topic.placeholderTitle, "Fundraising"])
        #expect(fetched.orderedUtterances.map(\.text) == ["When should we raise?", "After you hit your milestones."])

        let topic = try #require(fetched.orderedTopics.last)
        #expect(topic.titleIsProvisional == false)
        #expect(topic.summary == "- Seed round timing")
        #expect(topic.conversation?.id == conversation.id)
        #expect(topic.orderedUtterances.map(\.role) == [.user, .agent])

        let user = try #require(topic.orderedUtterances.first)
        #expect(user.source == .parakeet)
        #expect(user.endedAt == t0 + 123)
        #expect(user.asrConfidence == 0.92)
        #expect(user.voiceScore == 0.71)
        #expect(user.isFinal)
        #expect(user.conversation?.id == conversation.id)
        #expect(user.topic?.id == topic.id)
    }

    @Test func fetchesWithPredicatesAndSortsOnStoredFields() throws {
        let context = try makeContext()
        let conversation = Conversation(startedAt: t0)
        context.insert(conversation)
        for (offset, role) in [UtteranceRole.user, .agent, .user, .system].enumerated() {
            context.insert(
                StoredUtterance(
                    conversation: conversation, role: role, text: "line \(offset)",
                    startedAt: t0 + Double(offset), isFinal: offset < 3, source: role == .agent ? .grok : .parakeet))
        }
        try context.save()

        let userRaw = UtteranceRole.user.rawValue
        let descriptor = FetchDescriptor<StoredUtterance>(
            predicate: #Predicate { $0.roleRaw == userRaw && $0.isFinal },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        #expect(try context.fetch(descriptor).map(\.text) == ["line 2", "line 0"])
    }

    @Test func updatesPersist() throws {
        let context = try makeContext()
        let topic = Topic(startedAt: t0)
        context.insert(topic)
        try context.save()

        topic.title = "Hiring plan"
        topic.titleIsProvisional = false
        topic.endedAt = t0 + 300
        try context.save()

        let fetched = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Topic>()).first)
        #expect(fetched.title == "Hiring plan")
        #expect(!fetched.titleIsProvisional)
        #expect(!fetched.isOpen)
    }

    @Test func deletingAConversationCascadesToTopicsAndUtterances() throws {
        let context = try makeContext()
        let kept = Conversation(startedAt: t0)
        let deleted = Conversation(startedAt: t0 + 3600)
        context.insert(kept)
        context.insert(deleted)
        for conversation in [kept, deleted] {
            let topic = Topic(conversation: conversation, startedAt: conversation.startedAt)
            context.insert(topic)
            context.insert(
                StoredUtterance(
                    conversation: conversation, topic: topic, role: .user, text: "hi",
                    startedAt: conversation.startedAt, isFinal: true, source: .parakeet))
        }
        try context.save()
        #expect(try count(Topic.self, in: context) == 2)
        #expect(try count(StoredUtterance.self, in: context) == 2)

        context.delete(deleted)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Conversation>()).map(\.id) == [kept.id])
        #expect(try count(Topic.self, in: context) == 1)
        #expect(try count(StoredUtterance.self, in: context) == 1)
        #expect(try context.fetch(FetchDescriptor<StoredUtterance>()).first?.conversation?.id == kept.id)
    }

    @Test func deletingATopicKeepsItsUtterances() throws {
        let context = try makeContext()
        let conversation = Conversation(startedAt: t0)
        context.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: t0)
        context.insert(topic)
        let utterance = StoredUtterance(
            conversation: conversation, topic: topic, role: .user, text: "keep me", startedAt: t0, isFinal: true,
            source: .speechAnalyzer)
        context.insert(utterance)
        try context.save()

        context.delete(topic)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<StoredUtterance>())
        #expect(remaining.map(\.text) == ["keep me"])
        #expect(remaining.first?.topic == nil)
        #expect(remaining.first?.conversation?.id == conversation.id)
        #expect(try count(Conversation.self, in: context) == 1)
        #expect(try count(Topic.self, in: context) == 0)
    }

    @Test func deletingAnUtteranceLeavesItsConversationAndTopic() throws {
        let context = try makeContext()
        let conversation = Conversation(startedAt: t0)
        context.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: t0)
        context.insert(topic)
        let utterance = StoredUtterance(
            conversation: conversation, topic: topic, role: .agent, text: "bye", startedAt: t0, isFinal: true,
            source: .grok)
        context.insert(utterance)
        try context.save()

        context.delete(utterance)
        try context.save()

        #expect(try count(StoredUtterance.self, in: context) == 0)
        #expect(try count(Conversation.self, in: context) == 1)
        #expect(try count(Topic.self, in: context) == 1)
        #expect(conversation.utterances?.isEmpty == true)
        #expect(topic.utterances?.isEmpty == true)
    }

    @Test func voiceProfileRoundTripsAndCascadesToEnrollmentSets() throws {
        let context = try makeContext()
        let centroid = (0..<VoiceEnrollmentSet.defaultDimension).map { Float($0) / 256 }
        let profile = VoiceProfile(
            name: "Me", embeddingModelVersion: "wespeaker-resnet34-lm-v1", centroid: centroid, createdAt: t0)
        context.insert(profile)
        let clips = (0..<3).map { clip in
            (0..<VoiceEnrollmentSet.defaultDimension).map { Float(clip) - Float($0) * 0.5 }
        }
        let set = VoiceEnrollmentSet(profile: profile, deviceModel: "iPhone18,1", embeddings: clips, createdAt: t0)
        context.insert(set)
        try context.save()

        let fetched = try #require(try ModelContext(context.container).fetch(FetchDescriptor<VoiceProfile>()).first)
        #expect(fetched.name == "Me")
        #expect(fetched.updatedAt == t0)
        #expect(fetched.centroid.count == 256 * 4)
        #expect(fetched.centroidVector == centroid)
        let fetchedSet = try #require(fetched.enrollmentSets?.first)
        #expect(fetchedSet.clipCount == 3)
        #expect(fetchedSet.deviceModel == "iPhone18,1")
        #expect(fetchedSet.embeddings.count == 3 * 256 * 4)
        #expect(fetchedSet.embeddingVectors == clips)

        profile.updateCentroid([1, 2, 3], at: t0 + 60)
        #expect(profile.centroidVector == [1, 2, 3])
        #expect(profile.updatedAt == t0 + 60)

        context.delete(profile)
        try context.save()
        #expect(try count(VoiceProfile.self, in: context) == 0)
        #expect(try count(VoiceEnrollmentSet.self, in: context) == 0)
    }
}

@Suite("SchemaV1 model behavior")
struct SchemaV1ModelTests {
    @Test func defaultsMatchTheSchemaContract() {
        let topic = Topic(startedAt: t0)
        #expect(topic.title == "New topic")
        #expect(topic.titleIsProvisional)
        #expect(topic.summary == nil)
        #expect(topic.ordinal == 0)
        #expect(topic.isOpen)
        #expect(topic.utterances?.isEmpty == true)

        let conversation = Conversation(startedAt: t0)
        #expect(conversation.topics?.isEmpty == true)
        #expect(conversation.utterances?.isEmpty == true)
        #expect(conversation.title == nil)
    }

    @Test func colorSeedIsDerivedFromTheIDAndStable() throws {
        let id = try #require(UUID(uuidString: "AB12F7A3-2B44-4C09-9E58-1F2D3C4B5A69"))
        #expect(Topic(id: id, startedAt: t0).colorSeed == 0xAB12)
        #expect(Topic(id: id, startedAt: t0).colorSeed == Topic.colorSeed(for: id))
        #expect(Topic(id: id, startedAt: t0, colorSeed: 7).colorSeed == 7)
        #expect((0..<65_536).contains(Topic(startedAt: t0).colorSeed))
    }

    @Test(arguments: UtteranceRole.allCases)
    func rolesRoundTripThroughTheirRawValue(role: UtteranceRole) {
        let utterance = StoredUtterance(role: role, text: "", startedAt: t0, isFinal: false, source: .parakeet)
        #expect(utterance.roleRaw == role.rawValue)
        #expect(utterance.role == role)
    }

    @Test func rawValuesMatchTheDocumentedStrings() {
        #expect(UtteranceRole.allCases.map(\.rawValue) == ["user", "agent", "system"])
        #expect(TranscriptSource.allCases.map(\.rawValue) == ["parakeet", "speechanalyzer", "grok"])
    }

    @Test func unknownRawValuesFromNewerVersionsReadAsNil() {
        let utterance = StoredUtterance(role: .user, text: "", startedAt: t0, isFinal: true, source: .grok)
        utterance.roleRaw = "tool"
        utterance.sourceRaw = "whisper"
        #expect(utterance.role == nil)
        #expect(utterance.source == nil)
    }

    @Test func rolesMapToAndFromPipelineSpeakers() {
        #expect(UtteranceRole(Speaker.user) == .user)
        #expect(UtteranceRole(Speaker.agent) == .agent)
        #expect(UtteranceRole.user.speaker == .user)
        #expect(UtteranceRole.agent.speaker == .agent)
        #expect(UtteranceRole.system.speaker == nil)
    }

    @Test func storesAPipelineUtterance() {
        let conversation = Conversation(startedAt: t0)
        let value = BlauCore.Utterance(
            conversationID: ConversationID(rawValue: conversation.id),
            speaker: .user,
            text: "Let's talk about hiring.",
            timeRange: TimeRange(start: .seconds(10), duration: .milliseconds(2_500)),
            startedAt: t0 + 10,
            speakerDecision: .accept
        )
        let stored = StoredUtterance(value, source: .parakeet, conversation: conversation, voiceScore: 0.68)
        #expect(stored.id == value.id)
        #expect(stored.role == .user)
        #expect(stored.text == value.text)
        #expect(stored.startedAt == t0 + 10)
        #expect(stored.endedAt == t0 + 12.5)
        #expect(stored.isFinal)
        #expect(stored.source == .parakeet)
        #expect(stored.voiceScore == 0.68)
        #expect(stored.conversation === conversation)
    }

    @Test func malformedEnrollmentDataReadsAsNil() {
        let set = VoiceEnrollmentSet(deviceModel: "Mac", embeddings: [[1, 2], [3, 4]], createdAt: t0)
        #expect(set.embeddingVectors == [[1, 2], [3, 4]])
        set.clipCount = 3
        #expect(set.embeddingVectors == nil)
        set.embeddings = Data([1, 2, 3])
        set.clipCount = 1
        #expect(set.embeddingVectors == nil)

        let empty = VoiceEnrollmentSet(deviceModel: "Mac", embeddings: [], createdAt: t0)
        #expect(empty.clipCount == 0)
        #expect(empty.embeddingVectors == [])
    }
}
