import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauTranscription

@Suite("ASR evaluator")
struct ASREvaluatorTests {
    /// Two utterances: 1–3 s and 5–6 s of an 8 s file.
    let fixture = syntheticFixture(
        id: "two", seconds: 8,
        utterances: [("Can you remind me what we said", 1, 3), ("Thanks", 5, 6)])

    func dataset(_ fixtures: [ASREvaluationFixture]) throws -> ASREvaluationDataset {
        try ASREvaluationDataset(name: "test", consent: "synthetic", fixtures: fixtures)
    }

    func event(
        _ kind: ASRTimedEvent.Kind, _ text: String, _ from: Double, _ to: Double, at position: Double,
        compute: Duration = .zero
    ) -> ASRTimedEvent {
        ASRTimedEvent(
            kind: kind, text: text, range: Int64(from * 16_000)..<Int64(to * 16_000),
            audioPosition: Int64(position * 16_000), computeLag: compute)
    }

    @Test func measuresWERLatencyAndRTFFromTimedEvents() throws {
        let transcript = ASREngineTranscript(
            events: [
                event(.partial, "can you", 1, 1.4, at: 1.5, compute: .milliseconds(20)),
                event(.partial, "can you remind", 1, 1.8, at: 1.9),
                event(.final, "Can you remind me what we said.", 1, 3, at: 4, compute: .milliseconds(30)),
                event(.partial, "thanks", 5, 5.6, at: 5.7, compute: .milliseconds(10)),
                event(.final, "Thank you", 5, 6, at: 7, compute: .milliseconds(5)),
            ],
            computeTime: .milliseconds(400))
        let result = ASREvaluator(dataset: try dataset([fixture])).score(transcript, for: fixture)

        // "thanks" against "thank you": one substitution and one insertion.
        #expect(result.counts == WordErrorCounts(referenceWords: 8, substitutions: 1, insertions: 1))
        #expect(result.hypothesis == "Can you remind me what we said. Thank you")
        #expect(result.utterances.count == 2)
        let first = result.utterances[0]
        #expect(first.firstPartialAudioMilliseconds == 500)
        #expect(first.firstPartialMilliseconds == 520)
        #expect(first.endOfUtteranceAudioMilliseconds == 1_000)
        #expect(first.endOfUtteranceMilliseconds == 1_030)
        #expect(first.finals == 1)
        let second = result.utterances[1]
        #expect(second.firstPartialMilliseconds == 710)
        #expect(second.endOfUtteranceMilliseconds == 1_005)
        #expect(result.audioSeconds == 8)
        #expect(abs(result.realTimeFactor - 0.05) < 1e-9)
    }

    @Test func countsMissedAndSplitUtterances() throws {
        let transcript = ASREngineTranscript(
            events: [
                event(.final, "Can you remind", 1, 2, at: 2.5),
                event(.final, "me what we said", 2, 3, at: 4),
            ],
            computeTime: .zero)
        let result = ASREvaluator(dataset: try dataset([fixture])).score(transcript, for: fixture)
        #expect(result.utterances[0].finals == 2)
        // Latency to the last final over the utterance: when the turn is whole.
        #expect(result.utterances[0].endOfUtteranceAudioMilliseconds == 1_000)
        #expect(result.utterances[1].finals == 0)
        #expect(result.utterances[1].endOfUtteranceMilliseconds == nil)
        #expect(result.utterances[1].firstPartialMilliseconds == nil)
        let metrics = ASRMetrics([result])
        #expect(metrics.missedUtterances == 1)
        #expect(metrics.splitUtterances == 1)
        #expect(metrics.counts.deletions == 1)
    }

    @Test func anUtteranceFinalizedOnlyByTheEndOfTheAudioIsUnended() throws {
        // Background speech kept VAD open: the final came when the file ended.
        let transcript = ASREngineTranscript(
            events: [
                event(.final, "can you remind me what we said", 1, 3, at: 4),
                event(.final, "thanks", 5, 8, at: 8),
            ],
            computeTime: .zero)
        let evaluator = ASREvaluator(dataset: try dataset([fixture]))
        let streaming = evaluator.score(transcript, for: fixture)
        #expect(streaming.utterances.map(\.endedByStreamEnd) == [false, true])
        let metrics = ASRMetrics([streaming])
        #expect(metrics.unendedUtterances == 1)
        // Its 2 s "latency" is the file's tail, so it isn't in the summary.
        #expect(metrics.endOfUtteranceAudio?.count == 1)
        #expect(metrics.endOfUtteranceAudio?.maximum == 1_000)
        // An offline engine's final at the end of the file is just padding.
        let offline = evaluator.score(transcript, for: fixture, kind: .offline)
        #expect(offline.utterances.allSatisfy { !$0.endedByStreamEnd })
    }

    @Test func aPartialOfTheNextUtteranceDoesNotCountForThisOne() throws {
        // The first utterance gets no partial of its own; the second's
        // partial comes after the next utterance started.
        let transcript = ASREngineTranscript(
            events: [event(.partial, "thanks", 2.5, 5.5, at: 5.6), event(.final, "thanks", 5, 6, at: 7)],
            computeTime: .zero)
        let result = ASREvaluator(dataset: try dataset([fixture])).score(transcript, for: fixture)
        #expect(result.utterances[0].firstPartialMilliseconds == nil)
        #expect(result.utterances[1].firstPartialAudioMilliseconds == 600)
    }

    @Test func runsEveryEngineAndBreaksResultsDownByCategory() async throws {
        let clean = syntheticFixture(id: "clean-1", category: "clean", seconds: 4, utterances: [("hello there", 1, 2)])
        let noisy = syntheticFixture(id: "tv-1", category: "tv", seconds: 4, utterances: [("good night", 1, 2)])
        let perfect = PreparedEngine(
            id: "perfect",
            [
                "clean-1": ASREngineTranscript(
                    events: [event(.final, "Hello there.", 1, 2, at: 3)], computeTime: .milliseconds(100)),
                "tv-1": ASREngineTranscript(
                    events: [event(.final, "good night", 1, 2, at: 3)], computeTime: .milliseconds(300)),
            ])
        let broken = PreparedEngine(
            id: "broken", kind: .offline,
            ["clean-1": ASREngineTranscript(events: [event(.final, "hello", 1, 2, at: 2.2)], computeTime: .zero)])

        let progress = ProgressLog()
        let report = try await ASREvaluator(dataset: try dataset([clean, noisy])).run(
            [perfect, broken], commit: "abc123", progress: { progress.append($0) })

        #expect(report.schemaVersion == ASREvaluationReport.currentSchemaVersion)
        #expect(report.commit == "abc123")
        #expect(report.dataset.fixtures == 2)
        #expect(report.dataset.categories == ["clean", "tv"])
        let good = try #require(report.engine("perfect"))
        #expect(good.overall.wordErrorRate == 0)
        #expect(good.categories.map(\.name) == ["clean", "tv"])
        #expect(abs(good.overall.realTimeFactor - 0.05) < 1e-9)
        #expect(good.metrics(for: "tv")?.counts.referenceWords == 2)
        let bad = try #require(report.engine("broken"))
        #expect(bad.overall.failures == 1)
        #expect(bad.fixtures.last?.error?.contains("noTranscript") == true)
        #expect(bad.overall.counts == WordErrorCounts(referenceWords: 4, deletions: 3))
        #expect(progress.lines.contains { $0.contains("[broken] 2/2 tv-1") && $0.contains("failed") })
    }
}

final class ProgressLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ line: String) { storage.withLock { $0.append(line) } }
    var lines: [String] { storage.withLock { $0 } }
}

@Suite("ASR evaluation engines")
struct ASREvaluationEngineTests {
    @Test func theStreamingEngineRunsVADAndTheTranscriberLikeTheLivePipeline() async throws {
        let fixture = syntheticFixture(
            id: "two", seconds: 9,
            utterances: [("can you remind me what we decided", 1, 3.2), ("thanks a lot", 5, 6.2)])
        let engine = simulatedStreamingEngine()
        try await engine.prepare()
        let transcript = try await engine.transcribe(fixture)

        #expect(transcript.finals.map(\.text) == ["can you remind me what we decided", "thanks a lot"])
        #expect(!transcript.partials.isEmpty)
        #expect(transcript.computeTime > .zero)
        // Events come out in stream order, after the audio they cover.
        let positions = transcript.events.map(\.audioPosition)
        #expect(positions == positions.sorted())
        for event in transcript.events {
            #expect(event.audioPosition >= event.range.upperBound - 16_000 / 10, "\(event)")
        }

        let result = ASREvaluator(dataset: try ASREvaluationDataset(name: "t", consent: "x", fixtures: [fixture]))
            .score(transcript, for: fixture)
        #expect(result.counts.errors == 0)
        for utterance in result.utterances {
            #expect(utterance.finals == 1)
            // The simulated recognizer decodes a word once its 320 ms chunk
            // has run; VAD confirms the onset a few chunks in.
            let partial = try #require(utterance.firstPartialAudioMilliseconds)
            #expect((200...1_500).contains(partial), "first partial \(partial) ms")
            // The VAD fallback or the model commits within about a second
            // of the end of speech.
            let end = try #require(utterance.endOfUtteranceAudioMilliseconds)
            #expect((300...1_600).contains(end), "end of utterance \(end) ms")
        }
    }

    @Test func theStreamingEngineStartsEachFixtureFromACleanState() async throws {
        let engine = simulatedStreamingEngine()
        let first = syntheticFixture(id: "a", seconds: 5, utterances: [("first fixture words", 1, 2.5)])
        let second = syntheticFixture(id: "b", seconds: 5, utterances: [("second one", 1, 2)])
        let a = try await engine.transcribe(first)
        let b = try await engine.transcribe(second)
        let again = try await engine.transcribe(first)
        #expect(a.hypothesis == "first fixture words")
        #expect(b.hypothesis == "second one")
        #expect(again.hypothesis == a.hypothesis)
        #expect(again.events.map(\.audioPosition) == a.events.map(\.audioPosition))
    }

    @Test func theOfflineEngineTranscribesEachUtteranceWithPadding() async throws {
        let fixture = syntheticFixture(
            id: "two", seconds: 6, utterances: [("hello there", 0.1, 2), ("bye", 2.1, 3)])
        let model = ScriptedUtteranceModel(["Hello, there!", "  bye  "])
        let engine = OfflineASREvaluationEngine(
            descriptor: ASREngineDescriptor(id: "scripted", title: "Scripted", kind: .offline), model: model)
        // 200 ms either side, but never into the other utterance's speech.
        #expect(engine.segments(of: fixture) == [0..<33_600, 32_000..<51_200])

        let transcript = try await engine.transcribe(fixture)
        #expect(transcript.finals.map(\.text) == ["Hello, there!", "bye"])
        #expect(transcript.partials.isEmpty)
        #expect(transcript.finals.map(\.range) == fixture.utterances.map(\.range))
        #expect(transcript.finals.map(\.audioPosition) == [33_600, 51_200])
        let received = await model.received
        #expect(received.map(\.count) == [33_600, 19_200])

        let result = ASREvaluator(dataset: try ASREvaluationDataset(name: "t", consent: "x", fixtures: [fixture]))
            .score(transcript, for: fixture)
        #expect(result.counts.errors == 0)
        // The padding after the speech (cut short where the next utterance
        // starts) plus the model's compute.
        #expect(result.utterances[0].endOfUtteranceAudioMilliseconds == 100)
        #expect(result.utterances[1].endOfUtteranceAudioMilliseconds == 200)
        #expect(result.utterances[1].firstPartialMilliseconds == nil)
    }

    @Test(.enabled(if: ASRFixtures.audioIsAvailable, "The fixture audio is in Git LFS: run git lfs pull"))
    func theHarnessRunsEndToEndOnTheBundledFixtures() async throws {
        let dataset = try ASREvaluationDataset.load(manifest: ASRFixtures.manifestURL(), categories: ["clean"])
        let report = try await ASREvaluator(dataset: dataset).run([simulatedStreamingEngine()])
        let engine = try #require(report.engine("simulated-eou"))
        // A recognizer that knows the words and a VAD that finds the clean
        // speech: every utterance comes out whole, so any error here is the
        // harness's.
        #expect(engine.overall.wordErrorRate == 0, "\(engine.fixtures.map(\.hypothesis))")
        #expect(engine.overall.missedUtterances == 0)
        #expect(engine.overall.splitUtterances == 0)
        #expect(engine.overall.utterances == dataset.utteranceCount)
        #expect(engine.overall.endOfUtteranceAudio != nil)
        #expect(report.table().contains("simulated-eou"))
    }
}
