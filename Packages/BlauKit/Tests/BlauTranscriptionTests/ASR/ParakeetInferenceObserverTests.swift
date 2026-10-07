import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// The Parakeet transcriber reports each model chunk to the background
/// inference monitor (#26) as the `"asr"` stage, which lets the monitor move
/// speech-to-text to Apple's engine (#31) when Parakeet can't keep up.
@Suite("Parakeet inference observations")
struct ParakeetInferenceObserverTests {
    final class RecordingObserver: InferenceObserver {
        private let observations = Mutex<[InferenceObservation]>([])

        func record(_ observation: InferenceObservation) {
            observations.withLock { $0.append(observation) }
        }

        var all: [InferenceObservation] { observations.withLock { $0 } }
    }

    @Test func everyChunkAndFailureIsReported() async throws {
        let scenario = Scenario(seconds: 4).speech("one two three", from: 0.5, to: 2.0, endsUtterance: true)
        let recognizer = SimulatedEouRecognizer(
            words: scenario.words, chunkTime: .milliseconds(12), failingChunks: [3])
        let source = FixtureAudioSource(block: scenario.samples)
        let observer = RecordingObserver()
        let transcriber = ParakeetStreamingTranscriber(
            recognizer: recognizer, audio: source, voiceActivity: ScriptedVoiceActivity(),
            signposter: .disabled(.asr), clock: ManualClock(), inferenceObserver: observer)
        _ = await TranscriptionReplay.run(transcriber, source: source, vadEvents: scenario.events)

        let observations = observer.all
        #expect(observations.allSatisfy { $0.stage == "asr" })
        let completed = observations.filter {
            if case .completed(let latency) = $0.outcome { return latency == .milliseconds(12) }
            return false
        }
        let failed = observations.filter { if case .failed = $0.outcome { true } else { false } }
        #expect(failed.count == 1)
        // One per streaming chunk; the flushes at a commit aren't counted.
        #expect(!completed.isEmpty)
        #expect(Int64(completed.count) <= transcriber.statistics.chunksProcessed)
        #expect(Int64(completed.count) >= transcriber.statistics.chunksProcessed - 8)
    }
}
