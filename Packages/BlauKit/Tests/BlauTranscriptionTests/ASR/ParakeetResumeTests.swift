import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauTranscription

/// `ParakeetStreamingTranscriber.start(resumingAt:)`: taking the
/// conversation over from the Apple engine at an utterance boundary (#31).
@Suite("Parakeet resuming after another engine")
struct ParakeetResumeTests {
    private func run(
        _ scenario: Scenario, resumeAt resume: Double, captureAlreadyAt position: Double, speechActive: Bool,
        sendingEvents events: [VoiceActivityEvent]
    ) async throws -> [Utterance] {
        let recognizer = SimulatedEouRecognizer(words: scenario.words)
        let source = FixtureAudioSource(block: scenario.samples)
        source.position = Int64(position * 16_000)
        let vad = SettableVoiceActivity(isSpeechActive: speechActive)
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: vad, signposter: .disabled(.asr),
            clock: ManualClock())
        let log = TranscriptLog(transcriber.events)

        try await transcriber.start(resumingAt: .seconds(resume))
        var pending = events.sorted { $0.detectedAt < $1.detectedAt }[...]
        var offset = source.position
        while offset < source.totalSamples {
            while let next = pending.first, next.detectedAt <= offset {
                vad.send(next)
                pending.removeFirst()
            }
            let frame = source.frame(at: offset, length: 320)
            source.publish(frame)
            offset = frame.nextSampleOffset
            await Task.yield()
        }
        source.finishFrames()
        try await waitUntil { await transcriber.isRunning == false }
        await transcriber.finish()
        try await waitUntil { log.finals.count == Int(transcriber.statistics.utterancesCommitted) }
        return log.finals
    }

    @Test func speechAlreadyUnderwayIsTranscribedFromTheResumePosition() async throws {
        // The speaker started at 2.0 s, while the engines were switching:
        // VAD's onset went out before this transcriber listened.
        let scenario = Scenario(seconds: 6).speech("hello again", from: 2.0, to: 3.0, endsUtterance: true)
        let finals = try await run(
            scenario, resumeAt: 2.0, captureAlreadyAt: 2.5, speechActive: true,
            sendingEvents: Array(scenario.events.dropFirst()))
        #expect(finals.map(\.text) == ["hello again"])
        #expect(finals.first?.timeRange.start == .seconds(2))
    }

    @Test func anOnsetBeforeTheResumePositionStartsAtIt() async throws {
        // The previous engine committed through 2.0 s; VAD places the onset
        // of the next speech earlier, inside the committed audio.
        let scenario = Scenario(seconds: 6)
            .speech("old words", from: 0.5, to: 1.5, endsUtterance: false)
            .speech("new words", from: 2.0, to: 3.0, endsUtterance: true)
        let late = VoiceActivityEvent.speechStarted(
            SpeechOnset(
                segmentID: 9, startOffset: 24_000, sampleRate: 16_000, isContinuation: false, detectedAt: 36_000))
        let ended = scenario.events.last!
        let finals = try await run(
            scenario, resumeAt: 2.0, captureAlreadyAt: 2.0, speechActive: false, sendingEvents: [late, ended])
        #expect(finals.map(\.text) == ["new words"])
        #expect(finals.first?.timeRange.start == .seconds(2))
    }
}
