import BlauCore
import Foundation
import Testing

private let segment = AudioFrame(samples: [0.1, -0.1], sampleOffset: 0)

private func utterance(_ text: String) -> Utterance {
    Utterance(
        conversationID: ConversationID(),
        speaker: .user,
        text: text,
        timeRange: TimeRange(start: .zero, end: .seconds(1)),
        startedAt: Date(timeIntervalSinceReferenceDate: 0),
        speakerDecision: .accept
    )
}

@Suite("Fake services")
struct FakeServicesTests {
    @Test func audioTracksCapture() async throws {
        let audio = FakeAudioService()
        #expect(!audio.isCapturing)
        try await audio.startCapture()
        #expect(audio.isCapturing)
        #expect(audio.startCount == 1)
        await audio.stopCapture()
        #expect(!audio.isCapturing)
    }

    @Test func audioStartErrorIsThrown() async {
        struct Denied: Error {}
        let audio = FakeAudioService(startError: Denied())
        await #expect(throws: Denied.self) { try await audio.startCapture() }
        #expect(!audio.isCapturing)
    }

    @Test func voiceGateReturnsScriptedDecisionsThenTheFallback() async throws {
        let gate = FakeVoiceGate(decisions: [.uncertain, .reject], fallback: .accept)
        #expect(gate.isEnrolled)
        #expect(try await gate.evaluate(segment) == .uncertain)
        #expect(try await gate.evaluate(segment) == .reject)
        #expect(try await gate.evaluate(segment) == .accept)
        #expect(gate.evaluatedSegments.count == 3)
    }

    @Test func unenrolledVoiceGateRejectsEverything() async throws {
        let gate = FakeVoiceGate(isEnrolled: false, decisions: [.accept])
        #expect(!gate.isEnrolled)
        #expect(try await gate.evaluate(segment) == .reject)
    }

    @Test func realtimeRecordsSendsOnlyWhileConnected() async throws {
        let realtime = FakeRealtimeService()
        let hello = utterance("hello")
        await #expect(throws: FakeRealtimeService.NotConnectedError()) { try await realtime.send(hello) }

        try await realtime.connect()
        #expect(realtime.isConnected)
        try await realtime.send(hello)
        #expect(realtime.sentUtterances == [hello])

        await realtime.disconnect()
        #expect(!realtime.isConnected)
    }

    @Test func topicsRecordIngestedUtterances() async {
        let topics = FakeTopicService()
        let first = utterance("first")
        let second = utterance("second")
        await topics.ingest(first)
        await topics.ingest(second)
        #expect(topics.ingestedUtterances == [first, second])
    }

    @Test func memoryRanksByKeywordOverlap() async throws {
        let memory = FakeMemoryService(memories: [
            "Joe is building Blau, a voice app",
            "The YC interview is on Friday",
            "Blau talks to Grok over a realtime voice API",
        ])
        let hits = try await memory.search("Blau voice interview", limit: 5)
        #expect(
            hits.map(\.text) == [
                "Joe is building Blau, a voice app",
                "Blau talks to Grok over a realtime voice API",
                "The YC interview is on Friday",
            ]
        )
        #expect(hits.map(\.score) == [2.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0])
        #expect(hits.first?.id == memory.memories.first?.id, "hits keep the memory's identity")
        #expect(memory.queries == ["Blau voice interview"])

        #expect(try await memory.search("blau", limit: 1).count == 1)
        #expect(try await memory.search("pancakes", limit: 5).isEmpty)
        #expect(try await memory.search("   ", limit: 5).isEmpty)
        #expect(try await memory.search("blau", limit: 0).isEmpty)
    }

    @Test func fakesRecordLifecycleTransitions() async {
        let transition = AppPhaseTransition(from: .active, to: .inactive)
        let audio = FakeAudioService()
        let gate = FakeVoiceGate()
        let realtime = FakeRealtimeService()
        let topics = FakeTopicService()
        let memory = FakeMemoryService()
        let participants: [any AppLifecycleParticipant] = [audio, gate, realtime, topics, memory]
        for participant in participants {
            await participant.appPhaseDidChange(transition)
        }
        #expect(audio.receivedTransitions == [transition])
        #expect(gate.receivedTransitions == [transition])
        #expect(realtime.receivedTransitions == [transition])
        #expect(topics.receivedTransitions == [transition])
        #expect(memory.receivedTransitions == [transition])
    }
}

@Suite("UnavailableService")
struct UnavailableServiceTests {
    private let service = UnavailableService(subsystem: "realtime")
    private var expected: ServiceUnavailableError { ServiceUnavailableError(subsystem: "realtime") }

    @Test func actionsThrowAndQueriesReportOff() async {
        await #expect(throws: expected) { try await service.startCapture() }
        await #expect(throws: expected) { try await service.start() }
        await #expect(throws: expected) { try await service.evaluate(segment) }
        await #expect(throws: expected) { try await service.connect() }
        await #expect(throws: expected) { try await service.send(utterance("hi")) }
        await #expect(throws: expected) { try await service.search("hi", limit: 3) }

        #expect(!service.isCapturing)
        #expect(!service.isEnrolled)
        #expect(!service.isConnected)

        // Stopping and ingesting are harmless no-ops.
        await service.stopCapture()
        await service.stop()
        await service.disconnect()
        await service.ingest(utterance("hi"))
    }

    @Test func transcriptStreamIsAlreadyFinished() async {
        var iterator = service.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func errorNamesTheSubsystem() {
        #expect(expected.description == "The realtime service is not available in this build")
    }
}
