import BlauCore
import BlauTelemetry
import BlauTopics
import Foundation
import Synchronization
import Testing

@Suite("Topic label benchmark")
struct TopicLabelBenchmarkTests {
    /// Cold first request 1.2 s, then 300 ms, or 200 ms when prewarmed.
    final class FakeGenerator: TopicLabelGenerator {
        let clock: ManualClock
        let unavailable: String?
        let requests = Mutex<[Bool]>([])

        init(clock: ManualClock, unavailable: String? = nil) {
            self.clock = clock
            self.unavailable = unavailable
        }

        func unavailableReason() async -> String? { unavailable }

        func label(_ window: TopicBoundaryWindow, prewarm: Bool) async throws -> TopicLabelDraft {
            let first = requests.withLock { requests in
                requests.append(prewarm)
                return requests.count == 1
            }
            clock.advance(by: first ? .milliseconds(1_200) : (prewarm ? .milliseconds(200) : .milliseconds(300)))
            // Every third title is too long.
            let count = requests.withLock { $0.count }
            return TopicLabelDraft(
                isNewTopic: true, title: count % 3 == 0 ? "A title that is far too long" : "Weekend plans")
        }
    }

    struct FixedProbe: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 1 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    @Test func measuresColdPlainAndPrewarmedRequests() async throws {
        let clock = ManualClock()
        let generator = FakeGenerator(clock: clock)
        let benchmark = TopicLabelBenchmark(
            generator: generator, configuration: .init(iterations: 4), signposter: .disabled(.topics))

        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(benchmark)

        #expect(result.outcome == .completed)
        #expect(result.id == "topics.label.foundationModels")
        #expect(result.metric("label.cold")?.value == 1_200)
        #expect(result.latencies["label"]?.count == 4)
        #expect(result.latencies["label"]?.p50 == 300)
        #expect(result.latencies["label.prewarmed"]?.p50 == 200)
        // 9 requests, titles 3, 6 and 9 too long.
        #expect(abs((result.metric("titles.withinWordLimit")?.value ?? 0) - 600.0 / 9) < 1e-9)
        #expect(generator.requests.withLock { $0 } == [false, false, true, false, true, false, true, false, true])
    }

    @Test func skipsWhenTheModelIsUnavailable() async {
        let clock = ManualClock()
        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(
                TopicLabelBenchmark(
                    generator: FakeGenerator(clock: clock, unavailable: "Apple Intelligence is turned off")))
        #expect(result.outcome == .skipped(reason: "Foundation Models unavailable: Apple Intelligence is turned off"))
    }

    @Test func countsTitleWords() {
        #expect(TopicLabelDraft(isNewTopic: true, title: "  Launch  plan ").titleWordCount == 2)
        #expect(TopicLabelDraft(isNewTopic: false, title: "").titleWordCount == 0)
    }

    @Test func fixtureWindowsHaveTextOnBothSides() {
        #expect(TopicBoundaryWindow.benchmarkWindows.count >= 4)
        for window in TopicBoundaryWindow.benchmarkWindows {
            #expect(!window.before.isEmpty && !window.after.isEmpty)
        }
    }
}
