import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

@Suite("SpeakerEmbeddingBenchmark")
struct SpeakerEmbeddingBenchmarkTests {
    /// An embedder whose calls "take" a scripted time on a manual clock.
    final class TimedEmbedder: SpeakerEmbedder {
        let model = SpeakerEmbeddingModelInfo(identifier: "timed", dimension: 2)
        let minimumDuration: Duration = .milliseconds(1)
        let clock: ManualClock
        private let script: Mutex<[Duration]>
        private let calls = Mutex<[[Int]]>([])

        init(clock: ManualClock, durations: [Duration]) {
            self.clock = clock
            self.script = Mutex(durations)
        }

        var segmentLengths: [[Int]] { calls.withLock { $0 } }

        func embed(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding] {
            calls.withLock { $0.append(segments.map(\.sampleCount)) }
            let duration = script.withLock { $0.isEmpty ? Duration.zero : $0.removeFirst() }
            clock.advance(by: duration)
            return segments.map { _ in
                SpeakerEmbedding(normalizing: [1, 0], modelIdentifier: "timed", audioDuration: .zero)!
            }
        }
    }

    @Test func timesEachIterationAfterTheWarmUp() async throws {
        let clock = ManualClock()
        let warmUp: [Duration] = [.seconds(9), .seconds(9)]
        let timed: [Duration] = [4, 1, 3, 2, 5].map { .milliseconds($0) }
        let embedder = TimedEmbedder(clock: clock, durations: warmUp + timed)
        let benchmark = SpeakerEmbeddingBenchmark(iterations: 5, warmUpIterations: 2, clock: clock)

        let results = try await benchmark.run(embedder, scenarios: [.longWindow])

        #expect(embedder.segmentLengths == Array(repeating: [48_000], count: 7))
        let result = try #require(results.first)
        #expect(result.scenario == .longWindow)
        #expect(result.samples == timed)
        #expect(result.minimum == .milliseconds(1))
        #expect(result.maximum == .milliseconds(5))
        #expect(result.median == .milliseconds(3))
        #expect(result.mean == .milliseconds(3))
        #expect(result.percentile(90) == .milliseconds(5))
        #expect(result.percentile(0) == .milliseconds(1))
    }

    @Test func runsScenariosInOrder() async throws {
        let embedder = TimedEmbedder(clock: ManualClock(), durations: [])
        let benchmark = SpeakerEmbeddingBenchmark(iterations: 1, warmUpIterations: 0, clock: embedder.clock)
        let results = try await benchmark.run(embedder)
        #expect(results.map(\.scenario) == SpeakerEmbeddingBenchmark.Scenario.standard)
        #expect(embedder.segmentLengths == [[24_000], [48_000]])
    }

    @Test func nearestRankPercentiles() {
        let result = SpeakerEmbeddingBenchmark.Result(
            scenario: .shortWindow, samples: (1...100).map { .milliseconds($0) })
        #expect(result.percentile(50) == .milliseconds(50))
        #expect(result.percentile(90) == .milliseconds(90))
        #expect(result.percentile(99) == .milliseconds(99))
        #expect(result.percentile(100) == .milliseconds(100))
    }

    @Test func formatsAMarkdownTableInMilliseconds() {
        let result = SpeakerEmbeddingBenchmark.Result(
            scenario: .longWindow, samples: [.microseconds(1_500), .microseconds(2_500)])
        let table = SpeakerEmbeddingBenchmark.markdownTable([result])
        let lines = table.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("| Scenario | Runs | p50 (ms)"))
        #expect(lines[2] == "| 3 s window | 2 | 1.50 | 2.50 | 2.50 | 2.00 | 1.50 | 2.50 |")
    }

    @Test func syntheticSpeechIsDeterministicAndSpeechLike() {
        let a = SpeakerEmbeddingBenchmark.syntheticSpeech(duration: .milliseconds(1_500), seed: 3)
        let b = SpeakerEmbeddingBenchmark.syntheticSpeech(duration: .milliseconds(1_500), seed: 3)
        let c = SpeakerEmbeddingBenchmark.syntheticSpeech(duration: .milliseconds(1_500), seed: 4)
        #expect(a == b)
        #expect(a != c)
        #expect(a.sampleCount == 24_000)
        #expect(a.sampleRate == 16_000)
        #expect(a.samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(a.rms > 0.01 && a.rms < 0.5)
    }
}

@Suite("Speaker fixtures")
struct SpeakerFixtureTests {
    @Test func fourSpeakersWithThreeClipsEachAt16kHz() throws {
        let clips = try SpeakerFixtures.load()
        #expect(clips.count == 12)
        let bySpeaker = Dictionary(grouping: clips, by: \.speaker)
        #expect(Set(bySpeaker.keys) == ["bdl", "clb", "rms", "slt"])
        #expect(bySpeaker.values.allSatisfy { $0.map(\.utterance) == ["a0001", "a0002", "a0003"] })
        for clip in clips {
            #expect(clip.audio.sampleRate == AudioFrame.captureSampleRate, "\(clip.name)")
            #expect(clip.audio.duration >= .milliseconds(2_800), "\(clip.name)")
            #expect(clip.audio.duration <= .seconds(4), "\(clip.name)")
            #expect(clip.audio.rms > 0.01, "\(clip.name) has speech")
        }
    }
}
