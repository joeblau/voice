import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

/// Halves its input and delays it by `delay` samples.
private final class HalvingSuppressor: NoiseSuppressor {
    let descriptor: NoiseSuppressorDescriptor
    private var line: [Float]

    init(delay: Int) {
        descriptor = NoiseSuppressorDescriptor(
            id: "half", title: "Half", latencySamples: delay, settings: ["model": "test"])
        line = [Float](repeating: 0, count: delay)
    }

    func process(_ samples: [Float]) throws -> [Float] {
        line += samples.map { $0 / 2 }
        let ready = line.count - descriptor.latencySamples
        defer { line.removeFirst(ready) }
        return Array(line[0..<ready])
    }

    func finish() throws -> [Float] {
        defer { reset() }
        return line
    }

    func reset() { line = [Float](repeating: 0, count: descriptor.latencySamples) }
}

/// Transcribes nothing: records the audio it was given and emits one final
/// per utterance at its end, with 5 ms of compute.
private final class RecordingEngine: ASREvaluationEngine {
    let descriptor = ASREngineDescriptor(
        id: "base", title: "Base", kind: .streaming, model: "model@1234", settings: ["chunk": "320 ms"])
    let received = Mutex<[[Float]]>([])
    let prepared = Mutex(0)

    func prepare() async throws { prepared.withLock { $0 += 1 } }

    func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript {
        received.withLock { $0.append(fixture.samples) }
        let events = fixture.utterances.map { utterance in
            ASRTimedEvent(
                kind: .final, text: utterance.text, range: utterance.range, audioPosition: utterance.range.upperBound,
                computeLag: .milliseconds(5))
        }
        return ASREngineTranscript(events: events, computeTime: .milliseconds(10))
    }
}

@Suite("Noise-suppressed ASR evaluation engine")
struct NoiseSuppressedASREvaluationEngineTests {
    let fixture = ASREvaluationFixture(
        id: "f", category: "cafe", samples: (0..<16_000).map { Float($0 % 100) / 100 },
        utterances: [ASRReferenceUtterance(range: 1_600..<8_000, text: "hello there")])

    @Test func namesTheVariantAfterBothParts() throws {
        let engine = try NoiseSuppressedASREvaluationEngine(base: RecordingEngine()) { HalvingSuppressor(delay: 480) }
        #expect(engine.descriptor.id == "base+half")
        #expect(engine.descriptor.title == "Base, after Half")
        #expect(engine.descriptor.kind == .streaming)
        #expect(engine.descriptor.model == "model@1234")
        #expect(engine.descriptor.settings["chunk"] == "320 ms")
        #expect(engine.descriptor.settings["noiseSuppression"] == "half")
        #expect(engine.descriptor.settings["noiseSuppressionDelay"] == "30 ms")
        #expect(engine.descriptor.settings["noiseSuppression.model"] == "test")
    }

    @Test func transcribesTheEnhancedAudioAndChargesTheDelay() async throws {
        let base = RecordingEngine()
        let engine = try NoiseSuppressedASREvaluationEngine(base: base) { HalvingSuppressor(delay: 480) }
        let transcript = try await engine.transcribe(fixture)

        // The base engine got the enhanced audio, aligned with the labels.
        let received = try #require(base.received.withLock { $0.first })
        #expect(received == fixture.samples.map { $0 / 2 })
        // Every event is 30 ms (plus the suppressor's compute) later.
        let event = try #require(transcript.events.first)
        #expect(event.audioPosition == 8_000)
        #expect(event.computeLag >= .milliseconds(35))
        #expect(event.computeLag < .milliseconds(135))
        #expect(transcript.computeTime >= .milliseconds(10))
        #expect(transcript.hypothesis == "hello there")
    }

    @Test func preparesBothParts() async throws {
        let base = RecordingEngine()
        let engine = try NoiseSuppressedASREvaluationEngine(base: base) { HalvingSuppressor(delay: 0) }
        try await engine.prepare()
        #expect(base.prepared.withLock { $0 } == 1)
    }

    @Test func comparisonLinesVariantsUpWithTheirEngine() async throws {
        let dataset = try ASREvaluationDataset(name: "test", consent: "test", fixtures: [fixture])
        let base = RecordingEngine()
        let report = try await ASREvaluator(dataset: dataset).run(
            [base, try NoiseSuppressedASREvaluationEngine(base: base) { HalvingSuppressor(delay: 480) }],
            commit: nil)
        let comparison = NoiseSuppressionComparison(report)
        #expect(comparison.categories == ["cafe"])
        #expect(comparison.rows.map(\.suppressor) == ["none", "half"])
        #expect(comparison.rows.allSatisfy { $0.engine == "base" && $0.wordErrorRates == [0, 0] })
        let markdown = comparison.markdown()
        #expect(markdown.contains("`base`:"))
        #expect(markdown.contains("| `half` | 0.0% | 0.0% | 0 | 0 of 1 |"))
    }
}
