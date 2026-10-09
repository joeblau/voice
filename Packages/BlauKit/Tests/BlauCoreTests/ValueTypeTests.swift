import BlauCore
import Foundation
import Testing

@Suite("BlauCore module")
struct BlauCoreModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauCoreModule.name == "BlauCore")
    }

    @Test func hasASummary() {
        #expect(!BlauCoreModule.summary.isEmpty)
    }
}

@Suite("ConversationID")
struct ConversationIDTests {
    @Test func newIdentifiersAreUnique() {
        #expect(ConversationID() != ConversationID())
    }

    @Test func parsesItsOwnUUIDString() throws {
        let id = ConversationID()
        let parsed = try #require(ConversationID(uuidString: id.uuidString))
        #expect(parsed == id)
        #expect(id.description == id.uuidString)
    }

    @Test func rejectsStringsThatAreNotUUIDs() {
        #expect(ConversationID(uuidString: "not-a-uuid") == nil)
        #expect(ConversationID(uuidString: "") == nil)
    }

    @Test func encodesAsABareUUIDString() throws {
        let uuid = try #require(UUID(uuidString: "6E1F7A3C-2B44-4C09-9E58-1F2D3C4B5A69"))
        let data = try JSONEncoder().encode(ConversationID(rawValue: uuid))
        #expect(String(decoding: data, as: UTF8.self) == "\"6E1F7A3C-2B44-4C09-9E58-1F2D3C4B5A69\"")
        #expect(try JSONDecoder().decode(ConversationID.self, from: data).rawValue == uuid)
    }
}

@Suite("Speaker and SpeakerDecision")
struct SpeakerTests {
    @Test func rawValuesAreStableForStorage() {
        #expect(Speaker.allCases.map(\.rawValue) == ["user", "agent"])
        #expect(SpeakerDecision.allCases.map(\.rawValue) == ["accept", "reject", "uncertain"])
    }

    @Test func onlyRejectedSpeechIsKeptFromGrok() {
        #expect(!SpeakerDecision.accept.isRejected)
        #expect(SpeakerDecision.reject.isRejected)
        #expect(!SpeakerDecision.uncertain.isRejected)
    }
}

@Suite("Utterance")
struct UtteranceTests {
    private func makeUtterance(
        speaker: Speaker = .user,
        text: String = "Hello there.",
        decision: SpeakerDecision? = .accept
    ) -> Utterance {
        Utterance(
            conversationID: ConversationID(),
            speaker: speaker,
            text: text,
            timeRange: TimeRange(start: .seconds(2), end: .milliseconds(3_250)),
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            speakerDecision: decision
        )
    }

    @Test func roundTripsThroughJSON() throws {
        let utterance = makeUtterance()
        let data = try JSONEncoder().encode(utterance)
        #expect(try JSONDecoder().decode(Utterance.self, from: data) == utterance)
    }

    @Test func agentUtterancesHaveNoSpeakerDecision() throws {
        let utterance = makeUtterance(speaker: .agent, decision: nil)
        let data = try JSONEncoder().encode(utterance)
        let decoded = try JSONDecoder().decode(Utterance.self, from: data)
        #expect(decoded.speakerDecision == nil)
        #expect(decoded.speaker == .agent)
    }

    @Test func durationComesFromTheTimeRange() {
        #expect(makeUtterance().duration == .milliseconds(1_250))
    }

    @Test(arguments: ["", " ", "\n\t "])
    func whitespaceOnlyTextIsBlank(text: String) {
        #expect(makeUtterance(text: text).isBlank)
    }

    @Test func textIsNotBlank() {
        #expect(!makeUtterance(text: " ok ").isBlank)
    }

    @Test func refiningTextKeepsTheIdentity() {
        var utterance = makeUtterance(text: "hello there")
        let id = utterance.id
        utterance.text = "Hello there."
        #expect(utterance.id == id)
    }
}
