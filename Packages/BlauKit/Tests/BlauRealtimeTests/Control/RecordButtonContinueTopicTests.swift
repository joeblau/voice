import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// "Continue This Topic" through the record button's model (#58).
@Suite("RecordButtonModel: continuing a topic", .timeLimit(.minutes(1)))
@MainActor
struct RecordButtonContinueTopicTests {
    private struct MicDenied: LocalizedError {
        var errorDescription: String? { "Microphone access is off." }
    }

    private let clock = ManualClock()
    private let signposts = RecordingSignpostBackend()
    private let topic = RealtimeContinuedTopic(
        topicID: UUID(), title: "Seed Round", summary: "Raise $2M.", startedAt: Date(timeIntervalSince1970: 0))

    private func makeModel(_ session: FakeConversationSession) -> RecordButtonModel {
        RecordButtonModel(session: session, clock: clock, signposter: Signposter(category: .ui, backend: signposts))
    }

    @Test func whenIdleItStartsAConversationThatPicksUpTheTopic() async {
        let audio = FakeAudioService()
        let session = FakeConversationSession(audio: audio)
        let model = makeModel(session)

        #expect(await model.continueTopic(topic) == .started)

        // Exactly like a tap: started, listening, the start haptic and the
        // `session.start` interval.
        #expect(session.calls == [.start])
        #expect(session.continuedTopics == [topic])
        #expect(audio.isCapturing)
        #expect(model.phase == .running)
        #expect(model.state == .listening)
        #expect(model.feedback?.kind == .started)
        #expect(signposts.completedIntervals == ["session.start"])
    }

    @Test func aRunningConversationTakesTheTopic() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.tap()
        let feedback = model.feedback

        #expect(await model.continueTopic(topic) == .continued)
        #expect(session.calls == [.start, .continueTopic(topic.topicID)])
        #expect(session.continuedTopics == [topic])
        // Nothing restarts.
        #expect(model.phase == .running)
        #expect(model.feedback == feedback)
    }

    @Test func aFailedStartShowsLikeAFailedTap() async {
        let session = FakeConversationSession()
        session.startError = MicDenied()
        let model = makeModel(session)

        #expect(await model.continueTopic(topic) == .failed)
        #expect(model.phase == .idle)
        #expect(model.startFailureMessage == "Microphone access is off.")
        #expect(model.feedback?.kind == .failed)
    }

    @Test func itIsIgnoredWhileAStartIsInFlight() async throws {
        let session = FakeConversationSession(clock: clock, startDelay: .milliseconds(200))
        let model = makeModel(session)
        let tap = Task { await model.tap() }
        while model.phase != .starting { await Task.yield() }

        #expect(await model.continueTopic(topic) == .ignored)
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(200))
        await tap.value
        #expect(session.calls == [.start])
        #expect(session.continuedTopics.isEmpty)
    }

    @Test func aConversationThatEndedMeanwhileReportsAFailure() async {
        let session = FakeConversationSession()
        let model = makeModel(session)
        await model.tap()
        // Ended without the button; the model hasn't followed yet.
        session.update(.idle)

        #expect(await model.continueTopic(topic) == .failed)
        #expect(session.continuedTopics.isEmpty)
    }
}
